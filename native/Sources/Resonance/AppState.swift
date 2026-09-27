import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class AppState: ObservableObject {
    // Chat
    @Published var chat: [ChatBubble] = [
        ChatBubble(tone: .greeting, title: nil,
                   text: "ready when you are — drop a track or a batch and i'll do my best to give an honest read.")
    ]
    @Published var assistantStatus = "ready when you are"

    // Analysis
    @Published var currentFile: URL?
    @Published var currentAnalysis: AnalysisResult?
    @Published var isAnalyzing = false
    @Published var progress: Double = 0
    @Published var isMastering = false

    // Batch
    @Published var batchTracks: [BatchTrack] = []
    @Published var isBatchRunning = false
    var isBatchMode: Bool { !batchTracks.isEmpty }

    // Sidebar
    @Published var log: [LogEntry] = [LogEntry(time: AppState.timestamp(), message: "Awaiting input...")]
    @Published var history: [HistoryItem] = []
    @Published var hoverInfo: HoverInfo?

    // Mastering engine selection
    @AppStorage("masteringModeRaw") var masteringModeRaw: String = MasteringMode.core.rawValue
    var masteringMode: MasteringMode {
        get { MasteringMode(rawValue: masteringModeRaw) ?? .core }
        set { masteringModeRaw = newValue.rawValue }
    }

    // Single-blurb chat viewport (one mastering-expert blurb at a time)
    @Published var visibleChatIdx = 0
    @Published var chatPaused = false
    private var chatCycleTimer: Timer?

    // 10-second audition previews (middle slice, every engine)
    @Published var previewURLs: [MasteringMode: URL] = [:]
    @Published var batchPreviewMap: [String: [MasteringMode: URL]] = [:]
    @Published var previewGenerating = false
    @Published var previewProgressMode: MasteringMode?
    @Published var playingPreviewMode: MasteringMode?
    private var previewPlayer: AVAudioPlayer?
    private var previewStopTimer: Timer?

    /// All exports now use separate folders: masters/ and originals/
    nonisolated static var masterDir: URL {
        if let custom = ProcessInfo.processInfo.environment["RESONANCE_EXPORT_DIR"] {
            return URL(fileURLWithPath: custom).appendingPathComponent("resonance masters")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sound/resonance masters")
    }
    nonisolated static var originalDir: URL {
        if let custom = ProcessInfo.processInfo.environment["RESONANCE_EXPORT_DIR"] {
            return URL(fileURLWithPath: custom).appendingPathComponent("resonance originals")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Sound/resonance originals")
    }
    nonisolated static var exportDir: URL { masterDir }

    // MARK: logging + chat

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    func addLog(_ message: String) {
        log.append(LogEntry(time: Self.timestamp(), message: message))
    }

    func addChat(_ text: String, tone: ChatTone = .insight, title: String? = nil) {
        chat.append(ChatBubble(tone: tone, title: title, text: text))
        visibleChatIdx = max(0, chat.count - 1) // single-append jumps to newest
    }

    func clearChat() {
        chat.removeAll()
        visibleChatIdx = 0
    }

    /// Single-blurb viewport controls.
    func resetChatView() { visibleChatIdx = 0 }
    func advanceChat() {
        guard !chat.isEmpty else { return }
        visibleChatIdx = (visibleChatIdx + 1) % chat.count
    }
    func startChatCycle() {
        stopChatCycle()
        chatCycleTimer = Timer.scheduledTimer(withTimeInterval: 5.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.chatPaused,
                      !self.isAnalyzing, !self.isMastering, !self.isBatchRunning else { return }
                self.advanceChat()
            }
        }
    }
    func stopChatCycle() {
        chatCycleTimer?.invalidate()
        chatCycleTimer = nil
    }

    func renderAssistantChat(_ analysis: AnalysisResult, trackName: String?) {
        clearChat()
        if let name = trackName {
            addChat("on it — reading **\(name)** now.", tone: .greeting)
        }
        chat.append(contentsOf: analysis.chat)
        assistantStatus = "analysis ready · your call"
        visibleChatIdx = 0 // wholesale rebuild resets to the top
    }

    func addToHistory(name: String, path: URL) {
        history.insert(HistoryItem(name: name, path: path), at: 0)
        if history.count > 25 { history.removeLast() }
    }

    // MARK: single-track flow

    func handleFileSelection(_ url: URL) {
        exitBatchMode()
        stopPreview()
        clearPreviewCache()
        currentFile = url
        currentAnalysis = nil
        addLog("Target: \(url.lastPathComponent)")
        progress = 0
        isAnalyzing = true
        assistantStatus = "auditing signal dna…"
        clearChat()
        addChat("auditing signal dna…", tone: .working)

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let engine = try AnalysisEngine(url: url) { pct in
                    Task { @MainActor [weak self] in self?.progress = Double(pct) / 100 }
                }
                let result = engine.runFullAnalysis()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.currentAnalysis = result
                    self.renderAssistantChat(result, trackName: result.title)
                    self.addLog("DNA mapped. Hybrid compensation plan initialized.")
                    self.isAnalyzing = false
                    self.generatePreviews(file: url, metrics: result.metrics)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.addLog("CRITICAL: \(error.localizedDescription)")
                    self.addChat("hmm, i couldn't read that one — \(error.localizedDescription). try a wav or flac and i'll take another pass.",
                                 tone: .caution, title: "hit a snag")
                    self.isAnalyzing = false
                }
            }
        }
    }

    func masterCurrentTrack() {
        guard let analysis = currentAnalysis, let file = currentFile, !isMastering else { return }
        isMastering = true
        let mode = masteringMode
        addLog("Initiating \(mode.displayName) processing sequence...")
        addLog("Applying Hybrid Analog Compensation...")
        addChat("printing your master now with **\(mode.displayName)** — tailored to this track's read. one sec.",
                tone: .working, title: "mastering")

        let metrics = analysis.metrics
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.runMaster(input: file, metrics: metrics, mode: mode)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isMastering = false
                switch result {
                case .success(let master):
                    let displayName = master.outputPath.deletingPathExtension().lastPathComponent
                    self.addToHistory(name: "MASTER: \(displayName)", path: master.outputPath)
                    self.addLog("SEQUENCE COMPLETE (\(master.engineMode.chatLabel)). Exported to resonance masters/")
                    self.addChat("done — mastered with **\(master.engineMode.chatLabel)**. master's in **resonance masters/** folder. trust your ears over the meters.",
                                 tone: .done, title: nil)
                    if let video = master.videoPath {
                        self.addToHistory(name: "VIDEO: \(video.deletingPathExtension().lastPathComponent)", path: video)
                        self.addChat("your video's ready too — **\(video.lastPathComponent)** carries the original picture with the mastered sound, lossless. drop it straight into your edit or upload.",
                                     tone: .done, title: nil)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([master.videoPath ?? master.outputPath])
                case .failure(let error):
                    self.addLog("EXECUTION ERROR: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Master one file: chain render + original reference copy.
    nonisolated static func runMaster(input: URL, metrics: Metrics, mode: MasteringMode = .core) -> Result<MasterResult, Error> {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: masterDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: originalDir, withIntermediateDirectories: true)

            let naming = MasterNamer.generate(in: masterDir)
            let output = masterDir.appendingPathComponent("\(naming.masterName).wav")
            _ = try MasteringEngine().render(mode: mode, input: input, output: output, metrics: metrics)

            let meta: [String: String] = ["engine": mode.rawValue]
            let metaURL = masterDir.appendingPathComponent("\(naming.masterName).meta.json")
            let metaData = try JSONSerialization.data(withJSONObject: meta, options: [])
            try metaData.write(to: metaURL)

            var warning: String?
            let origExt = input.pathExtension.lowercased()
            let origCopy = originalDir.appendingPathComponent("\(naming.originalName).\(origExt)")
            do {
                try? fm.removeItem(at: origCopy)
                try fm.copyItem(at: input, to: origCopy)
            } catch {
                warning = "Failed to copy original: \(error.localizedDescription)"
            }

            // Video source: print the picture back with the mastered sound.
            var videoPath: URL?
            if VideoAudio.isVideo(input) {
                do {
                    let movieOut = masterDir.appendingPathComponent("\(naming.masterName).mov")
                    try VideoAudio.muxMasteredAudio(video: input, masteredAudio: output, output: movieOut)
                    videoPath = movieOut
                } catch {
                    warning = (warning.map { $0 + " · " } ?? "") + "Video remux failed: \(error.localizedDescription)"
                }
            }

            return .success(MasterResult(outputPath: output, comparisonPath: origCopy,
                                         abSamplePath: nil, videoPath: videoPath,
                                         warning: warning, abWarning: nil,
                                         engineMode: mode))
        } catch {
            return .failure(error)
        }
    }

    // MARK: batch flow

    func loadBatch(_ urls: [URL]) {
        let seed = masteringMode
        batchTracks = urls.map { BatchTrack(url: $0, name: $0.lastPathComponent, mode: seed) }
        currentAnalysis = nil
        addLog("Batch loaded: \(batchTracks.count) tracks.")
        clearPreviewCache()
        clearChat()
        addChat("loaded **\(batchTracks.count) tracks**. i'll analyze each one individually and give every track its own custom master — no blanket presets. hit **master all** when you're ready, or tap any track to see its read.",
                tone: .greeting, title: "batch ready")
        visibleChatIdx = 0
        assistantStatus = "\(batchTracks.count) tracks queued"
        analyzeBatchSequentially()
    }

    func exitBatchMode() { batchTracks.removeAll() }

    /// Per-track engine control: change one pending track's engine.
    func setBatchTrackMode(_ id: BatchTrack.ID, _ mode: MasteringMode) {
        guard let i = batchTracks.firstIndex(where: { $0.id == id }) else { return }
        batchTracks[i].mode = mode
        addLog("Batch engine: \(batchTracks[i].name) → \(mode.displayName)")
    }

    /// Push the global engine onto every track that hasn't started yet.
    func applyGlobalModeToPendingBatch() {
        let mode = masteringMode
        for i in batchTracks.indices where batchTracks[i].status == .queued || batchTracks[i].status == .ready {
            batchTracks[i].mode = mode
        }
        addLog("Batch engine: pending tracks → \(mode.displayName)")
    }

    func showTrackRead(_ track: BatchTrack) {
        guard let analysis = track.analysis else { return }
        stopPreview()
        currentAnalysis = analysis
        currentFile = track.url
        renderAssistantChat(analysis, trackName: track.name)
        if track.status == .done, let out = track.outputPath {
            NSWorkspace.shared.activateFileViewerSelecting([out])
        }
    }

    private func analyzeBatchSequentially() {
        Task { [weak self] in
            guard let self else { return }
            for index in self.batchTracks.indices {
                guard self.batchTracks.indices.contains(index),
                      self.batchTracks[index].analysis == nil else { continue }
                self.batchTracks[index].status = .analyzing
                self.assistantStatus = "analyzing \(self.batchTracks[index].name)…"
                let url = self.batchTracks[index].url
                let result: Result<AnalysisResult, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let engine = try AnalysisEngine(url: url)
                        return .success(engine.runFullAnalysis())
                    } catch {
                        return .failure(error)
                    }
                }.value
                guard self.batchTracks.indices.contains(index) else { return }
                switch result {
                case .success(let analysis):
                    self.batchTracks[index].analysis = analysis
                    self.batchTracks[index].status = .ready
                    self.generatePreviews(file: url, metrics: analysis.metrics,
                                          trackId: self.batchTracks[index].name)
                case .failure(let error):
                    self.batchTracks[index].status = .error
                    self.addLog("Analysis failed for \(self.batchTracks[index].name): \(error.localizedDescription)")
                }
            }
            let readyCount = self.batchTracks.filter { $0.status == .ready }.count
            self.assistantStatus = "\(readyCount) tracks analyzed"
            self.addChat("done analyzing — each track's read is saved. tap any one to see its details. when you hit **master all**, i'll process them one by one, each with its own tailored chain.",
                         tone: .plan, title: "all analyzed")
            if let first = self.batchTracks.first(where: { $0.analysis != nil }) {
                self.showTrackRead(first)
            }
        }
    }

    func runBatchMaster() {
        guard !isBatchRunning else { return }
        isBatchRunning = true
        let mode = masteringMode
        addChat("starting the batch with **\(mode.displayName)**. i'll tailor each master to its own analysis — the loud ones get eased off, the dark ones get lifted. sit back.",
                tone: .working, title: "mastering all")

        Task { [weak self] in
            guard let self else { return }
            for index in self.batchTracks.indices {
                guard self.batchTracks.indices.contains(index),
                      let analysis = self.batchTracks[index].analysis else { continue }
                let trackMode = self.batchTracks[index].mode
                self.batchTracks[index].status = .mastering
                self.assistantStatus = "mastering \(self.batchTracks[index].name)…"
                self.addLog("MASTER: \(self.batchTracks[index].name) [\(trackMode.displayName)]")
                let url = self.batchTracks[index].url
                let metrics = analysis.metrics
                let result: Result<MasterResult, Error> = await Task.detached(priority: .userInitiated) {
                    Self.runMaster(input: url, metrics: metrics, mode: trackMode)
                }.value
                guard self.batchTracks.indices.contains(index) else { return }
                switch result {
                case .success(let master):
                    self.batchTracks[index].outputPath = master.outputPath
                    self.batchTracks[index].status = .done
                    let displayName = master.outputPath.deletingPathExtension().lastPathComponent
                    self.addToHistory(name: "MASTER: \(displayName)", path: master.outputPath)
                case .failure(let error):
                    self.batchTracks[index].status = .error
                    self.addLog("Master failed for \(self.batchTracks[index].name): \(error.localizedDescription)")
                }
            }
            self.isBatchRunning = false
            let doneCount = self.batchTracks.filter { $0.status == .done }.count
            self.assistantStatus = "\(doneCount) tracks mastered"
            self.addChat("batch complete — **\(doneCount) of \(self.batchTracks.count)** mastered, each with its own treatment. everything's in your **resonance masters/** folder. tap any track to reveal it. nice work.",
                         tone: .done, title: nil)
        }
    }

    // MARK: 10-second audition previews

    nonisolated static var previewCacheDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("resonance-previews", isDirectory: true)
    }

    /// Center `seconds` of the buffer — the middle slice every engine auditions.
    nonisolated static func middleSlice(buffer: AudioBuffer, seconds: Double = 10) -> AudioBuffer {
        let fs = buffer.sampleRate
        let want = max(1, Int(seconds * fs))
        let total = buffer.frameCount
        guard total > want else { return buffer }
        let start = (total - want) / 2
        return AudioBuffer(channels: buffer.channels.map { Array($0[start ..< start + want]) },
                           sampleRate: fs)
    }

    func clearPreviewCache() {
        stopPreview()
        previewURLs = [:]
        batchPreviewMap = [:]
        previewGenerating = false
        previewProgressMode = nil
        try? FileManager.default.removeItem(at: Self.previewCacheDir)
    }

    /// Preview map for whatever is on screen (batch resolves via analysis title).
    func previewMapForCurrent() -> [MasteringMode: URL] {
        if isBatchMode, let title = currentAnalysis?.title,
           let map = batchPreviewMap[title] { return map }
        return previewURLs
    }

    func isPreviewReady(_ mode: MasteringMode) -> Bool { previewMapForCurrent()[mode] != nil }

    /// Render the middle 10 seconds in every engine. Track-scoped when trackId is set.
    func generatePreviews(file: URL, metrics: Metrics, trackId: String? = nil) {
        previewGenerating = true
        previewProgressMode = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            var map: [MasteringMode: URL] = [:]
            do {
                let buffer = try AudioLoader.load(url: file)
                let slice = Self.middleSlice(buffer: buffer, seconds: 10)
                let dir = Self.previewCacheDir
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stem = file.deletingPathExtension().lastPathComponent
                let sliceURL = dir.appendingPathComponent("\(stem)-slice.wav")
                try WavWriter.write(channels: slice.channels, sampleRate: slice.sampleRate,
                                    to: sliceURL, bitDepth: 16)
                for mode in MasteringMode.allCases {
                    await MainActor.run { [weak self] in self?.previewProgressMode = mode }
                    let out = dir.appendingPathComponent("\(stem)-preview-\(mode.rawValue).wav")
                    _ = try MasteringEngine().render(mode: mode, input: sliceURL, output: out, metrics: metrics)
                    map[mode] = out
                }
                try? FileManager.default.removeItem(at: sliceURL)
            } catch {
                await MainActor.run { [weak self] in
                    self?.addLog("Preview render failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let id = trackId {
                    self.batchPreviewMap[id] = map
                } else {
                    self.previewURLs = map
                }
                self.previewGenerating = false
                self.previewProgressMode = nil
                if !map.isEmpty {
                    self.assistantStatus = "previews ready · tap an engine to audition"
                    self.addLog("10-sec previews ready (\(map.count) engines).")
                }
            }
        }
    }

    /// Play (or toggle off) an engine's 10-second audition.
    func playPreview(_ mode: MasteringMode, trackId: String? = nil) {
        let map: [MasteringMode: URL]
        if let id = trackId, let m = batchPreviewMap[id] { map = m }
        else { map = previewMapForCurrent() }
        guard let url = map[mode] else { return }
        if playingPreviewMode == mode, previewPlayer?.isPlaying == true {
            stopPreview()
            return
        }
        stopPreview()
        do {
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.play()
            playingPreviewMode = mode
            assistantStatus = "auditioning 10 sec — middle slice"
            let dur = previewPlayer?.duration ?? 10
            previewStopTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stopPreview() }
            }
        } catch {
            addLog("Preview playback failed: \(error.localizedDescription)")
        }
    }

    func stopPreview() {
        previewStopTimer?.invalidate()
        previewStopTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        playingPreviewMode = nil
    }

    // MARK: file intake

    func intake(urls: [URL]) {
        let audioExts = ["mp3", "wav", "m4a", "flac", "aif", "aiff"]
        let audio = urls.filter {
            audioExts.contains($0.pathExtension.lowercased()) || VideoAudio.isVideo($0)
        }
        guard !audio.isEmpty else { return }
        if audio.count == 1 {
            handleFileSelection(audio[0])
        } else {
            loadBatch(audio)
        }
    }
}
