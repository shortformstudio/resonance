import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var player = PlayerController()

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 280)
            Divider().overlay(Theme.glassBorder)
            MainContent()
        }
        .environmentObject(player)
        .background(Theme.bg)
        .foregroundStyle(Theme.textPrimary)
        .onAppear { FilePicker.shared.warm() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadFileURL() { urls.append(url) }
                }
                state.intake(urls: urls)
            }
            return true
        }
    }
}

extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: url) }
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("resonance")
                .font(.system(size: 21, weight: .light))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 30)
            DropZone()
            if let analysis = state.currentAnalysis {
                TrackMetadata(analysis: analysis)
                Group {
                    if state.isBatchMode {
                        MasterButton(title: "Master All",
                                     disabled: state.isBatchRunning || state.batchTracks.allSatisfy { $0.analysis == nil }) {
                            state.runBatchMaster()
                        }
                    } else {
                        MasterButton(title: "Master",
                                     disabled: state.currentAnalysis == nil || state.isMastering || state.isAnalyzing) {
                            state.masterCurrentTrack()
                        }
                    }
                }
                if state.isBatchMode == false {
                    ModePicker(analysis: analysis)
                }
            }
            SectionHeader("PROCESS")
            StatusLog()
                .infoHover(Info.statusLog)
            InfoBoxView()
            Spacer(minLength: 0)
            Text("shortform studio")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(16)
        .padding(.top, 24)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(Theme.textSecondary)
    }
}

struct DropZone: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Text("⏀")
                .font(.system(size: 30))
                .foregroundStyle(Theme.accent)
            Button("AUDIO / VIDEO FILE(S)") { pickFiles() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Theme.accentDim)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("DRAG & DROP TRACK(S) OR VIDEO(S)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            if state.isAnalyzing {
                VStack(spacing: 4) {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    Text("analyzing the track…")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.glassBorder, style: StrokeStyle(lineWidth: 1, dash: [5]))
        )
        .background(Theme.glassBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .infoHover(Info.dropZone)
    }

    private func pickFiles() {
        FilePicker.shared.present { urls in
            state.intake(urls: urls)
        }
    }
}

struct TrackMetadata: View {
    let analysis: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(analysis.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            Text("\(analysis.duration) • \(analysis.format)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Text("VOLUME")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(analysis.metrics.truePeakDb, specifier: "%.2f") dB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }
}

struct StatusLog: View {
    @EnvironmentObject var state: AppState

    private var statusLine: String {
        if state.isMastering { return "mastering…" }
        if state.isAnalyzing { return "analyzing…" }
        if state.isBatchRunning { return "batch running…" }
        if state.currentAnalysis != nil { return "analysis ready" }
        return "idle"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.log.suffix(12)) { entry in
                            Text("[\(entry.time)] \(entry.message)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 100)
                .glass()
                .onChange(of: state.log.count) {
                    if let last = state.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var statusColor: Color {
        if state.isMastering || state.isBatchRunning { return Theme.caution }
        if state.isAnalyzing { return Theme.accent }
        if state.currentAnalysis != nil { return Theme.good }
        return Theme.textSecondary
    }
}

struct HistoryList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.history.isEmpty {
                Text("No recent masters.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
            } else {
                ForEach(state.history) { item in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([item.path])
                    } label: {
                        Text(item.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to reveal: \(item.path.path)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass()
    }
}

// MARK: - Main column

struct MainContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ChatPanel()
                    .frame(width: 370, height: 370)
                StatsPanel()
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 24)

            if state.isBatchMode {
                BatchQueue()
            }

            MasterLibraryGrid()
                .frame(maxWidth: .infinity, minHeight: 200)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}

struct ChatPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("◉").foregroundStyle(Theme.accent).font(.system(size: 13))
                Spacer()
                Text(state.assistantStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.chat) { bubble in
                            ChatBubbleView(bubble: bubble).id(bubble.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
                .onChange(of: state.chat.count) {
                    if let last = state.chat.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .glass()
        .infoHover(Info.chat)
    }
}

struct StatsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            if let analysis = state.currentAnalysis {
                AuditPanel(analysis: analysis)
                MetricsGrid(metrics: analysis.metrics)
                WaveformView(waveform: analysis.waveform)
                    .frame(height: 90)
                    .glass()
                    .infoHover(Info.waveform)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        MetricCard(title: "LOUDNESS", value: "— LUFS",
                                   help: "LOUDNESS: Measured in LUFS. Target: -14 LUFS.", info: Info.loudness)
                        MetricCard(title: "SPECTRAL", value: "—",
                                   help: "SPECTRAL: Ideal slope ~1.3 (Pink Noise).", info: Info.spectral)
                        MetricCard(title: "WIDTH", value: "—",
                                   help: "WIDTH: Correlation +1.0 is mono.", info: Info.width)
                    }
                    Spacer()
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.glassBorder, style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .background(Theme.glassBg)
                        VStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.textSecondary.opacity(0.3))
                            Text("waveform appears here")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.4))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct ChatBubbleView: View {
    let bubble: ChatBubble

    private var toneColor: Color {
        switch bubble.tone {
        case .good, .done: return Theme.good
        case .caution: return Theme.caution
        case .plan, .working: return Theme.accent
        default: return Theme.textPrimary.opacity(0.7)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = bubble.title {
                HStack(spacing: 5) {
                    Text(bubble.tone.icon).foregroundStyle(toneColor)
                    Text(title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(toneColor)
                }
            }
            Text(markdown(bubble.text))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(toneColor.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

struct BatchQueue: View {
    @EnvironmentObject var state: AppState

    private func statusColor(_ s: BatchStatus) -> Color {
        switch s {
        case .done, .ready: return Theme.good
        case .error: return Theme.danger
        case .analyzing, .mastering: return Theme.caution
        case .queued: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BATCH QUEUE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(state.batchTracks.filter { $0.status == .done }.count) / \(state.batchTracks.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(state.batchTracks) { track in
                        Button { state.showTrackRead(track) } label: {
                            HStack {
                                Text(track.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Spacer()
                                if let a = track.analysis {
                                    Text("\(a.metrics.integratedLufs, specifier: "%.2f") LUFS · slope \(a.metrics.spectralSlope, specifier: "%.3f")")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Text(track.status.label)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(statusColor(track.status))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(10)
        .glass()
        .infoHover(Info.batchQueue)
    }
}

struct AuditPanel: View {
    let analysis: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("audit")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("SIGNAL DNA AUDIT")
                        .infoHover(Info.dnaAudit)
                    AuditItem(label: "Loudness", value: "\(fmt(analysis.metrics.integratedLufs)) LUFS",
                              comment: loudnessComment)
                        .infoHover(Info.loudness)
                    AuditItem(label: "Spectral", value: fmt3(analysis.metrics.spectralSlope),
                              comment: spectralComment)
                        .infoHover(Info.spectral)
                    AuditItem(label: "Stereo", value: fmt3(analysis.metrics.correlation),
                              comment: stereoComment)
                        .infoHover(Info.width)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("TANDEM COMPENSATION PLAN")
                        .infoHover(Info.compensationPlan)
                    ForEach(proposedChain, id: \.0) { name, detail, info in
                        AuditItem(label: name, value: detail, comment: nil)
                            .infoHover(info)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .glass()
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }

    private var loudnessComment: String {
        let lufs = analysis.metrics.integratedLufs
        if lufs < -20 { return "Signal is extremely anemic. We're missing the saturation 'floor'—ready for a significant thermal lift." }
        if lufs > -10 { return "Signal is aggressively hot. We're trading dynamic impact for raw RMS density." }
        return "Healthy gain structure. Perfect foundation for transparent finalization."
    }

    private var spectralComment: String {
        let slope = analysis.metrics.spectralSlope
        if slope > 1.6 { return "Heavy low-mid accumulation. It's creating a 'sonic fog' that masks upper-harmonic detail." }
        if slope < 1.1 { return "Top-heavy bias. Mix feels brittle and lacks mechanical weight in the 200Hz chest region." }
        return "Elegant spectral distribution. Sitting in a professional pink-noise pocket."
    }

    private var stereoComment: String {
        analysis.metrics.correlation < 0.4
            ? "Critical phase incoherence. Image collapse likely in mono. Tightening center focus."
            : "Solid stereo integrity. Field is wide but focused and phase-coherent."
    }

    private var proposedChain: [(String, String, HoverInfo)] {
        let m = analysis.metrics
        return [
            ("Sub-Sonic Control", m.spectralSlope > 1.4 ? "35Hz HPF" : "30Hz HPF", Info.subSonic),
            ("Organic Heat", m.integratedLufs < -18 ? "+1.5dB Drive" : "+1.0dB Drive", Info.organicHeat),
            ("Spectral Balancing",
             m.spectralSlope > 1.4 ? String(format: "Mud Cut @ %.0fHz", m.mudCenterHz) : "Air Excitation",
             Info.spectralBalancing),
            ("Spatial Width", m.correlation > 0.7 ? "M/S Expansion" : (m.correlation < 0.6 ? "Sub Mono-Fold" : "Image Hold"), Info.spatialWidth),
            ("Program Glue", m.integratedLufs > -12 ? "1.2:1 Soft Knee" : "1.5:1 Soft Knee", Info.programGlue),
            ("Final Offset", "→ -14.0 LUFS exact", Info.finalOffset)
        ]
    }
}

struct AuditItem: View {
    let label: String
    let value: String
    let comment: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(label):")
                    .font(.system(size: 11, weight: .medium))
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            if let comment {
                Text(comment)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MetricsGrid: View {
    let metrics: Metrics

    var body: some View {
        HStack(spacing: 14) {
            MetricCard(title: "LOUDNESS", value: String(format: "%.2f", metrics.integratedLufs),
                       help: "LOUDNESS: Measured in LUFS. Target: -14 LUFS.", info: Info.loudness)
            MetricCard(title: "SPECTRAL", value: String(format: "%.3f", metrics.spectralSlope),
                       help: "SPECTRAL: Ideal slope ~1.3 (Pink Noise).", info: Info.spectral)
            MetricCard(title: "WIDTH", value: String(format: "%.3f", metrics.correlation),
                       help: "WIDTH: Correlation +1.0 is mono.", info: Info.width)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let help: String
    let info: HoverInfo

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 22, weight: .light, design: .monospaced))
                .foregroundStyle(Theme.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glass()
        .help(help)
        .infoHover(info)
    }
}

struct WaveformView: View {
    let waveform: WaveformData
    @State private var playhead: CGFloat = 0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            let count = waveform.data.count
            guard count > 0 else { return }
            let spacing = size.width / CGFloat(count)
            let barWidth = max(1, spacing * 0.7)
            let midY = size.height / 2

            for (i, value) in waveform.data.enumerated() {
                let h = max(1.5, CGFloat(value) * (size.height * 0.9))
                let x = CGFloat(i) * spacing
                let isRed = i < waveform.redlines.count && waveform.redlines[i]
                let color = isRed ? Theme.redline : Theme.accent.opacity(0.85)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
            }

            let headX = playhead * size.width
            context.fill(Path(CGRect(x: headX, y: 0, width: 1.5, height: size.height)),
                         with: .color(.white.opacity(0.25)))
        }
        .padding(10)
        .onReceive(timer) { _ in
            playhead += 1.0 / (30.0 * 12.0)
            if playhead > 1 { playhead = 0 }
        }
    }
}

// MARK: - Master Library Grid (2 columns, 8 latest, context menu)

struct MasterLibraryGrid: View {
    @EnvironmentObject var player: PlayerController
    @State private var hoveredPair: MasterPair?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MASTER LIBRARY")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if player.hasLegacyFiles {
                    Button { player.migrateLegacyFiles() } label: {
                        Text("MIGRATE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.caution)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.caution.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .help("Rename legacy files to new naming scheme")
                }
                Text("\(player.pairs.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }

            if player.current != nil { PlayerBar() }

            if player.pairs.isEmpty {
                Text("Masters land here as you print them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let latest = Array(player.pairs.prefix(8))
                let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(latest) { pair in
                            LibraryCell(pair: pair, hovered: $hoveredPair)
                                .contextMenu {
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([pair.masterURL])
                                    }
                                    Button("Export Master Again") {
                                        let panel = NSSavePanel()
                                        panel.nameFieldStringValue = pair.masterURL.lastPathComponent
                                        panel.begin { response in
                                            if response == .OK, let dest = panel.url {
                                                try? FileManager.default.copyItem(at: pair.masterURL, to: dest)
                                            }
                                        }
                                    }
                                    if let orig = pair.originalURL {
                                        Divider()
                                        Button("Reveal Original") {
                                            NSWorkspace.shared.activateFileViewerSelecting([orig])
                                        }
                                        Button("Remaster Original") {
                                            let openPanel = NSOpenPanel()
                                            openPanel.directoryURL = orig.deletingLastPathComponent()
                                            openPanel.nameFieldStringValue = orig.lastPathComponent
                                            openPanel.allowedContentTypes = [.audio]
                                            openPanel.begin { _ in
                                                if let url = openPanel.url {
                                                    Task { @MainActor in
                                                        NotificationCenter.default.post(name: .init("resonanceRemaster"), object: url)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .padding(10)
        .glass()
        .infoHover(Info.library)
        .onAppear { player.start() }
    }
}

struct LibraryCell: View {
    @EnvironmentObject var player: PlayerController
    let pair: MasterPair
    @Binding var hovered: MasterPair?

    private var isCurrent: Bool { player.current == pair }

    var body: some View {
        Button { player.select(pair) } label: {
            HStack(spacing: 5) {
                Image(systemName: isCurrent && player.isPlaying ? "waveform" : "play.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textSecondary)
                    .frame(width: 10)
                Text(pair.baseName)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary.opacity(0.85))
                Spacer()
                if let engine = pair.engineMode {
                    Text(engine.displayName)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.6))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(isCurrent ? Color.white.opacity(0.05) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(isCurrent ? Theme.accent.opacity(0.25) : .clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in hovered = hovering ? pair : nil }
    }
}

struct PlayerBar: View {
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).keyboardShortcut(.space, modifiers: [])

                Text(player.current?.baseName ?? "")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer()

                if player.current?.originalURL != nil {
                    Button { player.flip() } label: {
                        Text(player.hearingOriginal ? "ORIGINAL" : "MASTER")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(player.hearingOriginal ? Theme.caution.opacity(0.15) : Theme.accentDim)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(player.hearingOriginal ? Theme.caution : Theme.accent, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(player.hearingOriginal ? Theme.caution : Theme.accent)
                    }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: [])
                }
            }
            HStack(spacing: 4) {
                Text(clock(player.position)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(get: { min(player.position, player.duration) }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.01)).controlSize(.mini).tint(Theme.accent)
                Text(clock(player.duration)).font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct ModePicker: View {
    @EnvironmentObject var state: AppState
    let analysis: AnalysisResult

    var body: some View {
        HStack(spacing: 8) {
            Text("ENGINE:")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Picker("", selection: Binding(
                get: { state.masteringMode },
                set: { state.masteringMode = $0 }
            )) {
                ForEach(MasteringMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .onChange(of: state.masteringMode) { old, new in
                state.addLog("Engine switched to \(new.displayName)")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.glassBg)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.glassBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct MasterButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1)
                .padding(.horizontal, 28).padding(.vertical, 12)
                .background(disabled ? Theme.accentDim.opacity(0.4) : Theme.accentDim)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(disabled ? Theme.glassBorder : Theme.accent, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(disabled ? Theme.textSecondary : Theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private func clock(_ t: TimeInterval) -> String {
    guard t.isFinite && t > 0 else { return "--:--" }
    return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
}
