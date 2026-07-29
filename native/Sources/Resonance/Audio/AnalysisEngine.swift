import Foundation

/// Full-track read: metrics, cohesion score, waveform, and the mastering-buddy chat.
/// Direct port of analysis/engine.py.
struct AnalysisEngine {
    let url: URL
    let buffer: AudioBuffer
    var onProgress: ((Int) -> Void)?

    init(url: URL, onProgress: ((Int) -> Void)? = nil) throws {
        self.url = url
        self.onProgress = onProgress
        onProgress?(10)
        self.buffer = try AudioLoader.load(url: url)
        onProgress?(25)
    }

    func runFullAnalysis() -> AnalysisResult {
        let mono = buffer.mono
        onProgress?(35)

        let lufs = round2(Loudness.integratedLufs(buffer: buffer))
        onProgress?(50)
        let tp = round2(Loudness.truePeakDb(mono: mono))
        let spectralReport = Spectral.analyze(signal: mono, fs: buffer.sampleRate)
        let slope = round3(spectralReport.slope)
        let r2 = round3(spectralReport.rSquared)
        onProgress?(65)
        let (corrRaw, widthRaw) = Stereo.analyze(buffer: buffer)
        let corr = round3(corrRaw)
        let width = round3(widthRaw)
        onProgress?(75)

        let waveform = generateWaveformData(mono: mono)
        onProgress?(90)

        let durationSec = Double(mono.count) / buffer.sampleRate
        let minutes = Int(durationSec) / 60
        let seconds = Int(durationSec) % 60
        let durationStr = String(format: "%d:%02d", minutes, seconds)

        let metrics = Metrics(integratedLufs: lufs, truePeakDb: tp,
                              spectralSlope: slope, rSquared: r2,
                              correlation: corr, stereoWidth: width,
                              mudCenterHz: spectralReport.mudCenterHz,
                              mudProminenceDb: spectralReport.mudProminenceDb)

        let score = cohesionScore(metrics)
        let advice = generateSuggestions(metrics)
        onProgress?(100)

        return AnalysisResult(
            title: url.lastPathComponent,
            format: url.pathExtension.uppercased(),
            duration: durationStr,
            metrics: metrics,
            cohesionScore: score,
            status: status(for: score),
            waveform: waveform,
            suggestions: advice.suggestions,
            perspective: advice.perspective,
            chat: advice.chat
        )
    }

    // MARK: waveform

    func generateWaveformData(mono: [Double], points: Int = 500) -> WaveformData {
        let hop = max(1, mono.count / points)
        var wave: [Float] = [], red: [Bool] = []
        var i = 0
        while i < mono.count && wave.count < points {
            let end = min(i + hop, mono.count)
            var peak = 0.0
            for j in i..<end { peak = max(peak, abs(mono[j])) }
            wave.append(Float(peak))
            red.append(peak > 0.99)
            i += hop
        }
        return WaveformData(data: wave, redlines: red)
    }

    // MARK: scoring

    func cohesionScore(_ m: Metrics) -> Double {
        let loudnessScore = max(0, 100 - abs(m.integratedLufs - (-14)) * 5)
        let spectralScore = max(0, 100 - abs(m.spectralSlope - 1.3) * 100)
        let stereoScore = m.correlation > 0 ? max(0, m.correlation * 100) : 0
        let tpPenalty = m.truePeakDb > -1.0 ? max(0, (m.truePeakDb - (-1.0)) * 50) : 0
        let final = (loudnessScore * 0.3) + (spectralScore * 0.4) + (stereoScore * 0.3) - tpPenalty
        return (max(0, final) * 10).rounded() / 10
    }

    func status(for score: Double) -> String {
        if score >= 85 { return "PROFESSIONAL MASTER" }
        if score >= 70 { return "HIGH QUALITY MIX" }
        if score >= 50 { return "DEMO / ROUGH MIX" }
        return "UNFINISHED / TECHNICAL ISSUES"
    }

    // MARK: mastering-buddy copy (ported verbatim from engine.py)

    func generateSuggestions(_ m: Metrics) -> (suggestions: [Suggestion], perspective: String, chat: [ChatBubble]) {
        let lufs = m.integratedLufs
        let slope = m.spectralSlope
        let corr = m.correlation
        let tp = m.truePeakDb

        var chat: [ChatBubble] = []

        chat.append(ChatBubble(tone: .greeting, title: "here's what i'm hearing",
            text: "gave your track a full listen-through with the meters up. quick honest read below — nothing's broken, this is just how we make it shine."))

        if slope > 1.4 {
            let mudNote = m.mudProminenceDb >= 2.0
                ? "the buildup centers right around **\(Int(m.mudCenterHz)) hz** — i found it in your spectrum, and that's exactly where i'll dip"
                : "the low-mids (250–500hz) are stacking up and fogging the detail. i'll gently dip that"
            chat.append(ChatBubble(tone: .insight, title: "tonal balance · a touch dark",
                text: "your spectral slope is \(fmt(slope)) — there's lovely warmth down low, but \(mudNote) so the vocals and cymbals can breathe. think of it as wiping mist off glass."))
        } else if slope < 1.1 {
            chat.append(ChatBubble(tone: .insight, title: "tonal balance · bright & crisp",
                text: "slope's at \(fmt(slope)), so you're riding a bright, detailed top end — sounds expensive, but it's a little thin in the chest. i'll add weight around 150–250hz so it feels grounded instead of glassy."))
        } else {
            chat.append(ChatBubble(tone: .good, title: "tonal balance · dialed",
                text: "slope's sitting at \(fmt(slope)), right in the pro pink-noise pocket. honestly this is where you want to live — i'll preserve it and just tighten the edges."))
        }

        if lufs < -16 {
            chat.append(ChatBubble(tone: .insight, title: "loudness · lots of headroom",
                text: "you're at \(fmt(lufs)) lufs — plenty of room before the ceiling. that's a gift: it means i can push into gentle analog saturation for warmth and glue before we ever hit a limiter. streaming targets around -14, so we've got a clean path up."))
        } else if lufs > -9 {
            chat.append(ChatBubble(tone: .caution, title: "loudness · running hot",
                text: "heads up — you're at \(fmt(lufs)) lufs, which is loud. it'll be punchy, but we're trading away some of the micro-dynamics that make a track feel alive. i'll ease off the limiter a hair so the transients still hit. loud is easy; loud *and* open is the craft."))
        } else {
            chat.append(ChatBubble(tone: .good, title: "loudness · on target",
                text: "\(fmt(lufs)) lufs — basically perfect for streaming. we'll finalize right here and keep the dynamics intact."))
        }

        if corr < 0.6 {
            chat.append(ChatBubble(tone: .caution, title: "stereo image · watch the phase",
                text: "correlation's dipping to \(fmt(corr)). wide sounds great on headphones, but when a club or phone sums to mono, low-end can cancel and thin out. i'll mono the sub and re-focus the center so it stays big *and* solid everywhere."))
        } else {
            chat.append(ChatBubble(tone: .good, title: "stereo image · wide and solid",
                text: "correlation's at \(fmt(corr)) — your width is healthy and phase-coherent. it'll translate cleanly from earbuds to a big system."))
        }

        if tp > -0.5 {
            chat.append(ChatBubble(tone: .caution, title: "true peaks · codec safety",
                text: "peaks are grazing \(fmt(tp)) db. once this gets encoded to mp3/aac, inter-sample peaks can clip past 0. i'll set a -1.0 db ceiling so it survives streaming intact."))
        }

        let rec: String
        if lufs < -16 || slope > 1.4 {
            rec = "i'd start with **modern master** — it leans into harmonic density and glue, which is exactly what this track's asking for. want a warmer, more open take, run **acoustic clear** right after and a/b them."
        } else if corr < 0.6 || slope < 1.1 {
            rec = "i'd reach for **acoustic clear** first — it keeps things phase-coherent and airy, which suits this material. if you want more weight and loudness, try **modern master** and compare."
        } else {
            rec = "this one's balanced, so it's dealer's choice: **modern master** for a louder, denser print, **acoustic clear** for a transparent finish. hit master and we'll hear it."
        }
        chat.append(ChatBubble(tone: .plan, title: "my move",
            text: rec + " either way, i'll print an ORIGINAL_REFERENCE next to it so you can a/b instantly."))

        let perspective = chat
            .filter { [.insight, .good, .caution].contains($0.tone) }
            .map { $0.text }
            .joined(separator: " ")

        var suggestions: [Suggestion] = []
        if lufs < -16 {
            suggestions.append(Suggestion(title: "ANALOG THERMAL PUSH", text: "Lots of headroom — boosting into a soft-clipper for even-order harmonic warmth."))
        } else if lufs > -9 {
            suggestions.append(Suggestion(title: "SPECTRAL DYNAMICS CAUTION", text: "Loudness is hot — backing off the final limiter to let transients breathe."))
        }
        if slope > 1.5 {
            suggestions.append(Suggestion(title: "MUD DE-MASKING", text: "Low-mid buildup (300–500Hz) — a wide, gentle 2dB dip clears the fog."))
        } else if slope < 1.1 {
            suggestions.append(Suggestion(title: "HF EXCITATION", text: "Feels dark — a 12kHz high-shelf restores sheen without brittleness."))
        }
        if corr < 0.5 {
            suggestions.append(Suggestion(title: "CORRELATION ALIGNMENT", text: "Phase dipping — mono the sub-200Hz and check widening."))
        }
        if tp > -0.5 {
            suggestions.append(Suggestion(title: "INTER-SAMPLE SAFETY", text: "True peaks clipping — setting a -1.0dB ceiling for codec integrity."))
        }

        return (suggestions, perspective, chat)
    }

    // MARK: helpers

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.1f", v) : String(describing: v)
    }
}
