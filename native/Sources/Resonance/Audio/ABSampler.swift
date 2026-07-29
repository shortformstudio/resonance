import Foundation

/// Builds a ~30s clip alternating BEFORE and AFTER every `segmentSeconds`,
/// pulling both from the same time region with equal-power crossfades.
/// Direct port of mastering/ab_sampler.py.
struct ABSampler {
    var segmentSeconds = 5.0
    var totalSeconds = 30.0
    var crossfadeMs = 60.0

    struct Result {
        var outputPath: URL
        var sampleRate: Double
        var channels: Int
        var totalSeconds: Double
        var segments: Int
        var order: [String]
    }

    private func matchChannels(_ a: [[Double]], _ b: [[Double]]) -> ([[Double]], [[Double]]) {
        let target = max(a.count, b.count)
        func fit(_ x: [[Double]]) -> [[Double]] {
            if x.count == target { return x }
            if x.count == 1 { return [[Double]](repeating: x[0], count: target) }
            let n = x[0].count
            var mono = [Double](repeating: 0, count: n)
            for ch in x { for i in 0..<n { mono[i] += ch[i] } }
            let scale = 1.0 / Double(x.count)
            for i in 0..<n { mono[i] *= scale }
            return [[Double]](repeating: mono, count: target)
        }
        return (fit(a), fit(b))
    }

    private func takeSegment(_ src: [[Double]], start: Int, length: Int) -> [[Double]] {
        let total = src[0].count
        guard total > 0 else { return src.map { _ in [Double](repeating: 0, count: length) } }
        return src.map { ch in
            (0..<length).map { ch[(start + $0) % total] }
        }
    }

    private func equalPowerFades(_ segment: inout [[Double]], fadeLen: Int) {
        let n = segment[0].count
        guard fadeLen > 0, n >= 2 * fadeLen else { return }
        for i in 0..<fadeLen {
            let t = Double(i) / Double(fadeLen - 1) * .pi / 2
            let fin = sin(t), fout = cos(t)
            for c in 0..<segment.count {
                segment[c][i] *= fin
                segment[c][n - fadeLen + i] *= fout
            }
        }
    }

    func build(beforePath: URL, afterPath: URL, outputPath: URL) throws -> Result {
        let after = try AudioLoader.load(url: afterPath)
        let rate = after.sampleRate
        var beforeBuf = try AudioLoader.load(url: beforePath)

        // Resample BEFORE to AFTER's rate when they differ (linear interp).
        if abs(beforeBuf.sampleRate - rate) > 0.5 {
            let ratio = beforeBuf.sampleRate / rate
            let newCount = Int(Double(beforeBuf.frameCount) / ratio)
            let resampled = beforeBuf.channels.map { ch -> [Double] in
                (0..<newCount).map { i in
                    let pos = Double(i) * ratio
                    let i0 = min(Int(pos), ch.count - 1)
                    let i1 = min(i0 + 1, ch.count - 1)
                    let frac = pos - pos.rounded(.down)
                    return ch[i0] * (1 - frac) + ch[i1] * frac
                }
            }
            beforeBuf = AudioBuffer(channels: resampled, sampleRate: rate)
        }

        let (before, afterCh) = matchChannels(beforeBuf.channels, after.channels)
        let channels = afterCh.count
        let segLen = Int(segmentSeconds * rate)
        let fadeLen = Int(crossfadeMs / 1000 * rate)
        let numSegments = max(1, Int((totalSeconds / segmentSeconds).rounded()))

        let usable = min(before[0].count, afterCh[0].count)
        let needed = segLen * numSegments
        let start = max(0, Int(min(Double(usable) * 0.15, Double(max(0, usable - needed)))))

        var order: [String] = []
        var pieces: [[[Double]]] = []
        for i in 0..<numSegments {
            let which = i % 2 == 0 ? "before" : "after"
            order.append(which)
            let src = which == "before" ? before : afterCh
            var segment = takeSegment(src, start: start + i * segLen, length: segLen)
            equalPowerFades(&segment, fadeLen: fadeLen)
            pieces.append(segment)
        }

        var clip = [[Double]](repeating: [], count: channels)
        for c in 0..<channels {
            clip[c].reserveCapacity(segLen * numSegments)
            for piece in pieces { clip[c].append(contentsOf: piece[c]) }
        }

        var peak = 0.0
        for ch in clip { for v in ch { peak = max(peak, abs(v)) } }
        if peak > 0.999 {
            let scale = 0.999 / peak
            for c in 0..<channels {
                for i in 0..<clip[c].count { clip[c][i] *= scale }
            }
        }

        try FileManager.default.createDirectory(at: outputPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try WavWriter.write(channels: clip, sampleRate: rate, to: outputPath, bitDepth: 16)

        return Result(outputPath: outputPath, sampleRate: rate, channels: channels,
                      totalSeconds: (Double(clip[0].count) / rate * 100).rounded() / 100,
                      segments: numSegments, order: order)
    }
}
