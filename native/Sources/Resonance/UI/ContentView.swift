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
                MasterOptionsPanel(analysis: analysis)
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

    private var visibleBubble: ChatBubble? {
        guard !state.chat.isEmpty else { return nil }
        let idx = min(max(state.visibleChatIdx, 0), state.chat.count - 1)
        return state.chat[idx]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("◉").foregroundStyle(Theme.accent).font(.system(size: 13))
                Spacer()
                Button {
                    state.chatPaused.toggle()
                } label: {
                    Image(systemName: state.chatPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                Text(state.assistantStatus)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .id(state.assistantStatus)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)

            // Single-blurb viewport: exactly one mastering-expert blurb at a time.
            ZStack {
                if let bubble = visibleBubble {
                    ChatBubbleView(bubble: bubble)
                        .id(bubble.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .onTapGesture { state.advanceChat() }
                }
            }
            .animation(.easeInOut(duration: 0.62), value: state.visibleChatIdx)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 10).padding(.bottom, 4)

            // Dot indicators 1/N.
            if state.chat.count > 1 {
                HStack(spacing: 5) {
                    Spacer()
                    ForEach(state.chat.indices, id: \.self) { i in
                        Circle()
                            .fill(i == state.visibleChatIdx ? Theme.accent : Theme.textSecondary.opacity(0.3))
                            .frame(width: 5, height: 5)
                            .onTapGesture { state.visibleChatIdx = i }
                    }
                    Spacer()
                }
                .padding(.bottom, 8)
            }
        }
        .glass()
        .infoHover(Info.chat)
        .onAppear { state.startChatCycle() }
        .onDisappear { state.stopChatCycle() }
        .onChange(of: state.currentAnalysis?.title) { state.resetChatView() }
        .onChange(of: state.isAnalyzing) { state.resetChatView() }
    }
}

struct StatsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            if let analysis = state.currentAnalysis {
                AuditPanel()
                MetricsGrid(metrics: analysis.metrics)
                DynamicsStrip(dynamics: analysis.dynamics)
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
                        HStack {
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
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Picker("", selection: Binding(
                                get: { track.mode },
                                set: { state.setBatchTrackMode(track.id, $0) }
                            )) {
                                ForEach(MasteringMode.allCases, id: \.self) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            Text(track.status.label)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(statusColor(track.status))
                        }
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
    @EnvironmentObject var state: AppState

    private var analysis: AnalysisResult? { state.currentAnalysis }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("audit")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Text("\(state.masteringMode.displayName) · \(state.masteringMode.targetLabel)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.5)))
            }

            if let analysis {
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
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(modeChain, id: \.0) { name, detail, info in
                                    AuditItem(label: name, value: detail, comment: nil)
                                        .infoHover(info)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .glass()
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    private func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Chain for the selected engine, tuned to the current read.
    private var modeChain: [(String, String, HoverInfo)] {
        guard let analysis else { return [] }
        return state.masteringMode.chainPreview(metrics: analysis.metrics)
    }

    private var loudnessComment: String {
        guard let analysis else { return "" }
        let lufs = analysis.metrics.integratedLufs
        if lufs < -20 { return "Signal is extremely anemic. We're missing the saturation 'floor'—ready for a significant thermal lift." }
        if lufs > -10 { return "Signal is aggressively hot. We're trading dynamic impact for raw RMS density." }
        return "Healthy gain structure. Perfect foundation for transparent finalization."
    }

    private var spectralComment: String {
        guard let analysis else { return "" }
        let slope = analysis.metrics.spectralSlope
        if slope > 1.6 { return "Heavy low-mid accumulation. It's creating a 'sonic fog' that masks upper-harmonic detail." }
        if slope < 1.1 { return "Top-heavy bias. Mix feels brittle and lacks mechanical weight in the 200Hz chest region." }
        return "Elegant spectral distribution. Sitting in a professional pink-noise pocket."
    }

    private var stereoComment: String {
        guard let analysis else { return "" }
        return analysis.metrics.correlation < 0.4
            ? "Critical phase incoherence. Image collapse likely in mono. Tightening center focus."
            : "Solid stereo integrity. Field is wide but focused and phase-coherent."
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
        HStack(spacing: 10) {
            MetricCard(title: "LOUDNESS", value: String(format: "%.2f", metrics.integratedLufs),
                       help: "LOUDNESS: Measured in LUFS. Target: -14 LUFS.", info: Info.loudness)
            MetricCard(title: "SPECTRAL", value: String(format: "%.3f", metrics.spectralSlope),
                       help: "SPECTRAL: Ideal slope ~1.3 (Pink Noise).", info: Info.spectral)
            MetricCard(title: "WIDTH", value: String(format: "%.3f", metrics.correlation),
                       help: "WIDTH: Correlation +1.0 is mono.", info: Info.width)
            MetricCard(title: "RANGE", value: String(format: "%.1f LU", metrics.lra),
                       help: "RANGE: Loudness range across the track. Under 7 is tight and modern; over 9 breathes wide and may need section riding.", info: Info.dynamicsRange)
            MetricCard(title: "CREST", value: String(format: "%.1f dB", metrics.crestFactorDb),
                       help: "CREST: Peak-to-average ratio. High crest means punchy transients; low crest means dense and loud.", info: Info.crestFactor)
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

struct DynamicsStrip: View {
    let dynamics: DynamicsReport

    private var peak: Double { dynamics.sections.map(\.lufs).max() ?? 0 }
    private var floor: Double { dynamics.sections.map(\.lufs).min() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("SECTION DYNAMICS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "spread %.1f dB · LRA %.1f LU", dynamics.sectionSpreadDb, dynamics.lra))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(dynamics.sections.indices, id: \.self) { i in
                    let s = dynamics.sections[i]
                    let span = max(peak - floor, 0.5)
                    let h = max(6, CGFloat((s.lufs - floor) / span) * 44)
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent.opacity(0.35 + 0.55 * Double(h / 50)))
                            .frame(height: h)
                        Text(String(format: "%.0f", s.lufs))
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "section %d · %.0fs · %.1f LUFS · LRA %.1f · crest %.1f dB",
                                 i + 1, s.startSec, s.lufs, s.lra, s.crestDb))
                }
            }
            .frame(height: 64)
        }
        .padding(10)
        .glass()
        .infoHover(Info.sectionTrim)
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

// MARK: - Master options (engine cards before print)

struct MasterOptionsPanel: View {
    @EnvironmentObject var state: AppState
    let analysis: AnalysisResult

    private var suggested: MasteringMode { MasteringMode.recommended(for: analysis.metrics) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW TO MASTER")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(MasteringMode.allCases, id: \.self) { mode in
                    ModeCard(mode: mode,
                             suggested: mode == suggested,
                             isGenerating: state.previewGenerating && state.previewProgressMode == mode,
                             isReady: state.isPreviewReady(mode),
                             isPlaying: state.playingPreviewMode == mode)
                }
            }
            Text(state.playingPreviewMode != nil
                 ? "auditioning 10 sec — middle slice"
                 : (state.previewGenerating ? "rendering 10 sec preview…" : "tap to audition 10 sec"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
        }
        .infoHover(Info.modePicker)
    }
}

struct ModeCard: View {
    @EnvironmentObject var state: AppState
    let mode: MasteringMode
    let suggested: Bool
    let isGenerating: Bool
    let isReady: Bool
    let isPlaying: Bool

    private var isSelected: Bool { state.masteringMode == mode }

    var body: some View {
        Button {
            state.masteringMode = mode
            state.applyGlobalModeToPendingBatch()
            state.addLog("Engine switched to \(mode.displayName)")
            state.playPreview(mode)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(mode.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                    if suggested {
                        Text("★")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    if isPlaying {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                    } else if isGenerating {
                        ProgressView()
                            .controlSize(.mini)
                    } else if isReady {
                        Image(systemName: "play.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Circle()
                            .strokeBorder(Theme.textSecondary.opacity(0.5), lineWidth: 1)
                            .frame(width: 7, height: 7)
                    }
                }
                Text(mode.targetLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                Text(mode.pickerBlurb)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accentDim : Color.white.opacity(0.02))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Theme.accent : Theme.glassBorder, lineWidth: isSelected ? 1.5 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
