import Foundation
import AVFoundation
import Accelerate

/// Resonance mastering engine, v3 — shared DSP building blocks plus the
/// render entry point. The chain itself is composed in Engine/MasterChain:
///   rate guard → staging → scan → sub-sonic → transient → adaptive EQ →
///   resonance tamer → linked multiband → ADAA heat → glue → stereo →
///   closed-loop LUFS (clipper + 4x true-peak limiter) → WAV / MP3
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

    // MARK: render (modular chain — see Engine/)

    /// Load → MasterChain (scan, adaptive stages, closed-loop landing) → export.
    @discardableResult
    func render(mode: MasteringMode, input: URL, output: URL, metrics: Metrics,
                format: OutputFormat = .wav) throws -> MasterReport {
        let source = try AudioLoader.load(url: input)
        let (mastered, report) = try MasterChain(mode: mode).run(source)
        try Exporter.write(mastered, format: format, to: output)
        return report
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
            let masterMp3 = directory.appendingPathComponent("\(base).mp3")
            let originalFile = directory.appendingPathComponent("\(base) original.wav")
            let fm = FileManager.default
            if !fm.fileExists(atPath: masterFile.path) && !fm.fileExists(atPath: masterMp3.path) && !fm.fileExists(atPath: originalFile.path) {
                return (base, "\(base)", "\(base) original")
            }
            n += 1
        }
        let ts = Int(Date().timeIntervalSince1970)
        return ("track \(ts)", "track \(ts)", "track \(ts) original")
    }
}
