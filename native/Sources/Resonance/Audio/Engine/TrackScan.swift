import Foundation
import Accelerate

/// The scan: a full read of the (staged) signal that every adaptive stage
/// draws its decisions from. Nothing in the chain is a fixed preset.
struct TrackScan {
    var lufs: Double
    var truePeakDb: Double
    var crestDb: Double
    var correlation: Double
    var isStereo: Bool
    /// Octave-band energy (dB) at ReferenceCurve.centers; nil where the band
    /// has no real content (above the source bandwidth or above Nyquist).
    var bandLevelsDb: [Double?]
    /// Highest frequency carrying real program material. A 16 kHz voice memo
    /// reads ~8 kHz here, which keeps the EQ from boosting empty air (noise).
    var contentLimitHz: Double
    /// Side/mid energy ratio below 150 Hz — off-centre bass that needs folding.
    var lowSideRatio: Double

    static func scan(_ buffer: AudioBuffer) -> TrackScan {
        let fs = buffer.sampleRate
        let mono = buffer.mono
        let lufs = Loudness.integratedLufs(buffer: buffer)
        let tp = Loudness.truePeakDb(mono: mono)
        let peak = mono.map(abs).max() ?? 0
        var ms = 0.0
        vDSP_measqvD(mono, 1, &ms, vDSP_Length(mono.count))
        let crest = 20 * log10(max(peak, 1e-9) / max(sqrt(ms), 1e-9))
        let stereo = Stereo.analyze(buffer: buffer)

        let (freqs, psd) = Spectral.welch(signal: mono, fs: fs)
        let limit = contentLimit(freqs: freqs, psd: psd, fs: fs)

        var bands: [Double?] = []
        for fc in ReferenceCurve.centers {
            let lo = fc / sqrt(2), hi = min(fc * sqrt(2), fs / 2)
            guard hi > lo, fc < limit * 0.85, fc < 0.45 * fs else { bands.append(nil); continue }
            var e = 0.0
            for (f, p) in zip(freqs, psd) where f >= lo && f < hi { e += p }
            bands.append(e > 0 ? 10 * log10(e) : nil)
        }

        var lowSide = 0.0
        if buffer.isStereo {
            var lp = [Biquad.lowPass(fs: fs, f0: 150, q: 0.7071), Biquad.lowPass(fs: fs, f0: 150, q: 0.7071)]
            var mE = 0.0, sE = 0.0
            for i in 0..<buffer.frameCount {
                let l = buffer.channels[0][i], r = buffer.channels[1][i]
                let m = lp[0].process((l + r) / 2), s = lp[1].process((l - r) / 2)
                mE += m * m; sE += s * s
            }
            lowSide = sE / max(mE, 1e-12)
        }

        return TrackScan(lufs: lufs, truePeakDb: tp, crestDb: crest,
                         correlation: stereo.correlation, isStereo: buffer.isStereo,
                         bandLevelsDb: bands, contentLimitHz: limit, lowSideRatio: lowSide)
    }

    /// Walk down from Nyquist in 1/6-octave windows until the average power
    /// comes within 50 dB of the 300 Hz – 3 kHz body.
    static func contentLimit(freqs: [Double], psd: [Double], fs: Double) -> Double {
        guard freqs.count > 8 else { return fs / 2 }
        func bandDb(_ lo: Double, _ hi: Double) -> Double {
            var e = 0.0, n = 0
            for (f, p) in zip(freqs, psd) where f >= lo && f < hi { e += p; n += 1 }
            return n > 0 ? 10 * log10(max(e / Double(n), 1e-30)) : -300
        }
        let body = bandDb(300, 3000)
        var hi = fs / 2
        let step = pow(2.0, 1.0 / 6.0)
        while hi > 1000 {
            let lo = hi / step
            if bandDb(lo, hi) > body - 50 { return hi }
            hi = lo
        }
        return 1000
    }

    // MARK: level distributions (used to place every dynamics threshold)

    /// 400 ms mean-square blocks, 100 ms hop, averaged across channels (dB).
    static func blockLevelsDb(_ channels: [[Double]], fs: Double) -> [Double] {
        let n = channels.first?.count ?? 0
        let block = max(1, Int(0.4 * fs)), hop = max(1, Int(0.1 * fs))
        guard n >= block else { return [] }
        var out: [Double] = []
        var start = 0
        while start + block <= n {
            var p = 0.0
            for ch in channels {
                var m = 0.0
                ch.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + start, 1, &m, vDSP_Length(block)) }
                p += m
            }
            let db = 10 * log10(max(p / Double(channels.count), 1e-15))
            if db > -70 { out.append(db) }
            start += hop
        }
        return out
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = min(max(p, 0), 1) * Double(s.count - 1)
        let lo = Int(rank), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }
}
