import SwiftUI
import AVFoundation

struct MasterPair: Identifiable, Equatable {
    let id: String
    let baseName: String
    let masterURL: URL
    let originalURL: URL?
    let modified: Date
    var isLegacy: Bool = false
    var engineMode: MasteringMode? = nil
    var duration: TimeInterval = 0

    static func == (lhs: MasterPair, rhs: MasterPair) -> Bool { lhs.id == rhs.id }
}

/// Library of finished masters (paired with their originals) + synced dual player.
/// Both versions play simultaneously; the A/B flip is a seamless mute-swap at the
/// identical timestamp, with the louder file attenuated to matched loudness so the
/// ear judges quality instead of level.
@MainActor
final class PlayerController: ObservableObject {
    @Published var pairs: [MasterPair] = []
    @Published var current: MasterPair?
    @Published var isPlaying = false
    @Published var hearingOriginal = false
    @Published var position: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var loudnessMatched = false
    @Published var matchOffsetDb: Double = 0
    @Published var hasLegacyFiles = false

    private var masterPlayer: AVAudioPlayer?
    private var originalPlayer: AVAudioPlayer?
    private var masterVol: Float = 1
    private var originalVol: Float = 1
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1
    private var matchTask: Task<Void, Never>?

    // MARK: library scan + watch

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: AppState.masterDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: AppState.originalDir, withIntermediateDirectories: true)
        scan()
        watch()
    }

    func scan() {
        let fm = FileManager.default
        let mastersDir = AppState.masterDir
        let originalsDir = AppState.originalDir

        var masterMap: [String: URL] = [:]
        var originalMap: [String: URL] = [:]
        var modifiedMap: [String: Date] = [:]
        var engineMap: [String: MasteringMode] = [:]
        var durationMap: [String: TimeInterval] = [:]

        // Scan masters/
        if let masterItems = try? fm.contentsOfDirectory(at: mastersDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in masterItems {
                let rawName = item.deletingPathExtension().lastPathComponent
                let ext = item.pathExtension.lowercased()
                let mod = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                if ext == "json", rawName.hasSuffix(".meta") {
                    let metaBase = String(rawName.dropLast(".meta".count))
                    if let data = try? Data(contentsOf: item),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let raw = json["engine"],
                       let mode = MasteringMode(rawValue: raw) {
                        engineMap[metaBase] = mode
                    }
                    continue
                }

                guard ext == "wav" else { continue }
                masterMap[rawName] = item
                modifiedMap[rawName] = max(modifiedMap[rawName] ?? .distantPast, mod)
                if let player = try? AVAudioPlayer(contentsOf: item) {
                    durationMap[rawName] = max(durationMap[rawName] ?? 0, player.duration)
                }
            }
        }

        // Scan originals/  
        if let originalItems = try? fm.contentsOfDirectory(at: originalsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in originalItems {
                let rawName = item.deletingPathExtension().lastPathComponent
                if rawName.hasSuffix(" original") {
                    let base = String(rawName.dropLast(" original".count))
                    if originalMap[base] == nil { originalMap[base] = item }
                }
            }
        }

        pairs = masterMap.compactMap { base, masterURL -> MasterPair? in
            let modified = modifiedMap[base] ?? .distantPast
            let engine = engineMap[base]
            return MasterPair(id: base, baseName: base, masterURL: masterURL,
                              originalURL: originalMap[base], modified: modified,
                              isLegacy: false, engineMode: engine,
                              duration: durationMap[base] ?? 0)
        }
        .sorted { $0.modified > $1.modified }

        hasLegacyFiles = false
    }

    /// One-time migration removed — new folder scheme starts fresh.
    func migrateLegacyFiles() { scan() }

    private func watch() {
        guard watcher == nil else { return }
        let dir = AppState.masterDir
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in self?.scan() }
        source.setCancelHandler { [dirFD] in close(dirFD) }
        source.resume()
        watcher = source
    }

    // MARK: playback

    func select(_ pair: MasterPair) {
        if current == pair { togglePlay(); return }
        stop()
        current = pair
        hearingOriginal = false
        loudnessMatched = false
        matchOffsetDb = 0
        masterVol = 1
        originalVol = 1

        masterPlayer = try? AVAudioPlayer(contentsOf: pair.masterURL)
        originalPlayer = pair.originalURL.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        masterPlayer?.prepareToPlay()
        originalPlayer?.prepareToPlay()
        duration = masterPlayer?.duration ?? pair.duration
        position = 0
        applyVolumes()
        startSynced()
        matchLoudness(pair)
    }

    private func startSynced() {
        guard let master = masterPlayer else { return }
        let startAt = master.deviceCurrentTime + 0.08
        master.play(atTime: startAt)
        originalPlayer?.play(atTime: startAt)
        isPlaying = true
        startTimer()
    }

    func togglePlay() {
        guard let master = masterPlayer else { return }
        if isPlaying {
            master.pause()
            originalPlayer?.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            if let original = originalPlayer { original.currentTime = master.currentTime }
            startSynced()
        }
    }

    /// Seamless A/B: swap audibility between the synced players.
    func flip() {
        guard originalPlayer != nil else { return }
        hearingOriginal.toggle()
        if let master = masterPlayer, let original = originalPlayer, isPlaying {
            original.currentTime = master.currentTime
        }
        applyVolumes()
    }

    private func applyVolumes() {
        masterPlayer?.volume = hearingOriginal ? 0 : masterVol
        originalPlayer?.volume = hearingOriginal ? originalVol : 0
    }

    func seek(to time: TimeInterval) {
        masterPlayer?.currentTime = time
        originalPlayer?.currentTime = time
        position = time
    }

    func stop() {
        masterPlayer?.stop()
        originalPlayer?.stop()
        timer?.invalidate()
        matchTask?.cancel()
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let master = self.masterPlayer else { return }
                self.position = master.currentTime
                if self.isPlaying && master.isPlaying == false {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }

    // MARK: loudness matching

    private func matchLoudness(_ pair: MasterPair) {
        guard let originalURL = pair.originalURL else { return }
        matchTask?.cancel()
        let masterURL = pair.masterURL
        matchTask = Task.detached(priority: .utility) { [weak self] in
            guard let masterBuf = try? AudioLoader.load(url: masterURL),
                  let origBuf = try? AudioLoader.load(url: originalURL) else { return }
            let masterLufs = Loudness.integratedLufs(buffer: masterBuf)
            if Task.isCancelled { return }
            let origLufs = Loudness.integratedLufs(buffer: origBuf)
            if Task.isCancelled { return }
            let delta = origLufs - masterLufs
            await MainActor.run { [weak self] in
                guard let self, self.current == pair else { return }
                if delta > 0 {
                    self.originalVol = Float(pow(10, -delta / 20))
                    self.masterVol = 1
                } else {
                    self.masterVol = Float(pow(10, delta / 20))
                    self.originalVol = 1
                }
                self.matchOffsetDb = abs(delta)
                self.loudnessMatched = true
                self.applyVolumes()
            }
        }
    }
}

// MARK: - PlayerBar now lives in ContentView.swift (renamed MasterLibraryGrid)
