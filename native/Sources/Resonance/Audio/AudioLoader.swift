import Foundation
import AVFoundation

/// Decoded audio held as deinterleaved Float64 channel arrays at native sample rate.
struct AudioBuffer {
    var channels: [[Double]]
    var sampleRate: Double

    var frameCount: Int { channels.first?.count ?? 0 }
    var channelCount: Int { channels.count }
    var isStereo: Bool { channels.count > 1 }

    var mono: [Double] {
        guard channels.count > 1 else { return channels.first ?? [] }
        let n = frameCount
        var out = [Double](repeating: 0, count: n)
        for ch in channels {
            for i in 0..<n { out[i] += ch[i] }
        }
        let scale = 1.0 / Double(channels.count)
        for i in 0..<n { out[i] *= scale }
        return out
    }
}

enum AudioLoaderError: LocalizedError {
    case unreadable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "Audio decode failed: \(why)"
        case .empty: return "Audio file contains no frames."
        }
    }
}

enum AudioLoader {
    /// Decodes any CoreAudio-supported format (wav, aiff, mp3, m4a, flac, caf)
    /// into deinterleaved Float64 arrays via AVAudioFile. Movie files route
    /// through VideoAudio, which lifts the audio track into the same shape.
    static func load(url: URL) throws -> AudioBuffer {
        if VideoAudio.isVideo(url) {
            return try VideoAudio.extractAudio(url: url)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioLoaderError.unreadable(error.localizedDescription)
        }

        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { throw AudioLoaderError.empty }

        let channelCount = Int(format.channelCount)
        var channels = [[Double]](repeating: [], count: channelCount)
        for c in 0..<channelCount { channels[c].reserveCapacity(Int(totalFrames)) }

        let chunkFrames: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioLoaderError.unreadable("buffer allocation failed")
        }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let floatData = buffer.floatChannelData else { break }
            for c in 0..<channelCount {
                let ptr = floatData[c]
                for i in 0..<n { channels[c].append(Double(ptr[i])) }
            }
        }

        guard channels.first?.isEmpty == false else { throw AudioLoaderError.empty }
        return AudioBuffer(channels: channels, sampleRate: format.sampleRate)
    }
}
