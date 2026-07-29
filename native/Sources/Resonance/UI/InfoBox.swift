import SwiftUI

struct HoverInfo: Equatable {
    var title: String
    var text: String
}

/// The reference copy for every element and mastering concept in the app.
/// Written for the info box: plain language, what it is + how it shapes the sound.
enum Info {
    static let dropZone = HoverInfo(
        title: "audio intake",
        text: "Load audio here. One file gets a full read and a tailored master. Several files start a batch where every track gets its own custom treatment.")

    static let loudness = HoverInfo(
        title: "loudness (lufs)",
        text: "How loud the track feels to human ears, averaged over the whole song. Streaming services level everything to about -14 LUFS, so mastering to that target keeps your dynamics alive and your level competitive.")

    static let spectral = HoverInfo(
        title: "spectral slope",
        text: "How energy tilts from bass to treble. A slope near 1.3 mirrors pink noise — the balance our ears hear as natural and professional. Higher values lean warm and dark; lower values lean bright and thin.")

    static let width = HoverInfo(
        title: "stereo width (correlation)",
        text: "How the left and right channels relate. +1.0 means both sides move together — perfectly mono-solid. Lower values mean a wider, more spacious image. Above 0.6 the mix stays solid on phones and club systems that sum to mono.")

    static let truePeak = HoverInfo(
        title: "true peak",
        text: "The real analog peak between digital samples. Encoders like MP3 and AAC push peaks slightly higher, so a -1.0 dB ceiling keeps the streamed version clean and click-free.")

    static let subSonic = HoverInfo(
        title: "sub-sonic control",
        text: "A high-pass filter that clears rumble below 30–35 Hz — energy most speakers can barely reproduce. Clearing it frees headroom so the bass you can hear hits harder and the limiter works on music instead of rumble.")

    static let organicHeat = HoverInfo(
        title: "organic heat",
        text: "Gentle analog-style saturation with anti-aliased math (ADAA), so the added harmonics stay pure at any sample rate. The sub band passes through clean — warmth lands on the body of the mix while the low end keeps its punch.")

    static let spectralBalancing = HoverInfo(
        title: "spectral balancing",
        text: "Adaptive EQ tuned to this track's read. The engine locates the actual low-mid buildup in your spectrum (200–600 Hz) and dips exactly there. Bright mixes get body around 200 Hz. Every master gets an 'air' shelf at 12 kHz for that expensive sheen.")

    static let spatialWidth = HoverInfo(
        title: "spatial width",
        text: "Pure level-based mid/side control. Healthy tracks get a gentle lift of side information above 120 Hz; phase-risky tracks get their sub folded to mono. Level moves keep every phase relationship intact — wide on headphones, solid on a club system.")

    static let programGlue = HoverInfo(
        title: "program glue",
        text: "A slow, stereo-linked compressor (1.2–1.5:1, soft knee) reading RMS energy — the loudness your ear tracks. One gain moves both channels together, so the image holds still while the song breathes as one finished record.")

    static let finalOffset = HoverInfo(
        title: "final offset",
        text: "A closed loop: the engine renders, measures its own output, trims, and measures again until the track lands exactly on -14 LUFS. The ceiling is a true-peak limiter with 4x oversampled detection and 2 ms of lookahead — it sees peaks between the samples and ducks before they arrive, so the master survives MP3/AAC encoding untouched.")

    static let statusLog = HoverInfo(
        title: "system status",
        text: "A running log of every step the engine takes with your audio, timestamped.")

    static let history = HoverInfo(
        title: "session history",
        text: "Your last five masters. Click one to reveal the finished file in Finder.")

    static let chat = HoverInfo(
        title: "mastering buddy",
        text: "An honest read of your track in plain language — what the meters say, what it means musically, and the plan the engine will run.")

    static let waveform = HoverInfo(
        title: "waveform",
        text: "The track's peaks across time. Gold bars are healthy level. Red bars mark peaks grazing digital clipping — spots the limiter will protect.")

    static let masterButton = HoverInfo(
        title: "master this track",
        text: "Prints the master to Documents/Sound, places an untouched ORIGINAL_REFERENCE beside it, and builds a 30-second A/B clip that flips between before and after every 5 seconds.")

    static let batchMasterButton = HoverInfo(
        title: "master all",
        text: "Masters every analyzed track in the queue, one by one, each with a chain tailored to its own read. Loud tracks get eased off; dark tracks get lifted.")

    static let batchQueue = HoverInfo(
        title: "batch queue",
        text: "Every loaded track with its own analysis and status. Tap a track to see its read; tap a finished one to reveal its master in Finder.")

    static let dnaAudit = HoverInfo(
        title: "signal dna audit",
        text: "The track's measured fingerprint — loudness, tonal tilt, and stereo health — with the engineer's comment on each.")

    static let compensationPlan = HoverInfo(
        title: "tandem compensation plan",
        text: "The exact processing chain this track will get, stage by stage, with every setting chosen from the analysis. Hover each stage to learn what it does.")

    static let library = HoverInfo(
        title: "master library",
        text: "Every master you've printed, paired with its untouched original. Click a track to play it. Rows marked A/B carry both versions, ready to flip between.")

    static let abFlip = HoverInfo(
        title: "loudness-matched a/b",
        text: "Flips between master and original at the exact same moment (press F). Ears vote for whichever is louder, so the louder file is turned down to equal perceived loudness — what you hear flipping is pure quality: tone, width, glue. The pro way to judge a master.")

    static let modePicker = HoverInfo(
        title: "mastering engine",
        text: "Choose which mastering chain to run before printing. Each engine has a distinct sonic character — try different ones and A/B the results to find what suits the track.")

    static let modeResonanceV2 = HoverInfo(
        title: "resonance v2",
        text: "The current full-featured chain: adaptive sub-sonic HPF, M/S hygiene with phase-safe width expansion, ADAA anti-aliased saturation (sub band stays clean), spectral balancing with detected mud cut and dynamic air/body shelves, stereo-linked RMS glue compression, closed-loop LUFS landing, and a 4x-oversampled true-peak brickwall limiter. Broad, warm, and phase-coherent — the workhorse.")

    static let modeClear = HoverInfo(
        title: "clear · acoustic clarity engine",
        text: "Designed for acoustic material that needs unmasking, not loudness. A 40Hz 24dB/oct Butterworth HPF clears sub-rumble. A low-shelf at 180Hz tames boxy room resonance. A wide bell at 450Hz unmasks transients and detail. A 12kHz air shelf restores felt presence. A transparent 1.15:1 compressor with slow 60ms attack levels dynamics without dulling attacks. Finishes with the same true-peak limiter for safe output.")

    static let modeV1 = HoverInfo(
        title: "unified hybrid v1 · original alpha",
        text: "The original engine from the June 2025 alpha release. Adaptive HPF, gentle broadband saturation (raw tanh, no ADAA), spectral balancing with mud cut and air/body shelves, mono-sub fold for phase-risky material, single-band RMS glue compression, and a simple gain trim into the true-peak limiter. Warm and straightforward — no M/S expansion, no ADAA stages, no closed-loop re-measurement. A gentler, simpler sound.")
}

// MARK: - Hover plumbing

struct InfoHover: ViewModifier {
    @EnvironmentObject var state: AppState
    let info: HoverInfo

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                state.hoverInfo = info
            } else if state.hoverInfo == info {
                state.hoverInfo = nil
            }
        }
    }
}

extension View {
    func infoHover(_ info: HoverInfo) -> some View { modifier(InfoHover(info: info)) }
}

// MARK: - The box itself

struct InfoBoxView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let info = state.hoverInfo {
                Text(info.title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Text(info.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(10)
        .frame(height: 118)
        .glass()
        .animation(.easeOut(duration: 0.12), value: state.hoverInfo)
    }
}
