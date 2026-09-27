import Foundation

enum MasteringMode: String, CaseIterable {
    case core = "resonance_v2"
    case pure = "clear"
    case heat = "unified_hybrid_v1"
    case club = "club"
    case ivory = "ivory"
    case vox = "vox"

    var displayName: String {
        switch self {
        case .core: return "core"
        case .pure: return "pure"
        case .heat: return "heat"
        case .club: return "club"
        case .ivory: return "ivory"
        case .vox: return "vox"
        }
    }

    var chatLabel: String {
        switch self {
        case .core: return "Core"
        case .pure: return "Pure (acoustic clarity)"
        case .heat: return "Heat (vintage hybrid)"
        case .club: return "Club (loud)"
        case .ivory: return "Ivory (piano)"
        case .vox: return "Vox (vocal)"
        }
    }

    var shortDescription: String {
        switch self {
        case .core:
            return "Full chain: true-peak limiter, closed-loop -14 LUFS, M/S hygiene, glue comp, ADAA saturation, adaptive mud cut."
        case .pure:
            return "Acoustic clarity: 40Hz Butterworth HPF, boxiness taming, spectral unmasking, air shelf, transparent glue. Unmasks detail and levels dynamics without chasing loudness."
        case .heat:
            return "Original alpha engine: adaptive HPF, gentle saturation, spectral balancing, single-band glue comp, -14 LUFS target. Broadband, warm, no M/S or ADAA stages."
        case .club:
            return "Loud club print: hotter drive, harder glue, closed-loop -8 LUFS. Maximum density for big systems."
        case .ivory:
            return "Gentle piano voicing: soft high-pass, no saturation weight, transparent leveling to -14 LUFS. Preserves transients and felt dynamics."
        case .vox:
            return "Forward vocal presence: presence bell, air shelf, light glue to -14 LUFS. Puts the voice on top without harshness."
        }
    }

    /// Target loudness for the closed-loop landing stage.
    var targetLufs: Double {
        switch self {
        case .club: return -8.0
        default: return -14.0
        }
    }

    /// Short blurb shown on the mode card in the master-options panel.
    var pickerBlurb: String {
        switch self {
        case .core: return "balanced modern master"
        case .pure: return "transparent acoustic finish"
        case .heat: return "vintage hybrid warmth"
        case .club: return "loud club print"
        case .ivory: return "gentle piano voicing"
        case .vox: return "forward vocal presence"
        }
    }

    /// Target label shown beside the mode name, e.g. "-14 balanced".
    var targetLabel: String {
        switch self {
        case .core: return "-14 balanced"
        case .pure: return "-14 transparent"
        case .heat: return "-14 vintage"
        case .club: return "-8 loud"
        case .ivory: return "-14 piano"
        case .vox: return "-14 vocal"
        }
    }

    /// Suggested engine for the given read (★ badge in the options panel).
    static func recommended(for m: Metrics) -> MasteringMode {
        if m.correlation < 0.6 || m.spectralSlope < 1.1 { return .pure }
        if m.integratedLufs > -9 { return .club }
        if m.integratedLufs < -16 || m.spectralSlope > 1.4 { return .core }
        return .core
    }

    /// Per-mode processing chain detail for the current read, matching DSP thresholds.
    func chainPreview(metrics m: Metrics) -> [(name: String, detail: String, info: HoverInfo)] {
        let cfg = ModeDynamics.forMode(self)
        let mud = String(format: "Mud Cut @ %.0fHz", m.mudCenterHz)
        let hpf: String
        let heat: String
        let spectral: String
        let spatial: String
        let glue: String
        switch self {
        case .pure:
            hpf = "40Hz HPF ×2"
            heat = "no saturation"
            spectral = "450Hz unmask · 12kHz air"
            spatial = "Image Hold"
            glue = "1.15:1 Transparent"
        case .heat:
            hpf = m.spectralSlope > 1.4 ? "35Hz HPF" : "30Hz HPF"
            heat = m.integratedLufs < -18 ? "+1.5dB Drive" : "+1.0dB Drive"
            spectral = m.spectralSlope > 1.4 ? mud : "Air Excitation"
            spatial = m.correlation < 0.6 ? "Sub Mono-Fold" : "Image Hold"
            glue = m.integratedLufs > -12 ? "1.2:1 Soft Knee" : "1.5:1 Soft Knee"
        case .club:
            hpf = "30Hz HPF"
            heat = "+2.5dB Drive"
            spectral = m.spectralSlope > 1.4 ? mud : "Air +4dB"
            spatial = m.correlation > 0.7 ? "M/S Expansion" : (m.correlation < 0.6 ? "Sub Mono-Fold" : "Image Hold")
            glue = "2.0:1 Club Glue"
        case .ivory:
            hpf = "25Hz HPF"
            heat = "no saturation"
            spectral = m.spectralSlope > 1.6 ? mud : "Air +2dB"
            spatial = "Image Hold"
            glue = "1.15:1 Transparent"
        case .vox:
            hpf = "80Hz HPF"
            heat = "+1.0dB Drive"
            spectral = "3kHz presence · 12kHz air"
            spatial = "Center Focus"
            glue = "1.3:1 Vocal Glue"
        case .core:
            hpf = m.spectralSlope > 1.4 ? "35Hz HPF" : "30Hz HPF"
            heat = m.integratedLufs < -18 ? "+1.5dB Drive" : "+1.0dB Drive"
            spectral = m.spectralSlope > 1.4 ? mud : "Air Excitation"
            spatial = m.correlation > 0.7 ? "M/S Expansion" : (m.correlation < 0.6 ? "Sub Mono-Fold" : "Image Hold")
            glue = m.integratedLufs > -12 ? "1.2:1 Soft Knee" : "1.5:1 Soft Knee"
        }
        let avgRatio = cfg.mbRatios.reduce(0, +) / Double(max(cfg.mbRatios.count, 1))
        return [
            ("Sub-Sonic Control", hpf, Info.subSonic),
            ("Transient Detail", String(format: "Attack %+.2f · Sustain %+.2f", cfg.transientAttack, cfg.transientSustain), Info.transientDetail),
            ("Organic Heat", heat, Info.organicHeat),
            ("Spectral Balancing", spectral, Info.spectralBalancing),
            ("Resonance Tamer", "2–8kHz · \(Int(cfg.suppressDepth * 100))%", Info.resonanceTamer),
            ("Multiband Dynamics", String(format: "4 bands · ~%.1f:1", avgRatio), Info.multiband),
            ("Spatial Width", spatial, Info.spatialWidth),
            ("Program Glue", glue, Info.programGlue),
            ("Upward Detail", "parallel mix \(Int(cfg.upwardMix * 100))%", Info.upwardDetail),
            ("Section Trim", String(format: "±%.1f dB ride", cfg.sectionTrimDb), Info.sectionTrim),
            ("Final Offset", "→ \(String(format: "%.1f", targetLufs)) LUFS exact", Info.finalOffset)
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
