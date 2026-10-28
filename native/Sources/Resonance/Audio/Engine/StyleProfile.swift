import Foundation

/// Everything that differs between the three mastering styles lives here.
/// The chain itself is identical for every style; only these numbers move.
/// Thresholds are never absolute: dynamics stages place them on percentiles
/// of the track's own (staged) loudness distribution, so the same profile
/// behaves the same on a quiet demo and a hot mix.
struct StyleProfile {
    // Delivery
    var targetLufs: Double
    var ceilingDbtp: Double = -1.0

    // Foundation
    var highPassHz: Double

    // Adaptive tonal match
    var eqStrength: Double        // 0…1 — share of the distance to the reference curve we close
    var eqMaxDb: Double           // per-band clamp
    var curveTilt: [Double]       // extra dB per reference band (style voicing)

    // Detail / tamer
    var transientAttack: Double
    var suppressDepth: Double

    // Multiband (stereo-linked)
    var mbRatio: Double
    var mbPercentile: Double      // threshold sits at this percentile of each band's level
    var mbOffsetDb: Double
    var mbAttackMs: Double
    var mbReleaseMs: Double

    // Harmonics
    var saturationDb: Double      // 0 bypasses

    // Glue (stereo-linked RMS)
    var glueRatio: Double
    var gluePercentile: Double
    var glueOffsetDb: Double
    var glueAttackMs: Double
    var glueReleaseMs: Double

    // Stereo
    var widthDb: Double           // side lift above 300 Hz
    var monoBassHz: Double        // side high-pass

    // Loudness staging ahead of the brickwall
    var clipDriveDb: Double

    static func forMode(_ mode: MasteringMode) -> StyleProfile {
        switch mode {
        case .core:
            return StyleProfile(targetLufs: -14, highPassHz: 28,
                                eqStrength: 0.5, eqMaxDb: 3.0,
                                curveTilt: [0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5],
                                transientAttack: 0.15, suppressDepth: 0.5,
                                mbRatio: 1.8, mbPercentile: 0.80, mbOffsetDb: 2, mbAttackMs: 25, mbReleaseMs: 180,
                                saturationDb: 1.5,
                                glueRatio: 1.8, gluePercentile: 0.70, glueOffsetDb: 0, glueAttackMs: 30, glueReleaseMs: 160,
                                widthDb: 1.0, monoBassHz: 120,
                                clipDriveDb: 1.0)
        case .pure:
            return StyleProfile(targetLufs: -16, highPassHz: 22,
                                eqStrength: 0.35, eqMaxDb: 2.0,
                                curveTilt: [-1, -0.5, 0, 0, 0, 0, 0, 0.3, 0.6, 0.6],
                                transientAttack: 0.1, suppressDepth: 0.4,
                                mbRatio: 1.3, mbPercentile: 0.90, mbOffsetDb: 3, mbAttackMs: 40, mbReleaseMs: 250,
                                saturationDb: 0,
                                glueRatio: 1.3, gluePercentile: 0.85, glueOffsetDb: 2, glueAttackMs: 50, glueReleaseMs: 250,
                                widthDb: 0, monoBassHz: 80,
                                clipDriveDb: 0)
        case .club:
            return StyleProfile(targetLufs: -9, highPassHz: 30,
                                eqStrength: 0.6, eqMaxDb: 4.0,
                                curveTilt: [1.5, 1.5, 0.5, 0, -0.5, 0, 0, 0, 0.5, 0.5],
                                transientAttack: 0.25, suppressDepth: 0.6,
                                mbRatio: 2.5, mbPercentile: 0.70, mbOffsetDb: 0, mbAttackMs: 15, mbReleaseMs: 120,
                                saturationDb: 2.5,
                                glueRatio: 2.5, gluePercentile: 0.60, glueOffsetDb: -1, glueAttackMs: 20, glueReleaseMs: 120,
                                widthDb: 1.5, monoBassHz: 150,
                                clipDriveDb: 2.5)
        }
    }
}

/// Long-term average spectrum of commercially mastered music, octave-band
/// energy as a relative shape (after Pestana et al., AES 2013) — the absolute
/// offset is fitted to each track's own midrange at scan time. Pink noise is
/// flat in octave bands, so this curve is the familiar gentle bass plateau
/// with a steady top-end roll-off.
enum ReferenceCurve {
    static let centers: [Double] = [40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 16000]
    static let levelsDb: [Double] = [-1, 1, 1, 0, -1.5, -4, -7, -10.5, -15, -22]
}
