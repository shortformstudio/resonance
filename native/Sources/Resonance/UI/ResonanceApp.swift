import SwiftUI

enum Theme {
    static let bg = Color(red: 0x05 / 255.0, green: 0x07 / 255.0, blue: 0x0A / 255.0)
    static let accent = Color(red: 0xD4 / 255.0, green: 0xAF / 255.0, blue: 0x37 / 255.0)
    static let accentDim = accent.opacity(0.3)
    static let glassBg = Color.white.opacity(0.02)
    static let glassBorder = Color.white.opacity(0.08)
    static let textPrimary = Color(red: 0xF0 / 255.0, green: 0xF0 / 255.0, blue: 0xF0 / 255.0)
    static let textSecondary = Color.white.opacity(0.4)
    static let good = Color(red: 0x4A / 255.0, green: 0xDE / 255.0, blue: 0x80 / 255.0)
    static let caution = Color(red: 0xFB / 255.0, green: 0xBF / 255.0, blue: 0x24 / 255.0)
    static let danger = Color(red: 0xF8 / 255.0, green: 0x71 / 255.0, blue: 0x71 / 255.0)
    static let redline = Color(red: 0xCC / 255.0, green: 0, blue: 0)
}

struct Glass: ViewModifier {
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .background(Theme.glassBg)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.glassBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

extension View {
    func glass(radius: CGFloat = 10) -> some View { modifier(Glass(radius: radius)) }
}

@main
struct ResonanceApp: App {
    @StateObject private var state = AppState()

    init() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "analyze" {
            let url = URL(fileURLWithPath: args[2])
            do {
                let engine = try AnalysisEngine(url: url)
                let r = engine.runFullAnalysis()
                let m = r.metrics
                let json: [String: Any] = [
                    "title": r.title, "format": r.format, "duration": r.duration,
                    "metrics": [
                        "integrated_lufs": m.integratedLufs, "true_peak_db": m.truePeakDb,
                        "spectral_slope": m.spectralSlope, "r_squared": m.rSquared,
                        "correlation": m.correlation, "stereo_width": m.stereoWidth,
                        "mud_center_hz": m.mudCenterHz, "mud_prominence_db": m.mudProminenceDb
                    ],
                    "cohesion_score": r.cohesionScore, "status": r.status
                ]
                let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                print(String(data: data, encoding: .utf8)!)
                exit(0)
            } catch {
                print("{\"error\": \"\(error.localizedDescription)\"}")
                exit(1)
            }
        }
        if args.count >= 3, args[1] == "master" {
            let url = URL(fileURLWithPath: args[2])
            do {
                let engine = try AnalysisEngine(url: url)
                let analysis = engine.runFullAnalysis()
                switch AppState.runMaster(input: url, metrics: analysis.metrics) {
                case .success(let m):
                    print("{\"success\": true, \"output_path\": \"\(m.outputPath.path)\", \"ab_sample_path\": \"\(m.abSamplePath?.path ?? "")\", \"video_path\": \"\(m.videoPath?.path ?? "")\"}")
                    exit(0)
                case .failure(let error):
                    print("{\"error\": \"\(error.localizedDescription)\"}")
                    exit(1)
                }
            } catch {
                print("{\"error\": \"\(error.localizedDescription)\"}")
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1100, minHeight: 780)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 850)
    }
}
