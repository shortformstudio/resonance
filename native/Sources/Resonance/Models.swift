import Foundation

enum MasteringMode: String, CaseIterable {
    case resonanceV2 = "resonance_v2"
    case clear = "clear"
    case unifiedHybridV1 = "unified_hybrid_v1"

    var displayName: String {
        switch self {
        case .resonanceV2: return "Resonance v2"
        case .clear: return "CLEAR"
        case .unifiedHybridV1: return "Unified Hybrid v1"
        }
    }

    var chatLabel: String {
        switch self {
        case .resonanceV2: return "Resonance v2"
        case .clear: return "CLEAR (acoustic clarity)"
        case .unifiedHybridV1: return "Unified Hybrid v1 (legacy)"
        }
    }

    var shortDescription: String {
        switch self {
        case .resonanceV2:
            return "Full chain: true-peak limiter, closed-loop -14 LUFS, M/S hygiene, glue comp, ADAA saturation, adaptive mud cut."
        case .clear:
            return "Acoustic clarity: 40Hz Butterworth HPF, boxiness taming, spectral unmasking, air shelf, transparent glue. Unmasks detail and levels dynamics without chasing loudness."
        case .unifiedHybridV1:
            return "Original alpha engine: adaptive HPF, gentle saturation, spectral balancing, single-band glue comp, -14 LUFS target. Broadband, warm, no M/S or ADAA stages."
        }
    }
}

struct Metrics {
    var integratedLufs: Double
    var truePeakDb: Double
    var spectralSlope: Double
    var rSquared: Double
    var correlation: Double
    var stereoWidth: Double
    var mudCenterHz: Double = 420.0
    var mudProminenceDb: Double = 0.0
}

enum ChatTone: String {
    case greeting, insight, good, caution, plan, working, done

    var icon: String {
        switch self {
        case .greeting: return "◉"
        case .insight: return "✳"
        case .good, .done: return "✓"
        case .caution: return "⚠"
        case .plan: return "➤"
        case .working: return "⟳"
        }
    }
}

struct ChatBubble: Identifiable {
    let id = UUID()
    var tone: ChatTone
    var title: String?
    var text: String
}

struct Suggestion: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}

struct WaveformData {
    var data: [Float]
    var redlines: [Bool]
}

struct AnalysisResult {
    var title: String
    var format: String
    var duration: String
    var metrics: Metrics
    var cohesionScore: Double
    var status: String
    var waveform: WaveformData
    var suggestions: [Suggestion]
    var perspective: String
    var chat: [ChatBubble]
}

struct MasterResult {
    var outputPath: URL
    var comparisonPath: URL?
    var abSamplePath: URL?
    var videoPath: URL?
    var warning: String?
    var abWarning: String?
    var engineMode: MasteringMode = .resonanceV2
}

enum BatchStatus: String {
    case queued, analyzing, ready, mastering, done, error

    var label: String {
        switch self {
        case .queued: return "queued"
        case .analyzing: return "analyzing…"
        case .ready: return "ready"
        case .mastering: return "mastering…"
        case .done: return "done ✓"
        case .error: return "error"
        }
    }
}

struct BatchTrack: Identifiable {
    let id = UUID()
    var url: URL
    var name: String
    var status: BatchStatus = .queued
    var analysis: AnalysisResult?
    var outputPath: URL?
}

struct HistoryItem: Identifiable {
    let id = UUID()
    var name: String
    var path: URL
}

struct LogEntry: Identifiable {
    let id = UUID()
    var time: String
    var message: String
}
