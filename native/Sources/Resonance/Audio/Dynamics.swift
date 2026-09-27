import Foundation
import Accelerate

// MARK: - Biquad additions (RBJ cookbook, matching DSP.swift conventions)

extension Biquad {
    static func lowPass(fs: Double, f0: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        return Biquad(b0: (1 - cw) / 2, b1: 1 - cw, b2: (1 - cw) / 2,
                      a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    /// Constant-0dB-peak-gain bandpass (detection sidechains).
    static func bandPass(fs: Double, f0: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        return Biquad(b0: alpha, b1: 0, b2: -alpha,
                      a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }
}

// MARK: - Per-mode dynamics configuration

/// One place where every engine's dynamics behavior is decided.
struct ModeDynamics {
    var mbThresholdsDb: [Double]  // sub, low, mid, high
    var mbRatios: [Double]
    var mbAttackMs: Double
    var mbReleaseMs: Double
    var clipDriveDb: Double       // <= 0.05 bypasses the clipper
    var clipCeilingDb: Double
    var transientAttack: Double   // -1 ... 1
    var transientSustain: Double  // -1 ... 1
    var upwardDepth: Double       // 0 ... 1
    var upwardMix: Double         // 0 ... 1 parallel blend
    var suppressDepth: Double     // 0 ... 1 resonance tamer
    var sectionTrimDb: Double     // max adaptive section trim

    static func forMode(_ mode: MasteringMode) -> ModeDynamics {
        switch mode {
        case .core:
            return ModeDynamics(mbThresholdsDb: [-22, -20, -20, -24], mbRatios: [1.6, 1.6, 1.6, 1.6],
                                mbAttackMs: 30, mbReleaseMs: 200,
                                clipDriveDb: 1.5, clipCeilingDb: -1.0,
                                transientAttack: 0.25, transientSustain: 0.0,
                                upwardDepth: 0.35, upwardMix: 0.25,
                                suppressDepth: 0.5, sectionTrimDb: 1.5)
        case .pure:
            return ModeDynamics(mbThresholdsDb: [-22, -20, -20, -24], mbRatios: [1.4, 1.4, 1.4, 1.4],
                                mbAttackMs: 40, mbReleaseMs: 250,
                                clipDriveDb: 0.0, clipCeilingDb: -1.0,
                                transientAttack: 0.15, transientSustain: 0.0,
                                upwardDepth: 0.3, upwardMix: 0.2,
                                suppressDepth: 0.7, sectionTrimDb: 1.0)
        case .heat:
            return ModeDynamics(mbThresholdsDb: [-22, -20, -20, -24], mbRatios: [1.5, 1.5, 1.5, 1.5],
                                mbAttackMs: 35, mbReleaseMs: 220,
                                clipDriveDb: 2.0, clipCeilingDb: -1.0,
                                transientAttack: 0.2, transientSustain: 0.1,
                                upwardDepth: 0.4, upwardMix: 0.3,
                                suppressDepth: 0.4, sectionTrimDb: 1.5)
        case .club:
            return ModeDynamics(mbThresholdsDb: [-24, -22, -22, -26], mbRatios: [2.2, 2.2, 2.2, 2.2],
                                mbAttackMs: 20, mbReleaseMs: 150,
                                clipDriveDb: 3.0, clipCeilingDb: -1.0,
                                transientAttack: 0.35, transientSustain: 0.0,
                                upwardDepth: 0.3, upwardMix: 0.2,
                                suppressDepth: 0.6, sectionTrimDb: 2.0)
        case .ivory:
            return ModeDynamics(mbThresholdsDb: [-22, -20, -20, -24], mbRatios: [1.3, 1.3, 1.3, 1.3],
                                mbAttackMs: 50, mbReleaseMs: 300,
                                clipDriveDb: 0.0, clipCeilingDb: -1.0,
                                transientAttack: 0.1, transientSustain: 0.0,
                                upwardDepth: 0.25, upwardMix: 0.2,
                                suppressDepth: 0.3, sectionTrimDb: 1.0)
        case .vox:
            return ModeDynamics(mbThresholdsDb: [-22, -20, -20, -24], mbRatios: [1.6, 1.6, 1.6, 1.6],
                                mbAttackMs: 30, mbReleaseMs: 200,
                                clipDriveDb: 1.0, clipCeilingDb: -1.0,
                                transientAttack: 0.2, transientSustain: 0.0,
                                upwardDepth: 0.35, upwardMix: 0.25,
                                suppressDepth: 0.8, sectionTrimDb: 1.5)
        }
    }
}

// MARK: - 4-band crossover (magnitude-flat by construction)

/// Three cascaded 24dB/oct low-pass splits. Bands always sum back to the
/// input sample-exactly: b1 + b2 + b3 + b4 == x.
struct Crossover4 {
    var lp1a: Biquad; var lp1b: Biquad
    var lp2a: Biquad; var lp2b: Biquad
    var lp3a: Biquad; var lp3b: Biquad

    init(fs: Double, f1: Double, f2: Double, f3: Double) {
        lp1a = Biquad.lowPass(fs: fs, f0: f1, q: 0.7071); lp1b = Biquad.lowPass(fs: fs, f0: f1, q: 0.7071)
        lp2a = Biquad.lowPass(fs: fs, f0: f2, q: 0.7071); lp2b = Biquad.lowPass(fs: fs, f0: f2, q: 0.7071)
        lp3a = Biquad.lowPass(fs: fs, f0: f3, q: 0.7071); lp3b = Biquad.lowPass(fs: fs, f0: f3, q: 0.7071)
    }

    mutating func split(_ x: Double) -> (Double, Double, Double, Double) {
        let b1 = lp1b.process(lp1a.process(x))
        let r1 = x - b1
        let b2 = lp2b.process(lp2a.process(r1))
        let r2 = r1 - b2
        let b3 = lp3b.process(lp3a.process(r2))
        let b4 = r2 - b3
        return (b1, b2, b3, b4)
    }
}

// MARK: - Multiband compressor (corrective, before the glue)

struct MultibandCompressor {
    var xo: [Crossover4]
    var comps: [[MasteringEngine.GlueCompressor]]
    let channels: Int

    init(fs: Double, channels: Int, crossovers: (Double, Double, Double) = (120, 900, 5000),
         thresholdsDb: [Double], ratios: [Double], attackMs: Double, releaseMs: Double) {
        self.channels = channels
        xo = (0..<channels).map { _ in Crossover4(fs: fs, f1: crossovers.0, f2: crossovers.1, f3: crossovers.2) }
        comps = (0..<channels).map { _ in
            (0..<4).map { b in
                MasteringEngine.GlueCompressor(thresholdDb: thresholdsDb[b], ratio: ratios[b], kneeDb: 6,
                                               attackMs: attackMs, releaseMs: releaseMs, fs: fs)
            }
        }
    }

    mutating func process(channels work: inout [[Double]], frames: Int) {
        for c in 0..<channels {
            for i in 0..<frames {
                let (b1, b2, b3, b4) = xo[c].split(work[c][i])
                let bands = [b1, b2, b3, b4]
                var out = 0.0
                for b in 0..<4 {
                    let g = comps[c][b].gain(meanSquare: bands[b] * bands[b])
                    out += bands[b] * g
                }
                work[c][i] = out
            }
        }
    }
}

// MARK: - Soft clipper (loudness staging ahead of the brickwall)

struct SoftClipper {
    var driveDb: Double
    var ceilingDb: Double

    var bypassed: Bool { driveDb <= 0.05 }

    mutating func process(_ x: Double) -> Double {
        guard !bypassed else { return x }
        let g = pow(10, driveDb / 20)
        let c = pow(10, ceilingDb / 20)
        return c * tanh(g * x) / tanh(g)
    }
}

// MARK: - One-pole envelope follower

struct Follower {
    var attackMs: Double
    var releaseMs: Double
    var fs: Double
    var env = 0.0

    mutating func process(_ x: Double) -> Double {
        let a = x > env
            ? exp(-1.0 / (attackMs * 0.001 * fs))
            : exp(-1.0 / (releaseMs * 0.001 * fs))
        env = x + a * (env - x)
        return env
    }
}

// MARK: - Transient designer (two bands, attack/sustain)

struct TransientDesigner {
    var attack: Double
    var sustain: Double
    var splitA: [Biquad]
    var splitB: [Biquad]
    var fast: [[Follower]]
    var slow: [[Follower]]
    let channels: Int

    init(fs: Double, channels: Int, attack: Double, sustain: Double, splitHz: Double = 900) {
        self.attack = attack
        self.sustain = sustain
        self.channels = channels
        splitA = (0..<channels).map { _ in Biquad.lowPass(fs: fs, f0: splitHz, q: 0.7071) }
        splitB = (0..<channels).map { _ in Biquad.lowPass(fs: fs, f0: splitHz, q: 0.7071) }
        // [channel][band]: fast tracks onsets, slow tracks body.
        fast = (0..<channels).map { _ in
            [Follower(attackMs: 0.5, releaseMs: 8, fs: fs), Follower(attackMs: 0.5, releaseMs: 8, fs: fs)]
        }
        slow = (0..<channels).map { _ in
            [Follower(attackMs: 10, releaseMs: 120, fs: fs), Follower(attackMs: 10, releaseMs: 120, fs: fs)]
        }
    }

    mutating func process(channels work: inout [[Double]], frames: Int) {
        guard attack != 0 || sustain != 0 else { return }
        for c in 0..<channels {
            for i in 0..<frames {
                let x = work[c][i]
                let lo = splitB[c].process(splitA[c].process(x))
                let hi = x - lo
                work[c][i] = shape(lo, c: c, b: 0) + shape(hi, c: c, b: 1)
            }
        }
    }

    private mutating func shape(_ x: Double, c: Int, b: Int) -> Double {
        let f = fast[c][b].process(abs(x))
        let s = slow[c][b].process(abs(x))
        let onset = min(max((f - s) / (s + 1e-4), 0), 1.5)
        let body = min(s * 3.0, 1.0)
        let g = (1 + attack * onset) * (1 + sustain * body)
        return x * max(g, 0)
    }
}

// MARK: - Upward parallel path (quiet-detail lift with mix)

struct UpwardPath {
    var depth: Double
    var mix: Double
    var thresholdDb: Double = -36
    var maxBoostDb: Double = 6
    var level: [Follower]
    let channels: Int

    init(fs: Double, channels: Int, depth: Double, mix: Double) {
        self.depth = depth
        self.mix = mix
        self.channels = channels
        level = (0..<channels).map { _ in Follower(attackMs: 20, releaseMs: 300, fs: fs) }
    }

    mutating func process(channels work: inout [[Double]], frames: Int) {
        guard depth > 0 && mix > 0 else { return }
        for c in 0..<channels {
            for i in 0..<frames {
                let dry = work[c][i]
                let lv = max(level[c].process(abs(dry)), 1e-9)
                let levelDb = 20 * log10(lv)
                let boost = min(max(0, (thresholdDb - levelDb) * depth * 0.5), maxBoostDb)
                let wet = dry * pow(10, boost / 20)
                work[c][i] = dry * (1 - mix) + wet * mix
            }
        }
    }
}

// MARK: - Dynamic resonance suppressor (2–8 kHz, detection-driven bells)

/// Soothe-style tamer: six fixed bells whose cut follows how far each band
/// pokes above the broadband body. Cuts only exist while the harshness does.
struct ResonanceSuppressor {
    struct Bell {
        var bp: Biquad
        var bell: Biquad
        var env: Follower
        var cutDb = 0.0
    }

    static let spots: [(f0: Double, q: Double)] = [
        (2200, 3), (2800, 3), (3500, 3), (4400, 3), (5600, 3), (7000, 3)
    ]

    var depth: Double
    var maxCutDb = 6.0
    var ref: [Follower]
    var bells: [[Bell]]
    let channels: Int
    let fs: Double
    var blockCountdown = 0

    init(fs: Double, channels: Int, depth: Double) {
        self.depth = depth
        self.channels = channels
        self.fs = fs
        ref = (0..<channels).map { _ in Follower(attackMs: 10, releaseMs: 200, fs: fs) }
        bells = (0..<channels).map { _ in
            ResonanceSuppressor.spots.map { s in
                Bell(bp: Biquad.bandPass(fs: fs, f0: s.f0, q: s.q),
                     bell: Biquad.peak(fs: fs, f0: s.f0, gainDb: 0, q: s.q),
                     env: Follower(attackMs: 5, releaseMs: 120, fs: fs))
            }
        }
    }

    mutating func process(channels work: inout [[Double]], frames: Int) {
        guard depth > 0 else { return }
        for c in 0..<channels {
            for i in 0..<frames {
                let x = work[c][i]
                let body = max(ref[c].process(abs(x)), 1e-9)
                var y = x
                for b in 0..<bells[c].count {
                    let band = bells[c][b].bp.process(x)
                    let lv = max(bells[c][b].env.process(abs(band)), 1e-9)
                    // Re-aim the bell at block rate to avoid zipper noise.
                    if blockCountdown == 0 {
                        let excessDb = 20 * log10(lv / body)
                        let want = min(max(0, (excessDb - 4.0) * depth * 0.75), maxCutDb)
                        bells[c][b].cutDb += 0.25 * (want - bells[c][b].cutDb)
                        bells[c][b].bell = Biquad.peak(fs: fs, f0: ResonanceSuppressor.spots[b].f0,
                                                       gainDb: -bells[c][b].cutDb, q: ResonanceSuppressor.spots[b].q)
                    }
                    y = bells[c][b].bell.process(y)
                }
                work[c][i] = y
                if blockCountdown == 0 { blockCountdown = 256 } else { blockCountdown -= 1 }
            }
        }
    }
}

// MARK: - Section metering + adaptive trim

struct SectionDynamics {
    var startSec: Double
    var lufs: Double
    var lra: Double
    var crestDb: Double
}

struct DynamicsReport {
    var lra: Double
    var crestFactorDb: Double
    var sectionSpreadDb: Double
    var sections: [SectionDynamics]
    var histogram: [Float] // ~120 normalized peaks for the dynamics strip
}

enum SectionMeter {
    /// Split the track into `count` sections; measure each like a mini-master.
    static func analyze(buffer: AudioBuffer, count: Int = 8) -> [SectionDynamics] {
        let fs = buffer.sampleRate
        let total = buffer.frameCount
        guard total > 0 else { return [] }
        let per = max(1, total / count)
        var out: [SectionDynamics] = []
        for s in 0..<count {
            let start = min(s * per, total - 1)
            let end = (s == count - 1) ? total : min(start + per, total)
            guard end > start else { continue }
            let sub = AudioBuffer(channels: buffer.channels.map { Array($0[start..<end]) }, sampleRate: fs)
            let lufs = Loudness.integratedLufs(buffer: sub)
            let peak = sub.channels.flatMap { $0 }.map(abs).max() ?? 0
            let rms = sqrt(sub.mono.map { $0 * $0 }.reduce(0, +) / max(Double(sub.frameCount), 1))
            let crest = 20 * log10(max(peak, 1e-9) / max(rms, 1e-9))
            out.append(SectionDynamics(startSec: Double(start) / fs, lufs: lufs,
                                       lra: shortTermLRA(buffer: sub), crestDb: crest))
        }
        return out
    }

    /// Loudness range: 3s short-term blocks, absolute + relative gating, P95 − P10.
    static func shortTermLRA(buffer: AudioBuffer) -> Double {
        let fs = buffer.sampleRate
        let block = Int(3.0 * fs), hop = Int(1.5 * fs)
        let n = buffer.frameCount
        guard n >= block else { return 0 }
        var vals: [Double] = []
        var start = 0
        while start + block <= n {
            let sub = AudioBuffer(channels: buffer.channels.map { Array($0[start..<start + block]) }, sampleRate: fs)
            let l = Loudness.integratedLufs(buffer: sub)
            if l > -70 { vals.append(l) }
            start += hop
        }
        guard vals.count >= 2 else { return 0 }
        let sorted = vals.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let rel = sorted.filter { $0 >= mean - 20 }
        guard rel.count >= 2 else { return 0 }
        return percentile(rel, 0.95) - percentile(rel, 0.10)
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = p * Double(sorted.count - 1)
        let lo = Int(rank), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
    }

    /// Normalized peak histogram for the dynamics strip UI.
    static func histogram(buffer: AudioBuffer, points: Int = 120) -> [Float] {
        let mono = buffer.mono
        guard !mono.isEmpty else { return [] }
        let hop = max(1, mono.count / points)
        var out: [Float] = []
        var i = 0
        while i < mono.count && out.count < points {
            let end = min(i + hop, mono.count)
            var peak = 0.0
            for j in i..<end { peak = max(peak, abs(mono[j])) }
            out.append(Float(peak))
            i += hop
        }
        let maxPeak = out.max() ?? 1
        return out.map { $0 / max(maxPeak, 1e-6) }
    }

    /// Per-section trim riding quiet sections up and loud ones down,
    /// clamped to ±maxDb and crossfaded over half a second.
    static func adaptiveTrim(work: inout [[Double]], sections: [SectionDynamics],
                             fs: Double, targetLufs: Double, maxDb: Double) {
        guard sections.count > 1, maxDb > 0 else { return }
        let channels = work.count
        let frames = work.first?.count ?? 0
        guard frames > 0 else { return }
        let trims = sections.map { s in min(max(targetLufs - s.lufs, -maxDb), maxDb) }
        let fade = Int(0.5 * fs)
        // Section boundaries in frames (even split, matching analyze()).
        let per = frames / sections.count
        for i in 0..<frames {
            let s = min(i / max(per, 1), sections.count - 1)
            var g = trims[s]
            // Raised-cosine crossfade across boundaries.
            let local = i - s * per
            if local < fade, s > 0 {
                let t = Double(local) / Double(fade)
                let w = 0.5 - 0.5 * cos(Double.pi * t)
                g = trims[s - 1] * (1 - w) + trims[s] * w
            }
            let lin = pow(10, g / 20)
            for c in 0..<channels { work[c][i] *= lin }
        }
    }
}

// MARK: - One-call dynamics chain (hook for every render)

enum DynamicsChain {
    /// Transient shaping on the raw load — transients are cleanest pre-EQ.
    static func applyTransient(channels: [[Double]], fs: Double, metrics: Metrics, mode: MasteringMode) -> [[Double]] {
        let cfg = ModeDynamics.forMode(mode)
        var td = TransientDesigner(fs: fs, channels: channels.count,
                                   attack: cfg.transientAttack, sustain: cfg.transientSustain)
        var work = channels
        let frames = work.first?.count ?? 0
        td.process(channels: &work, frames: frames)
        return work
    }

    /// Post-chain corrective stages: tamer → multiband → upward → section trim.
    /// Runs on the finished work buffer, ahead of the closed-loop landing.
    static func process(work: [[Double]], fs: Double, metrics: Metrics, mode: MasteringMode,
                        targetLufs: Double) -> [[Double]] {
        let cfg = ModeDynamics.forMode(mode)
        var out = work
        let frames = out.first?.count ?? 0
        let channels = out.count
        guard frames > 0 else { return out }

        var sup = ResonanceSuppressor(fs: fs, channels: channels, depth: cfg.suppressDepth)
        sup.process(channels: &out, frames: frames)

        var mb = MultibandCompressor(fs: fs, channels: channels,
                                     thresholdsDb: cfg.mbThresholdsDb, ratios: cfg.mbRatios,
                                     attackMs: cfg.mbAttackMs, releaseMs: cfg.mbReleaseMs)
        mb.process(channels: &out, frames: frames)

        var up = UpwardPath(fs: fs, channels: channels, depth: cfg.upwardDepth, mix: cfg.upwardMix)
        up.process(channels: &out, frames: frames)

        let sections = SectionMeter.analyze(buffer: AudioBuffer(channels: out, sampleRate: fs))
        SectionMeter.adaptiveTrim(work: &out, sections: sections, fs: fs,
                                  targetLufs: targetLufs, maxDb: cfg.sectionTrimDb)
        return out
    }

    /// Full metering report for analysis + UI.
    static func report(buffer: AudioBuffer) -> DynamicsReport {
        let sections = SectionMeter.analyze(buffer: buffer)
        let lufs = sections.map(\.lufs).filter { $0 > -70 }
        let spread = (lufs.max() ?? 0) - (lufs.min() ?? 0)
        let mono = buffer.mono
        let peak = mono.map(abs).max() ?? 0
        let rms = sqrt(mono.map { $0 * $0 }.reduce(0, +) / max(Double(mono.count), 1))
        let crest = 20 * log10(max(peak, 1e-9) / max(rms, 1e-9))
        return DynamicsReport(lra: SectionMeter.shortTermLRA(buffer: buffer),
                              crestFactorDb: crest,
                              sectionSpreadDb: spread,
                              sections: sections,
                              histogram: SectionMeter.histogram(buffer: buffer))
    }
}
