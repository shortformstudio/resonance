import Foundation
import Accelerate

// MARK: - Biquad

struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    mutating func process(buffer: inout [Double]) {
        for i in 0..<buffer.count { buffer[i] = process(buffer[i]) }
    }

    mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }

    // RBJ cookbook designs
    static func highPass(fs: Double, f0: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        return Biquad(b0: (1 + cw) / 2, b1: -(1 + cw), b2: (1 + cw) / 2,
                      a0: 1 + alpha, a1: -2 * cw, a2: 1 - alpha)
    }

    static func peak(fs: Double, f0: Double, gainDb: Double, q: Double) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        return Biquad(b0: 1 + alpha * A, b1: -2 * cw, b2: 1 - alpha * A,
                      a0: 1 + alpha / A, a1: -2 * cw, a2: 1 - alpha / A)
    }

    static func highShelf(fs: Double, f0: Double, gainDb: Double, q: Double) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let sqA = sqrt(A)
        return Biquad(
            b0: A * ((A + 1) + (A - 1) * cw + 2 * sqA * alpha),
            b1: -2 * A * ((A - 1) + (A + 1) * cw),
            b2: A * ((A + 1) + (A - 1) * cw - 2 * sqA * alpha),
            a0: (A + 1) - (A - 1) * cw + 2 * sqA * alpha,
            a1: 2 * ((A - 1) - (A + 1) * cw),
            a2: (A + 1) - (A - 1) * cw - 2 * sqA * alpha)
    }

    static func lowShelf(fs: Double, f0: Double, gainDb: Double, q: Double) -> Biquad {
        let A = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let cw = cos(w0)
        let sqA = sqrt(A)
        return Biquad(
            b0: A * ((A + 1) - (A - 1) * cw + 2 * sqA * alpha),
            b1: 2 * A * ((A - 1) - (A + 1) * cw),
            b2: A * ((A + 1) - (A - 1) * cw - 2 * sqA * alpha),
            a0: (A + 1) + (A - 1) * cw + 2 * sqA * alpha,
            a1: -2 * ((A - 1) + (A + 1) * cw),
            a2: (A + 1) + (A - 1) * cw - 2 * sqA * alpha)
    }
}

// MARK: - Loudness (ITU-R BS.1770-4)

enum Loudness {
    /// K-weighting: stage 1 high shelf + stage 2 high pass (BS.1770 constants).
    static func kWeightingFilters(fs: Double) -> (Biquad, Biquad) {
        let shelf = Biquad.highShelf(fs: fs, f0: 1681.9744509555319,
                                     gainDb: 3.99984385397, q: 0.7071752369554193)
        let hp = Biquad.highPass(fs: fs, f0: 38.13547087613982, q: 0.5003270373253953)
        return (shelf, hp)
    }

    /// Gated integrated loudness in LUFS.
    static func integratedLufs(buffer: AudioBuffer) -> Double {
        let fs = buffer.sampleRate
        let blockSize = Int(0.400 * fs)
        let hop = Int(0.100 * fs)
        guard blockSize > 0, buffer.frameCount >= blockSize else { return -70.0 }

        // K-weight each channel
        var weighted: [[Double]] = []
        for ch in buffer.channels {
            var (shelf, hp) = kWeightingFilters(fs: fs)
            var data = ch
            shelf.process(buffer: &data)
            hp.process(buffer: &data)
            weighted.append(data)
        }

        // Mean-square per 400ms block, 75% overlap
        let n = buffer.frameCount
        var blockLoudness: [Double] = []
        var blockPowers: [Double] = []
        var start = 0
        while start + blockSize <= n {
            var power = 0.0
            for ch in weighted {
                var ms = 0.0
                ch.withUnsafeBufferPointer { p in
                    vDSP_measqvD(p.baseAddress! + start, 1, &ms, vDSP_Length(blockSize))
                }
                power += ms // channel weight 1.0 (L/R/C)
            }
            blockPowers.append(power)
            blockLoudness.append(-0.691 + 10 * log10(max(power, 1e-15)))
            start += hop
        }
        guard !blockPowers.isEmpty else { return -70.0 }

        // Absolute gate at -70 LUFS
        var gated = zip(blockPowers, blockLoudness).filter { $0.1 > -70.0 }.map { $0.0 }
        guard !gated.isEmpty else { return -70.0 }

        // Relative gate at mean - 10 LU
        let meanPower = gated.reduce(0, +) / Double(gated.count)
        let relThreshold = -0.691 + 10 * log10(meanPower) - 10.0
        gated = zip(blockPowers, blockLoudness)
            .filter { $0.1 > -70.0 && $0.1 > relThreshold }
            .map { $0.0 }
        guard !gated.isEmpty else { return -70.0 }

        let finalPower = gated.reduce(0, +) / Double(gated.count)
        return -0.691 + 10 * log10(finalPower)
    }

    /// True peak via 4x polyphase FIR oversampling of the mono mix.
    static func truePeakDb(mono: [Double]) -> Double {
        guard !mono.isEmpty else { return -144.0 }
        let factor = 4
        let tapsPerPhase = 24
        let total = tapsPerPhase * factor
        // Windowed-sinc lowpass at Nyquist/4 of the upsampled rate
        var kernel = [Double](repeating: 0, count: total)
        let mid = Double(total - 1) / 2
        for i in 0..<total {
            let x = Double(i) - mid
            let sinc = x == 0 ? 1.0 : sin(.pi * x / Double(factor)) / (.pi * x / Double(factor))
            let win = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(total - 1)) // Hamming
            kernel[i] = sinc * win
        }

        var peak = 0.0
        let n = mono.count
        for phase in 0..<factor {
            // y[m] for upsample index m ≡ phase (mod factor):
            // y = Σ_k mono[j - k] * kernel[k*factor + phase]
            for j in 0..<n {
                var acc = 0.0
                var k = 0
                while k < tapsPerPhase {
                    let idx = j - k
                    if idx >= 0 { acc += mono[idx] * kernel[k * factor + phase] }
                    k += 1
                }
                let a = abs(acc)
                if a > peak { peak = a }
            }
        }
        return peak > 0 ? 20 * log10(peak) : -144.0
    }
}

// MARK: - Spectral (Welch PSD + log-log slope)

enum Spectral {
    /// Welch PSD, hann window, 50% overlap, one-sided — mirrors scipy defaults.
    static func welch(signal: [Double], fs: Double, nperseg: Int = 8192) -> (freqs: [Double], psd: [Double]) {
        let seg = min(nperseg, signal.count)
        guard seg >= 8 else { return ([], []) }
        let hop = seg / 2

        var window = [Double](repeating: 0, count: seg)
        vDSP_hann_windowD(&window, vDSP_Length(seg), Int32(vDSP_HANN_DENORM))
        var winSumSq = 0.0
        vDSP_svesqD(window, 1, &winSumSq, vDSP_Length(seg))

        let log2n = vDSP_Length(ceil(log2(Double(seg))))
        let fftSize = 1 << Int(log2n)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetupD(setup) }

        let half = fftSize / 2
        var accum = [Double](repeating: 0, count: half + 1)
        var segments = 0

        var real = [Double](repeating: 0, count: half)
        var imag = [Double](repeating: 0, count: half)
        var frame = [Double](repeating: 0, count: fftSize)

        var start = 0
        while start + seg <= signal.count {
            // Detrend (remove mean), window, zero-pad to fftSize
            var mean = 0.0
            signal.withUnsafeBufferPointer { p in
                vDSP_meanvD(p.baseAddress! + start, 1, &mean, vDSP_Length(seg))
            }
            for i in 0..<seg { frame[i] = (signal[start + i] - mean) * window[i] }
            if seg < fftSize { for i in seg..<fftSize { frame[i] = 0 } }

            frame.withUnsafeBufferPointer { fp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        fp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) {
                            vDSP_ctozD($0, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    }
                }
            }

            // vDSP packed real FFT scales by 2; periodogram = |X|^2 / (fs * winSumSq)
            let scale = 1.0 / (4.0 * fs * winSumSq)
            accum[0] += real[0] * real[0] * scale
            accum[half] += imag[0] * imag[0] * scale // Nyquist packed in imag[0]
            for k in 1..<half {
                accum[k] += (real[k] * real[k] + imag[k] * imag[k]) * scale
            }
            segments += 1
            start += hop
        }
        guard segments > 0 else { return ([], []) }

        var psd = accum.map { $0 / Double(segments) }
        // One-sided doubling (all bins except DC and Nyquist)
        for k in 1..<half { psd[k] *= 2 }

        let df = fs / Double(fftSize)
        let freqs = (0...half).map { Double($0) * df }
        return (freqs, psd)
    }

    struct Report {
        var slope: Double
        var rSquared: Double
        var mudCenterHz: Double
        var mudProminenceDb: Double
    }

    /// alpha where PSD ~ 1/f^alpha over 20 Hz – 20 kHz (1.0 = pink noise), plus
    /// the detected low-mid buildup center: the 200–600 Hz bin rising furthest
    /// above the track's own spectral tilt line.
    static func analyze(signal: [Double], fs: Double) -> Report {
        let (freqs, psd) = welch(signal: signal, fs: fs)
        var xs: [Double] = [], ys: [Double] = []
        for (f, p) in zip(freqs, psd) where f >= 20 && f <= 20000 && p > 0 {
            xs.append(log10(f))
            ys.append(log10(p))
        }
        guard xs.count >= 2 else { return Report(slope: 0, rSquared: 0, mudCenterHz: 420, mudProminenceDb: 0) }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<xs.count {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return Report(slope: 0, rSquared: 0, mudCenterHz: 420, mudProminenceDb: 0) }
        let m = sxy / sxx
        let b = my - m * mx
        let r = sxy / sqrt(sxx * syy)

        var mudHz = 420.0
        var mudProm = 0.0
        for (f, p) in zip(freqs, psd) where f >= 200 && f <= 600 && p > 0 {
            let baselineLog = m * log10(f) + b
            let promDb = 10 * (log10(p) - baselineLog)
            if promDb > mudProm {
                mudProm = promDb
                mudHz = f
            }
        }
        if mudProm < 2.0 { mudHz = 420.0 } // gentle default when the buildup is mild

        return Report(slope: -m, rSquared: r * r,
                      mudCenterHz: (mudHz * 10).rounded() / 10,
                      mudProminenceDb: (mudProm * 100).rounded() / 100)
    }

    /// alpha where PSD ~ 1/f^alpha over 20 Hz – 20 kHz; 1.0 = pink noise.
    static func slope(signal: [Double], fs: Double) -> (slope: Double, rSquared: Double) {
        let report = analyze(signal: signal, fs: fs)
        return (report.slope, report.rSquared)
    }
}

// MARK: - Stereo field

enum Stereo {
    static func analyze(buffer: AudioBuffer) -> (correlation: Double, width: Double) {
        guard buffer.isStereo else { return (1.0, 0.0) }
        let left = buffer.channels[0]
        let right = buffer.channels[1]
        let n = min(left.count, right.count)
        guard n > 1 else { return (1.0, 0.0) }

        var ml = 0.0, mr = 0.0
        vDSP_meanvD(left, 1, &ml, vDSP_Length(n))
        vDSP_meanvD(right, 1, &mr, vDSP_Length(n))

        var sxy = 0.0, sxx = 0.0, syy = 0.0
        var midPower = 0.0, sidePower = 0.0
        for i in 0..<n {
            let dl = left[i] - ml, dr = right[i] - mr
            sxy += dl * dr; sxx += dl * dl; syy += dr * dr
            let mid = (left[i] + right[i]) / 2
            let side = (left[i] - right[i]) / 2
            midPower += mid * mid
            sidePower += side * side
        }
        let corr = (sxx > 0 && syy > 0) ? sxy / sqrt(sxx * syy) : 1.0
        let width = (sidePower / Double(n)) / (midPower / Double(n) + 1e-10)
        return (corr, width)
    }
}
