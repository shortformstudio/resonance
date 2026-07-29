import Foundation
import SwiftUI

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
    @AppStorage("masteringModeRaw") var masteringModeRaw: String = MasteringMode.resonanceV2.rawValue
    var masteringMode: MasteringMode {
        get { MasteringMode(rawValue: masteringModeRaw) ?? .resonanceV2 }
        set { masteringModeRaw = newValue.rawValue }
    }

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
    }

    func clearChat() { chat.removeAll() }

    func renderAssistantChat(_ analysis: AnalysisResult, trackName: String?) {
        clearChat()
        if let name = trackName {
            addChat("on it — reading **\(name)** now.", tone: .greeting)
        }
        chat.append(contentsOf: analysis.chat)
        assistantStatus = "analysis ready · your call"
    }

    func addToHistory(name: String, path: URL) {
        history.insert(HistoryItem(name: name, path: path), at: 0)
        if history.count > 25 { history.removeLast() }
    }

    // MARK: single-track flow

    func handleFileSelection(_ url: URL) {
        exitBatchMode()
        currentFile = url
        currentAnalysis = nil
        addLog("Target: \(url.lastPathComponent)")
        progress = 0
        isAnalyzing = true
        assistantStatus = "auditing signal dna…"

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
    nonisolated static func runMaster(input: URL, metrics: Metrics, mode: MasteringMode = .resonanceV2) -> Result<MasterResult, Error> {
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
        batchTracks = urls.map { BatchTrack(url: $0, name: $0.lastPathComponent) }
        currentAnalysis = nil
        addLog("Batch loaded: \(batchTracks.count) tracks.")
        clearChat()
        addChat("loaded **\(batchTracks.count) tracks**. i'll analyze each one individually and give every track its own custom master — no blanket presets. hit **master all** when you're ready, or tap any track to see its read.",
                tone: .greeting, title: "batch ready")
        assistantStatus = "\(batchTracks.count) tracks queued"
        analyzeBatchSequentially()
    }

    func exitBatchMode() { batchTracks.removeAll() }

    func showTrackRead(_ track: BatchTrack) {
        guard let analysis = track.analysis else { return }
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
                self.batchTracks[index].status = .mastering
                self.assistantStatus = "mastering \(self.batchTracks[index].name)…"
                let url = self.batchTracks[index].url
                let metrics = analysis.metrics
                let result: Result<MasterResult, Error> = await Task.detached(priority: .userInitiated) {
                    Self.runMaster(input: url, metrics: metrics, mode: mode)
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
