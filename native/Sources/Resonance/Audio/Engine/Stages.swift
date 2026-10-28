import Foundation

/// One step of the master chain. Stages are pure transforms over the work
/// buffer and are composed in MasterChain; each owns its own filter state.
protocol MasterStage {
    var name: String { get }
    mutating func process(_ work: inout [[Double]], fs: Double)
}

// MARK: - Foundation: 4th-order Butterworth high-pass (also removes DC)

struct SubsonicStage: MasterStage {
    let name = "sub-sonic"
    var hz: Double
    mutating func process(_ work: inout [[Double]], fs: Double) {
        for c in work.indices {
            // Q pair for a 4th-order Butterworth: 0.5412, 1.3066
            var a = Biquad.highPass(fs: fs, f0: hz, q: 0.5412)
            var b = Biquad.highPass(fs: fs, f0: hz, q: 1.3066)
            for i in work[c].indices { work[c][i] = b.process(a.process(work[c][i])) }
        }
    }
}

// MARK: - Adaptive tonal match (scan vs reference curve)

struct AdaptiveEQStage: MasterStage {
    let name = "adaptive eq"
    /// (centre Hz, gain dB) moves actually applied — reported to the UI/log.
    private(set) var moves: [(hz: Double, db: Double)] = []

    init(scan: TrackScan, style: StyleProfile) {
        let centers = ReferenceCurve.centers
        var target = ReferenceCurve.levelsDb
        for i in target.indices where i < style.curveTilt.count { target[i] += style.curveTilt[i] }

        // Anchor the reference curve to this track's own body (160 Hz – 2.5 kHz).
        var diffs: [Double] = []
        for i in centers.indices where centers[i] >= 160 && centers[i] <= 2500 {
            if let l = scan.bandLevelsDb[i] { diffs.append(l - target[i]) }
        }
        guard !diffs.isEmpty else { return }
        let anchor = diffs.reduce(0, +) / Double(diffs.count)

        var raw = [Double](repeating: 0, count: centers.count)
        for i in centers.indices {
            guard let l = scan.bandLevelsDb[i] else { continue }
            let dev = l - (target[i] + anchor)
            var g = -style.eqStrength * dev
            // Never conjure content that isn't there: a band 10 dB+ short of
            // the curve is absent (band-limited source), not merely quiet.
            if dev < -10 { g = 0 }
            if centers[i] <= 80 { g = min(g, 1.0) }            // no sub boom
            if centers[i] >= 10000 { g = min(g, 2.5) }          // tasteful air only
            raw[i] = min(max(g, -style.eqMaxDb), style.eqMaxDb)
        }
        // Light neighbour smoothing → broad, musical curves rather than notches.
        for i in centers.indices {
            guard scan.bandLevelsDb[i] != nil else { continue }
            let l = i > 0 && scan.bandLevelsDb[i - 1] != nil ? raw[i - 1] : raw[i]
            let r = i < centers.count - 1 && scan.bandLevelsDb[i + 1] != nil ? raw[i + 1] : raw[i]
            let g = 0.25 * l + 0.5 * raw[i] + 0.25 * r
            if abs(g) >= 0.3 { moves.append((centers[i], (g * 10).rounded() / 10)) }
        }
    }

    mutating func process(_ work: inout [[Double]], fs: Double) {
        guard !moves.isEmpty else { return }
        let lowest = ReferenceCurve.centers.first!
        for c in work.indices {
            var filters: [Biquad] = moves.map { m in
                if m.hz == lowest { return Biquad.lowShelf(fs: fs, f0: m.hz * 1.5, gainDb: m.db, q: 0.7071) }
                if m.hz >= 10000 { return Biquad.highShelf(fs: fs, f0: m.hz / 1.4, gainDb: m.db, q: 0.7071) }
                return Biquad.peak(fs: fs, f0: m.hz, gainDb: m.db, q: 1.1)
            }
            for i in work[c].indices {
                var s = work[c][i]
                for f in filters.indices { s = filters[f].process(s) }
                work[c][i] = s
            }
        }
    }
}

// MARK: - Transient detail (reuses TransientDesigner)

struct TransientStage: MasterStage {
    let name = "transient detail"
    var attack: Double
    mutating func process(_ work: inout [[Double]], fs: Double) {
        guard attack != 0 else { return }
        var td = TransientDesigner(fs: fs, channels: work.count, attack: attack, sustain: 0)
        td.process(channels: &work, frames: work.first?.count ?? 0)
    }
}

// MARK: - Resonance tamer (reuses ResonanceSuppressor)

struct TamerStage: MasterStage {
    let name = "resonance tamer"
    var depth: Double
    mutating func process(_ work: inout [[Double]], fs: Double) {
        guard depth > 0 else { return }
        var sup = ResonanceSuppressor(fs: fs, channels: work.count, depth: depth)
        sup.process(channels: &work, frames: work.first?.count ?? 0)
    }
}

// MARK: - Stereo-linked 4-band compressor with scanned thresholds

struct MultibandStage: MasterStage {
    let name = "multiband"
    var style: StyleProfile
    static let crossovers = (120.0, 1000.0, 6000.0)
    private(set) var thresholdsDb: [Double] = []

    init(style: StyleProfile) { self.style = style }

    mutating func process(_ work: inout [[Double]], fs: Double) {
        let n = work.first?.count ?? 0
        let chs = work.count
        guard n > 0 else { return }
        let xo = Self.crossovers

        // Scan pass: each band's level distribution sets its own threshold.
        var bandSig = [[Double]](repeating: [Double](repeating: 0, count: n), count: 4)
        var probe = Crossover4(fs: fs, f1: xo.0, f2: xo.1, f3: xo.2)
        for i in 0..<n {
            var m = 0.0
            for c in 0..<chs { m += work[c][i] }
            let (a, b, cc, d) = probe.split(m / Double(chs))
            bandSig[0][i] = a; bandSig[1][i] = b; bandSig[2][i] = cc; bandSig[3][i] = d
        }
        thresholdsDb = (0..<4).map { b in
            (TrackScan.percentile(TrackScan.blockLevelsDb([bandSig[b]], fs: fs), style.mbPercentile) ?? -30)
                + style.mbOffsetDb
        }
        bandSig = []

        // Process pass: one gain per band shared across channels (image holds).
        var xs = (0..<chs).map { _ in Crossover4(fs: fs, f1: xo.0, f2: xo.1, f3: xo.2) }
        var comps = thresholdsDb.map {
            MasteringEngine.GlueCompressor(thresholdDb: $0, ratio: style.mbRatio, kneeDb: 6,
                                           attackMs: style.mbAttackMs, releaseMs: style.mbReleaseMs, fs: fs)
        }
        var bands = [Double](repeating: 0, count: chs * 4)   // [c*4 + k], reused
        var msq = [Double](repeating: 0, count: 4)
        var g = [Double](repeating: 1, count: 4)
        for i in 0..<n {
            msq[0] = 0; msq[1] = 0; msq[2] = 0; msq[3] = 0
            for c in 0..<chs {
                let (a, b, cc, d) = xs[c].split(work[c][i])
                bands[c * 4] = a; bands[c * 4 + 1] = b; bands[c * 4 + 2] = cc; bands[c * 4 + 3] = d
                msq[0] += a * a; msq[1] += b * b; msq[2] += cc * cc; msq[3] += d * d
            }
            for k in 0..<4 { g[k] = comps[k].gain(meanSquare: msq[k] / Double(chs)) }
            for c in 0..<chs {
                let o = c * 4
                work[c][i] = bands[o] * g[0] + bands[o + 1] * g[1] + bands[o + 2] * g[2] + bands[o + 3] * g[3]
            }
        }
    }
}

// MARK: - Harmonic saturation (ADAA tanh, sub band clean, unity small-signal gain)

struct SaturationStage: MasterStage {
    let name = "organic heat"
    var driveDb: Double
    mutating func process(_ work: inout [[Double]], fs: Double) {
        guard driveDb > 0.05 else { return }
        let g = pow(10, driveDb / 20)
        for c in work.indices {
            var split = MasteringEngine.OnePoleSplit(fs: fs, fc: 150)
            var sat = MasteringEngine.ADAATanh(driveDb: driveDb)
            for i in work[c].indices {
                let s = work[c][i]
                let sub = split.low(s)
                work[c][i] = sub + sat.process(s - sub) / g
            }
        }
    }
}

// MARK: - Program glue (stereo-linked RMS, scanned threshold)

struct GlueStage: MasterStage {
    let name = "program glue"
    var style: StyleProfile
    private(set) var thresholdDb = -20.0

    init(style: StyleProfile) { self.style = style }

    mutating func process(_ work: inout [[Double]], fs: Double) {
        let n = work.first?.count ?? 0
        guard n > 0 else { return }
        thresholdDb = (TrackScan.percentile(TrackScan.blockLevelsDb(work, fs: fs), style.gluePercentile) ?? -20)
            + style.glueOffsetDb
        var comp = MasteringEngine.GlueCompressor(thresholdDb: thresholdDb, ratio: style.glueRatio,
                                                  attackMs: style.glueAttackMs, releaseMs: style.glueReleaseMs, fs: fs)
        let chs = Double(work.count)
        for i in 0..<n {
            var m = 0.0
            for c in work.indices { m += work[c][i] * work[c][i] }
            let g = comp.gain(meanSquare: m / chs)
            for c in work.indices { work[c][i] *= g }
        }
    }
}

// MARK: - Stereo field: mono bass + phase-aware width

struct StereoStage: MasterStage {
    let name = "spatial width"
    var monoBassHz: Double
    var widthDb: Double
    var scan: TrackScan
    private(set) var foldBass = false
    private(set) var appliedWidthDb = 0.0

    init(style: StyleProfile, scan: TrackScan) {
        self.scan = scan
        monoBassHz = style.monoBassHz
        widthDb = style.widthDb
        foldBass = scan.isStereo && (scan.lowSideRatio > 0.05 || style.monoBassHz >= 120)
        // Never widen an image that is already fragile in mono.
        appliedWidthDb = scan.isStereo && scan.correlation > 0.3 ? widthDb : 0
    }

    mutating func process(_ work: inout [[Double]], fs: Double) {
        guard work.count == 2, foldBass || appliedWidthDb > 0 else { return }
        var hp1 = Biquad.highPass(fs: fs, f0: monoBassHz, q: 0.5412)
        var hp2 = Biquad.highPass(fs: fs, f0: monoBassHz, q: 1.3066)
        var split = MasteringEngine.OnePoleSplit(fs: fs, fc: 300)
        let wg = pow(10, appliedWidthDb / 20)
        for i in work[0].indices {
            let l = work[0][i], r = work[1][i]
            let m = (l + r) / 2
            var s = (l - r) / 2
            if foldBass { s = hp2.process(hp1.process(s)) }
            if appliedWidthDb > 0 {
                let lo = split.low(s)
                s = lo + (s - lo) * wg
            }
            work[0][i] = m + s
            work[1][i] = m - s
        }
    }
}
