import Foundation
import AVFoundation
import Accelerate

/// Unified Hybrid Mastering Engine — native chain, v2.
/// 1. Sub-Sonic Control      adaptive high-pass foundation
/// 2. Mid/Side Hygiene       mono-solid sub + phase-safe level-based width
/// 3. Organic Heat           ADAA anti-aliased tanh saturation, sub band passes clean
/// 4. Spectral Balancing     detected mud center, air + body shelves
/// 5. Program Glue           stereo-linked soft-knee RMS compression
/// 6. Closed-Loop Level      measured trim landing exactly on target LUFS
/// 7. True-Peak Brickwall    4x-oversampled detection + 2 ms lookahead, -1 dBTP
struct MasteringEngine {
    var targetLufs = -14.0

    // MARK: components

    /// Complementary 1st-order split: low(x) + (x - low(x)) reconstructs exactly.
    struct OnePoleSplit {
        private var z = 0.0
        private let a: Double
        init(fs: Double, fc: Double) { a = exp(-2 * .pi * fc / fs) }
        mutating func low(_ x: Double) -> Double {
            z = (1 - a) * x + a * z
            return z
        }
    }

    /// First-order antiderivative anti-aliasing (Parker et al.) around tanh —
    /// the alias suppression of oversampling at the cost of one state variable.
    struct ADAATanh {
        private let gain: Double
        private var x1 = 0.0
        private var f1 = 0.0

        init(driveDb: Double) {
            gain = pow(10, driveDb / 20)
            f1 = antiderivative(0)
        }

        private func antiderivative(_ x: Double) -> Double {
            // ∫ tanh(g·x) dx = ln(cosh(g·x)) / g, computed overflow-safe
            let gx = abs(gain * x)
            let lnCosh = gx > 20 ? gx - log(2.0) : log(cosh(gx))
            return lnCosh / gain
        }

        mutating func process(_ x: Double) -> Double {
            let f = antiderivative(x)
            let dx = x - x1
            let y: Double = abs(dx) < 1e-9
                ? tanh(gain * 0.5 * (x + x1))
                : (f - f1) / dx
            x1 = x
            f1 = f
            return y
        }
    }

    /// Stereo-linked RMS detector with a 6 dB soft knee — one gain for all
    /// channels, so the stereo image holds still while the song breathes.
    struct GlueCompressor {
        private let thresholdDb: Double
        private let slope: Double
        private let kneeDb: Double
        private let aAtt: Double
        private let aRel: Double
        private var env = 0.0 // mean-square envelope

        init(thresholdDb: Double, ratio: Double, kneeDb: Double = 6,
             attackMs: Double, releaseMs: Double, fs: Double) {
            self.thresholdDb = thresholdDb
            self.slope = 1.0 / ratio - 1.0
            self.kneeDb = kneeDb
            self.aAtt = exp(-1.0 / (attackMs * 0.001 * fs))
            self.aRel = exp(-1.0 / (releaseMs * 0.001 * fs))
        }

        mutating func gain(meanSquare: Double) -> Double {
            let coeff = meanSquare > env ? aAtt : aRel
            env = meanSquare + coeff * (env - meanSquare)
            let levelDb = 10 * log10(max(env, 1e-12))
            let over = levelDb - thresholdDb
            let gDb: Double
            if over <= -kneeDb / 2 {
                gDb = 0
            } else if over >= kneeDb / 2 {
                gDb = slope * over
            } else {
                let t = over + kneeDb / 2
                gDb = slope * t * t / (2 * kneeDb)
            }
            return pow(10, gDb / 20)
        }
    }

    // MARK: true-peak lookahead limiter

    /// Brickwall with 4x-oversampled inter-sample peak detection and a 2 ms
    /// lookahead window: gain reaches each peak before the peak arrives, so
    /// transients duck cleanly and the encoded stream honors the ceiling.
    enum TruePeakLimiter {
        static func limit(_ channels: inout [[Double]], fs: Double,
                          thresholdDb: Double = -1.0,
                          lookaheadMs: Double = 2.0,
                          releaseMs: Double = 100.0) {
            let n = channels[0].count
            guard n > 0 else { return }
            let thresh = pow(10, thresholdDb / 20) * 0.995 // small engraving margin
            let lookahead = max(1, Int(lookaheadMs / 1000 * fs))

            // 4x interpolation kernel (windowed sinc, 8 taps per phase)
            let factor = 4, tapsPerPhase = 8
            let total = tapsPerPhase * factor
            var kernel = [Double](repeating: 0, count: total)
            let mid = Double(total - 1) / 2
            for i in 0..<total {
                let x = Double(i) - mid
                let sinc = x == 0 ? 1.0 : sin(.pi * x / Double(factor)) / (.pi * x / Double(factor))
                let win = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(total - 1))
                kernel[i] = sinc * win
            }

            // Per-sample required gain from the true-peak estimate across channels
            var gReq = [Double](repeating: 1.0, count: n)
            for ch in channels {
                for i in 0..<n {
                    var peak = abs(ch[i])
                    for phase in 1..<factor {
                        var acc = 0.0
                        for k in 0..<tapsPerPhase {
                            let idx = i - k
                            if idx >= 0 { acc += ch[idx] * kernel[k * factor + phase] }
                        }
                        peak = max(peak, abs(acc))
                    }
                    if peak > thresh {
                        gReq[i] = min(gReq[i], thresh / peak)
                    }
                }
            }

            // Sliding-window minimum over [i, i + lookahead] (monotonic deque)
            var winMin = [Double](repeating: 1.0, count: n)
            var deque = [Int]()
            deque.reserveCapacity(lookahead + 1)
            var head = 0
            for j in 0..<n + lookahead {
                let incoming = min(j, n - 1)
                if j < n {
                    while deque.count > head && gReq[deque.last!] >= gReq[j] { deque.removeLast() }
                    deque.append(j)
                }
                let i = j - lookahead
                if i >= 0 {
                    while deque.count > head && deque[head] < i { head += 1 }
                    winMin[i] = deque.count > head ? gReq[deque[head]] : gReq[incoming]
                }
            }

            // Smooth: fast attack (envelope dives ahead of the transient thanks
            // to the lookahead min), musical release
            let aAtt = exp(-1.0 / (0.0005 * fs))
            let aRel = exp(-1.0 / (releaseMs * 0.001 * fs))
            var env = 1.0
            for i in 0..<n {
                let target = winMin[i]
                let coeff = target < env ? aAtt : aRel
                env = target + coeff * (env - target)
                let g = min(env, 1.0)
                for c in 0..<channels.count {
                    let v = channels[c][i] * g
                    channels[c][i] = max(-thresh, min(thresh, v))
                }
            }
        }
    }

    // MARK: mode dispatch

    func render(mode: MasteringMode, input: URL, output: URL, metrics: Metrics) throws -> URL {
        switch mode {
        case .core:  return try applyCompensation(input: input, output: output, metrics: metrics)
        case .pure:  return try clearRender(input: input, output: output, metrics: metrics)
        case .heat:  return try v1LegacyRender(input: input, output: output, metrics: metrics)
        case .club:  return try clubRender(input: input, output: output, metrics: metrics)
        case .ivory: return try ivoryRender(input: input, output: output, metrics: metrics)
        case .vox:   return try voxRender(input: input, output: output, metrics: metrics)
        }
    }

    // MARK: main render (Resonance v2)

    func applyCompensation(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        let lufs = metrics.integratedLufs
        let slope = metrics.spectralSlope
        let corr = metrics.correlation

        // Stage 1: Sub-Sonic Control
        let hpfFreq: Double = slope > 1.4 ? 35 : 30
        var hpf = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: hpfFreq, q: 0.7071) }

        // Stage 2: Mid/Side hygiene
        let doMonoSub = channels == 2 && corr < 0.6
        let doWiden = channels == 2 && corr > 0.7
        var sideHP = Biquad.highPass(fs: fs, f0: 120, q: 0.7071)
        var sideSplit = OnePoleSplit(fs: fs, fc: 120)
        let widthGain = pow(10, 1.2 / 20) // +1.2 dB of side, above the mono sub

        // Stage 3: Organic Heat — sub band passes clean, upper band saturates
        let driveDb: Double = lufs < -18 ? 1.5 : 1.0
        var subSplit = (0..<channels).map { _ in OnePoleSplit(fs: fs, fc: 150) }
        var adaa = (0..<channels).map { _ in ADAATanh(driveDb: driveDb) }

        // Stage 4: Adaptive Spectral Balancing
        let mudHz = metrics.mudCenterHz
        var mudCut: [Biquad]? = slope > 1.4
            ? (0..<channels).map { _ in Biquad.peak(fs: fs, f0: mudHz, gainDb: -2.5, q: 0.4) } : nil
        let airGain: Double = slope > 1.2 ? 3.5 : 2.0
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: airGain, q: 0.7071) }
        var bodyShelf: [Biquad]? = slope < 1.1
            ? (0..<channels).map { _ in Biquad.lowShelf(fs: fs, f0: 200, gainDb: 2.0, q: 0.7071) } : nil

        // Stage 5: Program Glue
        let compRatio: Double = lufs > -12 ? 1.2 : 1.5
        var comp = GlueCompressor(thresholdDb: -22, ratio: compRatio,
                                  attackMs: 50, releaseMs: 200, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            for c in 0..<channels {
                work[c][i] = hpf[c].process(work[c][i])
            }

            if doMonoSub || doWiden {
                let l = work[0][i], r = work[1][i]
                let midSample = (l + r) / 2
                var side = (l - r) / 2
                if doMonoSub { side = sideHP.process(side) }
                if doWiden {
                    let lowSide = sideSplit.low(side)
                    side = lowSide + (side - lowSide) * widthGain
                }
                work[0][i] = midSample + side
                work[1][i] = midSample - side
            }

            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                let sub = subSplit[c].low(s)
                s = sub + adaa[c].process(s - sub)
                if mudCut != nil { s = mudCut![c].process(s) }
                s = airShelf[c].process(s)
                if bodyShelf != nil { s = bodyShelf![c].process(s) }
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        // Stages 6 + 7: closed-loop level into the true-peak brickwall.
        // Measure, trim, limit, re-measure — lands on target within 0.05 LU.
        let preLufs = Loudness.integratedLufs(buffer: AudioBuffer(channels: work, sampleRate: fs))
        var trimDb = targetLufs - preLufs
        var out = work
        for _ in 0..<3 {
            out = work
            let g = pow(10, trimDb / 20)
            for c in 0..<channels {
                var scale = g
                vDSP_vsmulD(out[c], 1, &scale, &out[c], 1, vDSP_Length(frames))
            }
            TruePeakLimiter.limit(&out, fs: fs)
            let measured = Loudness.integratedLufs(buffer: AudioBuffer(channels: out, sampleRate: fs))
            let residual = targetLufs - measured
            if abs(residual) < 0.05 { break }
            trimDb += residual
        }

        try WavWriter.write(channels: out, sampleRate: fs, to: output, bitDepth: 24)
        return output
    }

    // MARK: CLEAR mode (acoustic clarity)

    func clearRender(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        // Step 1: 40Hz 24dB/oct Butterworth HPF (two cascaded 2nd-order stages)
        var hpf1 = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: 40, q: 0.7071) }
        var hpf2 = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: 40, q: 0.7071) }

        // Step 2: 180Hz low-shelf -3.5dB Q0.7 (boxiness suppression)
        var lowShelf = (0..<channels).map { _ in Biquad.lowShelf(fs: fs, f0: 180, gainDb: -3.5, q: 0.7) }

        // Step 3: 450Hz bell -2.0dB Q0.5 (spectral unmasking)
        var mudCut = (0..<channels).map { _ in Biquad.peak(fs: fs, f0: 450, gainDb: -2.0, q: 0.5) }

        // Step 4: 12kHz high-shelf +3.0dB (air excitation)
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: 3.0, q: 0.7071) }

        // Step 5: Transparency compressor (leveling, not loudness)
        var comp = GlueCompressor(thresholdDb: -18, ratio: 1.15, kneeDb: 6,
                                  attackMs: 60, releaseMs: 250, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                s = hpf1[c].process(s)
                s = hpf2[c].process(s)
                s = lowShelf[c].process(s)
                s = mudCut[c].process(s)
                s = airShelf[c].process(s)
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        // Closed-loop LUFS + true-peak limiter (same finishing stage as v2)
        let preLufs = Loudness.integratedLufs(buffer: AudioBuffer(channels: work, sampleRate: fs))
        var trimDb = targetLufs - preLufs
        var out = work
        for _ in 0..<3 {
            out = work
            let g = pow(10, trimDb / 20)
            for c in 0..<channels {
                var scale = g
                vDSP_vsmulD(out[c], 1, &scale, &out[c], 1, vDSP_Length(frames))
            }
            TruePeakLimiter.limit(&out, fs: fs)
            let measured = Loudness.integratedLufs(buffer: AudioBuffer(channels: out, sampleRate: fs))
            let residual = targetLufs - measured
            if abs(residual) < 0.05 { break }
            trimDb += residual
        }

        try WavWriter.write(channels: out, sampleRate: fs, to: output, bitDepth: 24)
        return output
    }

    // MARK: Unified Hybrid v1 (original alpha engine, ported from commit 6bb41b1)

    func v1LegacyRender(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        let lufs = metrics.integratedLufs
        let slope = metrics.spectralSlope
        let corr = metrics.correlation

        // Stage 1: Adaptive HPF (same as v2's sub-sonic control)
        let hpfFreq: Double = slope > 1.4 ? 35 : 30
        var hpf = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: hpfFreq, q: 0.7071) }

        // Stage 2: Gentle saturation (raw tanh, no ADAA — faithful to the original)
        let driveDb: Double = lufs < -18 ? 1.5 : 1.0
        let driveLinear = pow(10, driveDb / 20)

        // Stage 3: Adaptive Spectral Balancing (same EQ logic as v2)
        let mudHz = metrics.mudCenterHz
        var mudCut: [Biquad]? = slope > 1.4
            ? (0..<channels).map { _ in Biquad.peak(fs: fs, f0: mudHz, gainDb: -2.5, q: 0.4) } : nil
        let airGain: Double = slope > 1.2 ? 3.5 : 2.0
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: airGain, q: 0.7071) }
        var bodyShelf: [Biquad]? = slope < 1.1
            ? (0..<channels).map { _ in Biquad.lowShelf(fs: fs, f0: 200, gainDb: 2.0, q: 0.7071) } : nil

        // Stage 4: Mono-sub fold for phase-risky tracks (simplified M/S — no widening)
        var sideHP = Biquad.highPass(fs: fs, f0: 120, q: 0.7071)
        let doMonoSub = channels == 2 && corr < 0.6

        // Stage 5: Program Glue (original v1 params)
        let compRatio: Double = lufs > -12 ? 1.2 : 1.5
        var comp = GlueCompressor(thresholdDb: -22, ratio: compRatio,
                                  attackMs: 50, releaseMs: 200, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            for c in 0..<channels {
                work[c][i] = hpf[c].process(work[c][i])
            }

            if doMonoSub {
                let l = work[0][i], r = work[1][i]
                let midSample = (l + r) / 2
                var side = (l - r) / 2
                side = sideHP.process(side)
                work[0][i] = midSample + side
                work[1][i] = midSample - side
            }

            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                s = tanh(driveLinear * s)
                if mudCut != nil { s = mudCut![c].process(s) }
                s = airShelf[c].process(s)
                if bodyShelf != nil { s = bodyShelf![c].process(s) }
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        // Simple gain trim + true-peak limiter (v1: no closed-loop re-measurement)
        let preLufs = Loudness.integratedLufs(buffer: AudioBuffer(channels: work, sampleRate: fs))
        let trimDb = targetLufs - preLufs
        let g = pow(10, trimDb / 20)
        var out = work
        for c in 0..<channels {
            var scale = g
            vDSP_vsmulD(out[c], 1, &scale, &out[c], 1, vDSP_Length(frames))
        }
        TruePeakLimiter.limit(&out, fs: fs)

        try WavWriter.write(channels: out, sampleRate: fs, to: output, bitDepth: 24)
        return output
    }

    // MARK: shared closed-loop finish (measure, trim, limit, re-measure)

    /// Lands the work buffer exactly on target, then writes it. Used by the
    /// newer renders; the original three keep their inline finishing stages.
    private func closedLoopFinish(work: [[Double]], fs: Double, target: Double, output: URL) throws -> URL {
        let channels = work.count
        let frames = work.first?.count ?? 0
        let preLufs = Loudness.integratedLufs(buffer: AudioBuffer(channels: work, sampleRate: fs))
        var trimDb = target - preLufs
        var out = work
        for _ in 0..<3 {
            out = work
            let g = pow(10, trimDb / 20)
            for c in 0..<channels {
                var scale = g
                vDSP_vsmulD(out[c], 1, &scale, &out[c], 1, vDSP_Length(frames))
            }
            TruePeakLimiter.limit(&out, fs: fs)
            let measured = Loudness.integratedLufs(buffer: AudioBuffer(channels: out, sampleRate: fs))
            let residual = target - measured
            if abs(residual) < 0.05 { break }
            trimDb += residual
        }
        try WavWriter.write(channels: out, sampleRate: fs, to: output, bitDepth: 24)
        return output
    }

    // MARK: CLUB mode (loud club print, closed-loop -8 LUFS)

    func clubRender(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        let lufs = metrics.integratedLufs
        let slope = metrics.spectralSlope
        let corr = metrics.correlation

        var hpf = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: 30, q: 0.7071) }

        let doMonoSub = channels == 2 && corr < 0.6
        let doWiden = channels == 2 && corr > 0.7
        var sideHP = Biquad.highPass(fs: fs, f0: 120, q: 0.7071)
        var sideSplit = OnePoleSplit(fs: fs, fc: 120)
        let widthGain = pow(10, 1.2 / 20)

        // Hotter drive for density; sub band still passes clean.
        var subSplit = (0..<channels).map { _ in OnePoleSplit(fs: fs, fc: 150) }
        var adaa = (0..<channels).map { _ in ADAATanh(driveDb: 2.5) }

        let mudHz = metrics.mudCenterHz
        var mudCut: [Biquad]? = slope > 1.4
            ? (0..<channels).map { _ in Biquad.peak(fs: fs, f0: mudHz, gainDb: -2.5, q: 0.4) } : nil
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: 4.0, q: 0.7071) }
        var bodyShelf: [Biquad]? = slope < 1.1
            ? (0..<channels).map { _ in Biquad.lowShelf(fs: fs, f0: 200, gainDb: 2.0, q: 0.7071) } : nil

        // Harder glue for club density.
        let compRatio: Double = lufs > -12 ? 1.6 : 2.0
        var comp = GlueCompressor(thresholdDb: -20, ratio: compRatio,
                                  attackMs: 30, releaseMs: 150, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            for c in 0..<channels {
                work[c][i] = hpf[c].process(work[c][i])
            }

            if doMonoSub || doWiden {
                let l = work[0][i], r = work[1][i]
                let midSample = (l + r) / 2
                var side = (l - r) / 2
                if doMonoSub { side = sideHP.process(side) }
                if doWiden {
                    let lowSide = sideSplit.low(side)
                    side = lowSide + (side - lowSide) * widthGain
                }
                work[0][i] = midSample + side
                work[1][i] = midSample - side
            }

            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                let sub = subSplit[c].low(s)
                s = sub + adaa[c].process(s - sub)
                if mudCut != nil { s = mudCut![c].process(s) }
                s = airShelf[c].process(s)
                if bodyShelf != nil { s = bodyShelf![c].process(s) }
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        return try closedLoopFinish(work: work, fs: fs, target: MasteringMode.club.targetLufs, output: output)
    }

    // MARK: IVORY mode (gentle piano voicing, closed-loop -14 LUFS)

    func ivoryRender(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        let slope = metrics.spectralSlope

        // Soft 25Hz high-pass; transients pass untouched.
        var hpf = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: 25, q: 0.7071) }

        // Mud cut only for genuinely dark material.
        let mudHz = metrics.mudCenterHz
        var mudCut: [Biquad]? = slope > 1.6
            ? (0..<channels).map { _ in Biquad.peak(fs: fs, f0: mudHz, gainDb: -2.0, q: 0.5) } : nil
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: 2.0, q: 0.7071) }

        // Transparent leveling, not loudness.
        var comp = GlueCompressor(thresholdDb: -18, ratio: 1.15, kneeDb: 6,
                                  attackMs: 60, releaseMs: 250, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                s = hpf[c].process(s)
                if mudCut != nil { s = mudCut![c].process(s) }
                s = airShelf[c].process(s)
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        return try closedLoopFinish(work: work, fs: fs, target: MasteringMode.ivory.targetLufs, output: output)
    }

    // MARK: VOX mode (forward vocal presence, closed-loop -14 LUFS)

    func voxRender(input: URL, output: URL, metrics: Metrics) throws -> URL {
        let buffer = try AudioLoader.load(url: input)
        let fs = buffer.sampleRate
        let channels = buffer.channelCount
        let frames = buffer.frameCount

        // 80Hz high-pass keeps rumble off the vocal range.
        var hpf = (0..<channels).map { _ in Biquad.highPass(fs: fs, f0: 80, q: 0.7071) }

        // Presence bell puts the voice on top; air shelf keeps it open.
        var presence = (0..<channels).map { _ in Biquad.peak(fs: fs, f0: 3000, gainDb: 2.5, q: 1.0) }
        var airShelf = (0..<channels).map { _ in Biquad.highShelf(fs: fs, f0: 12000, gainDb: 3.0, q: 0.7071) }

        var subSplit = (0..<channels).map { _ in OnePoleSplit(fs: fs, fc: 150) }
        var adaa = (0..<channels).map { _ in ADAATanh(driveDb: 1.0) }

        var comp = GlueCompressor(thresholdDb: -20, ratio: 1.3, kneeDb: 6,
                                  attackMs: 40, releaseMs: 180, fs: fs)

        var work = buffer.channels
        for i in 0..<frames {
            var meanSquare = 0.0
            for c in 0..<channels {
                var s = work[c][i]
                s = hpf[c].process(s)
                let sub = subSplit[c].low(s)
                s = sub + adaa[c].process(s - sub)
                s = presence[c].process(s)
                s = airShelf[c].process(s)
                work[c][i] = s
                meanSquare += s * s
            }
            let g = comp.gain(meanSquare: meanSquare / Double(channels))
            for c in 0..<channels { work[c][i] *= g }
        }

        return try closedLoopFinish(work: work, fs: fs, target: MasteringMode.vox.targetLufs, output: output)
    }
}

// MARK: - WAV output

enum WavWriter {
    static func write(channels: [[Double]], sampleRate: Double, to url: URL, bitDepth: Int) throws {
        let channelCount = channels.count
        let frames = channels.first?.count ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: sampleRate,
                                    channels: AVAudioChannelCount(channelCount),
                                    interleaved: false)!
        let ditherAmp = bitDepth <= 16 ? 1.0 / 32768.0 : 0.0
        var rng = SystemRandomNumberGenerator()

        let chunk = 1 << 16
        var start = 0
        while start < frames {
            let n = min(chunk, frames - start)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<channelCount {
                let dst = buf.floatChannelData![c]
                if ditherAmp > 0 {
                    for i in 0..<n {
                        let tpdf = (Double.random(in: 0..<1, using: &rng)
                                  - Double.random(in: 0..<1, using: &rng)) * ditherAmp
                        dst[i] = Float(channels[c][start + i] + tpdf)
                    }
                } else {
                    for i in 0..<n { dst[i] = Float(channels[c][start + i]) }
                }
            }
            try file.write(from: buf)
            start += n
        }
    }
}

// MARK: - Master file naming

enum MasterNamer {
    static let firstWords = [
        "fern", "dusk", "moon", "dawn", "mist", "wave", "stone", "pine",
        "lake", "ash", "seed", "vine", "moss", "reed", "rain", "cloud",
        "dew", "bloom", "vale", "cliff", "sage", "root", "leaf", "brook",
        "creek", "shore", "wind", "soil", "peak", "veil", "hush", "slate",
        "frost", "flint", "bark", "nest", "thaw", "shell", "spark", "dust",
        "amber", "opal", "jade", "onyx", "iris", "lotus", "cedar", "birch",
        "elm", "oak", "willow", "hawthorn", "rowan", "ivy", "heather", "gorse",
        "aster", "calla", "lupin", "orchid", "tansy", "yarrow", "glimmer", "ember",
        "ember", "cinder", "quartz", "agate", "jasper", "flame", "ember", "ember"
    ]

    static let secondWords = [
        "light", "beam", "fall", "rise", "pool", "path", "wing", "cove",
        "bell", "foam", "star", "ridge", "shade", "drift", "glow", "spire",
        "deep", "crest", "flux", "turn", "fold", "brim", "edge", "rift",
        "lark", "wren", "sky", "mere", "grove", "reach", "firth", "knoll",
        "gale", "bight", "tarn", "holt", "ghyll", "rill", "wold", "bough",
        "whisper", "harbor", "lantern", "cascade", "hollow", "summit", "tender", "silence",
        "resonance", "horizon", "timber", "canopy", "meadow", "valley", "thicket", "orchard",
        "twilight", "solstice", "equinox", "compass", "anchor", "vessel", "harbor", "sanctum"
    ]

    static func generate(in directory: URL) -> (base: String, masterName: String, originalName: String) {
        var rng = SystemRandomNumberGenerator()
        var n = 1
        while n < 5000 {
            let w1 = firstWords.randomElement(using: &rng)!
            let w2 = secondWords.randomElement(using: &rng)!
            let base = "\(w1) \(w2) \(n)"
            let masterFile = directory.appendingPathComponent("\(base).wav")
            let originalFile = directory.appendingPathComponent("\(base) original.wav")
            let fm = FileManager.default
            if !fm.fileExists(atPath: masterFile.path) && !fm.fileExists(atPath: originalFile.path) {
                return (base, "\(base)", "\(base) original")
            }
            n += 1
        }
        let ts = Int(Date().timeIntervalSince1970)
        return ("track \(ts)", "track \(ts)", "track \(ts) original")
    }
}
