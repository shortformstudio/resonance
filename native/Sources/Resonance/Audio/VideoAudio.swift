import Foundation
import AVFoundation

/// Video intake: pulls the audio track out of a movie for analysis/mastering,
/// then rebuilds a movie whose picture is untouched and whose sound is the
/// finished master.
enum VideoAudioError: LocalizedError {
    case noAudioTrack
    case noVideoTrack
    case readerFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "The video contains no audio track."
        case .noVideoTrack: return "The file contains no video track."
        case .readerFailed(let why): return "Video audio decode failed: \(why)"
        case .exportFailed(let why): return "Video export failed: \(why)"
        }
    }
}

enum VideoAudio {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Decodes the first audio track of a movie into deinterleaved Float64
    /// arrays at native sample rate — the same shape AudioLoader produces.
    static func extractAudio(url: URL) throws -> AudioBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw VideoAudioError.noAudioTrack
        }

        var sampleRate = 44100.0
        var channelCount = 2
        if let desc = track.formatDescriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMAudioFormatDescription)?.pointee {
            if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
            if asbd.mChannelsPerFrame > 0 { channelCount = Int(asbd.mChannelsPerFrame) }
        }
        channelCount = max(1, min(channelCount, 2))

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw VideoAudioError.readerFailed(error.localizedDescription) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoAudioError.readerFailed("reader rejected track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw VideoAudioError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }

        var channels = [[Double]](repeating: [], count: channelCount)
        var scratch = [Float]()

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            let floatCount = byteCount / MemoryLayout<Float>.size
            if floatCount == 0 { continue }
            if scratch.count < floatCount { scratch = [Float](repeating: 0, count: floatCount) }
            scratch.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                               destination: raw.baseAddress!)
            }
            let frames = floatCount / channelCount
            for c in 0..<channelCount {
                channels[c].reserveCapacity(channels[c].count + frames)
                var i = c
                for _ in 0..<frames {
                    channels[c].append(Double(scratch[i]))
                    i += channelCount
                }
            }
        }

        if reader.status == .failed {
            throw VideoAudioError.readerFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard channels.first?.isEmpty == false else { throw VideoAudioError.noAudioTrack }
        return AudioBuffer(channels: channels, sampleRate: sampleRate)
    }

    /// Rebuilds the movie with the mastered audio: original video samples pass
    /// through untouched, the mastered WAV becomes the sole audio track.
    /// Output is a QuickTime .mov (PCM audio stays lossless in this container).
    static func muxMasteredAudio(video videoURL: URL, masteredAudio audioURL: URL, output outputURL: URL) throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        let videoTracks = videoAsset.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoAudioError.noVideoTrack }

        let comp = AVMutableComposition()
        let videoRange = CMTimeRange(start: .zero, duration: videoAsset.duration)

        for vTrack in videoTracks {
            guard let cTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try cTrack.insertTimeRange(videoRange, of: vTrack, at: .zero)
            cTrack.preferredTransform = vTrack.preferredTransform
        }

        guard let aTrack = audioAsset.tracks(withMediaType: .audio).first,
              let cAudio = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoAudioError.exportFailed("mastered audio track unavailable")
        }
        let audioRange = CMTimeRange(start: .zero, duration: min(audioAsset.duration, videoAsset.duration))
        try cAudio.insertTimeRange(audioRange, of: aTrack, at: .zero)

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoAudioError.exportFailed("export session unavailable")
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mov

        let sem = DispatchSemaphore(value: 0)
        export.exportAsynchronously { sem.signal() }
        sem.wait()

        guard export.status == .completed else {
            throw VideoAudioError.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
    }
}
