import Foundation

/// The three mastering styles. Raw values are kept from earlier builds so
/// saved selections and library tags still resolve.
enum MasteringMode: String, CaseIterable {
    case core = "resonance_v2"
    case pure = "clear"
    case club = "club"

    var displayName: String {
        switch self {
        case .core: return "core"
        case .pure: return "pure"
        case .club: return "club"
        }
    }

    var chatLabel: String {
        switch self {
        case .core: return "Core (balanced)"
        case .pure: return "Pure (transparent)"
        case .club: return "Club (loud)"
        }
    }

    var shortDescription: String {
        switch self {
        case .core:
            return "Balanced modern master: scanned tonal match toward a commercial reference curve, linked multiband + glue on the track's own loudness percentiles, gentle ADAA heat, mono bass, -14 LUFS / -1 dBTP."
        case .pure:
            return "Transparent finish: light tonal correction, wide-open dynamics (thresholds only catch the loudest moments), no saturation or widening, -16 LUFS / -1 dBTP."
        case .club:
            return "Loud, dense print: stronger tonal match with weighted lows, firmer multiband + glue, hotter heat, soft clip into the true-peak limiter, -9 LUFS / -1 dBTP."
        }
    }

    /// Target loudness for the closed-loop landing stage.
    var targetLufs: Double { StyleProfile.forMode(self).targetLufs }

    /// Short blurb shown on the mode card in the master-options panel.
    var pickerBlurb: String {
        switch self {
        case .core: return "balanced modern master"
        case .pure: return "transparent, dynamic finish"
        case .club: return "loud, dense print"
        }
    }

    /// Target label shown beside the mode name, e.g. "-14 balanced".
    var targetLabel: String {
        switch self {
        case .core: return "-14 balanced"
        case .pure: return "-16 transparent"
        case .club: return "-9 loud"
        }
    }

    /// Suggested style for the given read (★ badge in the options panel).
    static func recommended(for m: Metrics) -> MasteringMode {
        if m.integratedLufs > -11 && m.crestFactorDb < 12 { return .club }
        if m.crestFactorDb > 18 || m.correlation < 0.5 || m.lra > 12 { return .pure }
        return .core
    }

    /// Processing chain for the current read, mirroring Engine/MasterChain.
    func chainPreview(metrics m: Metrics) -> [(name: String, detail: String, info: HoverInfo)] {
        let p = StyleProfile.forMode(self)
        let stereo = m.correlation > 0.3 && p.widthDb > 0
            ? String(format: "mono <%.0fHz · width %+.1fdB", p.monoBassHz, p.widthDb)
            : String(format: "mono <%.0fHz · image hold", p.monoBassHz)
        return [
            ("Rate Guard", "<44.1k → 48k mastering SRC", Info.rateGuard),
            ("Gain Staging", String(format: "%.1f → -18 LUFS working level", m.integratedLufs), Info.gainStaging),
            ("Sub-Sonic Control", String(format: "%.0fHz HPF 24dB/oct", p.highPassHz), Info.subSonic),
            ("Transient Detail", String(format: "attack %+.2f", p.transientAttack), Info.transientDetail),
            ("Spectral Balancing", String(format: "scan-matched · %.0f%% · ±%.0fdB", p.eqStrength * 100, p.eqMaxDb), Info.spectralBalancing),
            ("Resonance Tamer", "2–8kHz · \(Int(p.suppressDepth * 100))%", Info.resonanceTamer),
            ("Multiband Dynamics", String(format: "4 bands linked · %.1f:1 @ P%.0f", p.mbRatio, p.mbPercentile * 100), Info.multiband),
            ("Organic Heat", p.saturationDb > 0 ? String(format: "+%.1fdB ADAA drive", p.saturationDb) : "no saturation", Info.organicHeat),
            ("Program Glue", String(format: "%.1f:1 linked @ P%.0f", p.glueRatio, p.gluePercentile * 100), Info.programGlue),
            ("Spatial Width", stereo, Info.spatialWidth),
            ("Final Offset", String(format: "→ %.1f LUFS · %.1f dBTP", p.targetLufs, p.ceilingDbtp), Info.finalOffset)
        ]
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
    var lra: Double = 0.0
    var crestFactorDb: Double = 0.0
    var sectionSpreadDb: Double = 0.0
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
    var dynamics: DynamicsReport = DynamicsReport(lra: 0, crestFactorDb: 0, sectionSpreadDb: 0, sections: [], histogram: [])
}

struct MasterResult {
    var outputPath: URL
    var comparisonPath: URL?
    var abSamplePath: URL?
    var videoPath: URL?
    var warning: String?
    var abWarning: String?
    var engineMode: MasteringMode = .core
    var report: MasterReport? = nil
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
    var mode: MasteringMode = .core
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
