import Foundation
import AVFoundation

// MARK: - Output format (user pick)

enum OutputFormat: String, CaseIterable {
    case wav, mp3
    var fileExtension: String { rawValue }
    var label: String { rawValue }
}

enum ExportError: LocalizedError {
    case encoderMissing
    case encoderFailed(String)
    var errorDescription: String? {
        switch self {
        case .encoderMissing:
            return "MP3 export needs the LAME encoder (brew install lame) — or pick WAV."
        case .encoderFailed(let why):
            return "MP3 encode failed: \(why)"
        }
    }
}

enum Exporter {
    /// WAV: 24-bit PCM at the processing rate.
    /// MP3: 16-bit TPDF-dithered intermediate → LAME 320 kbps CBR, highest
    /// quality algorithm, 44.1/48 kHz. The master already sits at −1 dBTP,
    /// which leaves the headroom lossy encoding needs.
    static func write(_ buffer: AudioBuffer, format: OutputFormat, to url: URL) throws {
        switch format {
        case .wav:
            try WavWriter.write(channels: buffer.channels, sampleRate: buffer.sampleRate, to: url, bitDepth: 24)
        case .mp3:
            guard let lame = lamePath() else { throw ExportError.encoderMissing }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("resonance-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var src = buffer
            if src.sampleRate > 48_000 { src = try Resampler.resample(src, to: 48_000) }
            try WavWriter.write(channels: src.channels, sampleRate: src.sampleRate, to: tmp, bitDepth: 16)
            try? FileManager.default.removeItem(at: url)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: lame)
            p.arguments = ["--quiet", "-b", "320", "--cbr", "-q", "0", "--noreplaygain",
                           "--tt", url.deletingPathExtension().lastPathComponent,
                           tmp.path, url.path]
            let err = Pipe()
            p.standardError = err
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw ExportError.encoderFailed(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)
            }
        }
    }

    /// Bundled encoder first, then the usual Homebrew/MacPorts locations.
    static func lamePath() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("lame").path { candidates.append(res) }
        candidates += ["/opt/homebrew/bin/lame", "/usr/local/bin/lame", "/opt/local/bin/lame"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - High-quality sample-rate conversion

enum Resampler {
    /// Apple's mastering-grade SRC (AVAudioConverter, max quality).
    static func resample(_ buf: AudioBuffer, to target: Double) throws -> AudioBuffer {
        guard abs(buf.sampleRate - target) > 0.5, buf.frameCount > 0 else { return buf }
        let ch = AVAudioChannelCount(buf.channelCount)
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.sampleRate, channels: ch, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: ch, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(buf.frameCount))
        else { throw AudioLoaderError.unreadable("resampler setup failed") }
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        inBuf.frameLength = AVAudioFrameCount(buf.frameCount)
        for c in 0..<buf.channelCount {
            let dst = inBuf.floatChannelData![c]
            for i in 0..<buf.frameCount { dst[i] = Float(buf.channels[c][i]) }
        }

        let expected = Int((Double(buf.frameCount) * target / buf.sampleRate).rounded())
        var out = [[Double]](repeating: [], count: buf.channelCount)
        for c in out.indices { out[c].reserveCapacity(expected) }
        var fed = false
        let chunk: AVAudioFrameCount = 1 << 16
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunk) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true
                st.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            let n = Int(outBuf.frameLength)
            for c in out.indices {
                let p = outBuf.floatChannelData![c]
                for i in 0..<n { out[c].append(Double(p[i])) }
            }
            if status == .endOfStream || status == .error || (n == 0 && fed) { break }
        }
        // Exact length: pad/trim to the ideal frame count.
        for c in out.indices {
            if out[c].count > expected { out[c].removeLast(out[c].count - expected) }
            else if out[c].count < expected { out[c] += [Double](repeating: 0, count: expected - out[c].count) }
        }
        return AudioBuffer(channels: out, sampleRate: target)
    }
}
