import Foundation
import Accelerate

/// What the chain did, for the log, chat, and library metadata.
struct MasterReport {
    var style: MasteringMode
    var sourceRate: Double
    var processRate: Double
    var contentLimitHz: Double
    var inputLufs: Double
    var outputLufs: Double
    var outputTruePeakDb: Double
    var eqMoves: [(hz: Double, db: Double)]
    var glueThresholdDb: Double
    var stereoFolded: Bool
    var widthDb: Double

    var summary: String {
        let eq = eqMoves.isEmpty ? "flat" :
            eqMoves.map { String(format: "%@ %+.1f", $0.hz >= 1000 ? String(format: "%.1fk", $0.hz / 1000) : String(format: "%.0f", $0.hz), $0.db) }
                   .joined(separator: " · ")
        var s = String(format: "%.1f → %.1f LUFS · %.1f dBTP · eq %@", inputLufs, outputLufs, outputTruePeakDb, eq)
        if processRate != sourceRate { s += String(format: " · %.0f→%.0f Hz", sourceRate, processRate) }
        return s
    }
}

/// The modular mastering pipeline. Order follows standard mastering practice:
///
///   rate guard → gain staging → scan → sub-sonic → transient → adaptive EQ
///   → resonance tamer → multiband → saturation → glue → stereo
///   → closed-loop loudness (clipper + true-peak limiter) → export
///
/// Every style runs this exact chain; StyleProfile supplies the numbers and
/// the scan supplies the thresholds.
struct MasterChain {
    var mode: MasteringMode
    var style: StyleProfile { StyleProfile.forMode(mode) }

    /// Below 44.1 kHz the chain works at 48 kHz: filters, saturation and the
    /// true-peak detector all need headroom above the audio band.
    static let minimumProcessRate = 44_100.0
    static let upsampleRate = 48_000.0
    /// Internal working level: every relative threshold is tuned around it.
    static let stagingLufs = -18.0

    func run(_ source: AudioBuffer) throws -> (AudioBuffer, MasterReport) {
        let style = self.style
        var buffer = source
        if buffer.sampleRate < Self.minimumProcessRate {
            buffer = try Resampler.resample(buffer, to: Self.upsampleRate)
        }
        let fs = buffer.sampleRate
        var work = buffer.channels

        // Gain staging → consistent drive into every stage.
        let inLufs = Loudness.integratedLufs(buffer: buffer)
        if inLufs > -70 { scale(&work, db: Self.stagingLufs - inLufs) }

        let scan = TrackScan.scan(AudioBuffer(channels: work, sampleRate: fs))

        var sub = SubsonicStage(hz: style.highPassHz)
        var transient = TransientStage(attack: style.transientAttack)
        var eq = AdaptiveEQStage(scan: scan, style: style)
        var tamer = TamerStage(depth: style.suppressDepth)
        var mb = MultibandStage(style: style)
        var sat = SaturationStage(driveDb: style.saturationDb)
        var glue = GlueStage(style: style)
        var stereo = StereoStage(style: style, scan: scan)

        sub.process(&work, fs: fs)
        transient.process(&work, fs: fs)
        eq.process(&work, fs: fs)
        tamer.process(&work, fs: fs)
        mb.process(&work, fs: fs)
        sat.process(&work, fs: fs)
        glue.process(&work, fs: fs)
        stereo.process(&work, fs: fs)

        let out = Self.landLoudness(work, fs: fs, target: style.targetLufs,
                                    ceilingDbtp: style.ceilingDbtp, clipDriveDb: style.clipDriveDb)
        let outBuf = AudioBuffer(channels: out, sampleRate: fs)
        let report = MasterReport(style: mode, sourceRate: source.sampleRate, processRate: fs,
                                  contentLimitHz: scan.contentLimitHz,
                                  inputLufs: inLufs,
                                  outputLufs: Loudness.integratedLufs(buffer: outBuf),
                                  outputTruePeakDb: Loudness.truePeakDb(mono: outBuf.channels.count == 1 ? out[0] : Self.peakChannel(out)),
                                  eqMoves: eq.moves, glueThresholdDb: glue.thresholdDb,
                                  stereoFolded: stereo.foldBass, widthDb: stereo.appliedWidthDb)
        return (outBuf, report)
    }

    /// Measure → trim → clip → true-peak limit → re-measure, until the
    /// integrated loudness lands within 0.05 LU of target.
    static func landLoudness(_ work: [[Double]], fs: Double, target: Double,
                             ceilingDbtp: Double, clipDriveDb: Double) -> [[Double]] {
        let frames = work.first?.count ?? 0
        guard frames > 0 else { return work }
        var clipper = SoftClipper(driveDb: clipDriveDb, ceilingDb: ceilingDbtp + 0.5)
        let pre = Loudness.integratedLufs(buffer: AudioBuffer(channels: work, sampleRate: fs))
        guard pre > -70 else { return work }
        var trimDb = target - pre
        var out = work
        for _ in 0..<4 {
            out = work
            var g = pow(10, trimDb / 20)
            for c in out.indices { vDSP_vsmulD(out[c], 1, &g, &out[c], 1, vDSP_Length(frames)) }
            if !clipper.bypassed {
                for c in out.indices { for i in 0..<frames { out[c][i] = clipper.process(out[c][i]) } }
            }
            MasteringEngine.TruePeakLimiter.limit(&out, fs: fs, thresholdDb: ceilingDbtp)
            let measured = Loudness.integratedLufs(buffer: AudioBuffer(channels: out, sampleRate: fs))
            let residual = target - measured
            if abs(residual) < 0.05 { break }
            trimDb += residual
        }
        return out
    }

    private func scale(_ work: inout [[Double]], db: Double) {
        var g = pow(10, db / 20)
        for c in work.indices { vDSP_vsmulD(work[c], 1, &g, &work[c], 1, vDSP_Length(work[c].count)) }
    }

    /// The channel with the higher absolute peak (true-peak report).
    private static func peakChannel(_ chs: [[Double]]) -> [Double] {
        chs.max(by: { ($0.map(abs).max() ?? 0) < ($1.map(abs).max() ?? 0) }) ?? []
    }
}
