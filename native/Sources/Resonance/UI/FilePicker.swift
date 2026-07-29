import SwiftUI
import UniformTypeIdentifiers

/// Shared, pre-warmed open panel. The panel and its content-type lookups are
/// built once at launch, so the click handler only reveals it. Warming at
/// startup also absorbs the cold-start of macOS's out-of-process panel service.
@MainActor
final class FilePicker {
    static let shared = FilePicker()

    private lazy var panel: NSOpenPanel = {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.title = "Choose Audio or Video"
        p.message = "Pick one track or video for a full read, or several for a batch."
        p.prompt = "Analyze"
        p.allowedContentTypes = Self.audioTypes
        return p
    }()

    private static let audioTypes: [UTType] = {
        var types: [UTType] = [.mp3, .wav, .mpeg4Audio, .aiff,
                               .mpeg4Movie, .quickTimeMovie, .movie]
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let m4v = UTType(filenameExtension: "m4v") { types.append(m4v) }
        return types
    }()

    /// Touch the lazy panel so all setup cost lands at launch.
    func warm() { _ = panel }

    func present(completion: @escaping ([URL]) -> Void) {
        let p = panel
        p.begin { response in
            completion(response == .OK ? p.urls : [])
        }
    }
}
