import os
import sys
import json
import numpy as np
import librosa
import soundfile as sf
import pyloudnorm as ln
from scipy import signal, stats

class AudioAnalysisEngine:
    def __init__(self, file_path):
        self.file_path = file_path
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"Audio file not found: {file_path}")
        
        # Load audio with robust format support (Symphonia > librosa > FFmpeg)
        self.data, self.rate = self._load_audio(file_path)
        
        # Ensure consistency in shape (samples, channels)
        if len(self.data.shape) > 1:
            self.is_stereo = True
            # if we used mono=False, librosa returns (channels, samples)
            # but soundfile/symphonia-wav return (samples, channels)
            if self.data.shape[0] < self.data.shape[1]: # Likely (channels, samples)
                self.data = self.data.T
            self.mono_data = librosa.to_mono(self.data.T)
        else:
            self.is_stereo = False
            self.mono_data = self.data

    def _load_audio(self, file_path):
        """Robustly loads audio using Symphonia (preferred), librosa, or FFmpeg fallback."""
        print("PROGRESS: 10", file=sys.stderr, flush=True)
        
        # 1. Try Symphonia (Google's preferred Rust decoder)
        # Assuming binary is in project_root/bin/symphonia-decode
        symphonia_bin = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "symphonia-decode")
        if os.path.exists(symphonia_bin):
            try:
                import tempfile
                import subprocess
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                    tmp_path = tmp.name
                
                # Use Symphonia to decode to a temporary WAV
                subprocess.run([symphonia_bin, file_path, tmp_path], check=True, capture_output=True)
                print("PROGRESS: 25", file=sys.stderr, flush=True)
                data, rate = sf.read(tmp_path)
                os.remove(tmp_path)
                return data, rate
            except Exception as e:
                print(f"Symphonia decoding failed, falling back: {e}", file=sys.stderr)

        # 2. Try librosa (which uses soundfile/audioread/ffmpeg)
        try:
            data, rate = librosa.load(file_path, sr=None, mono=False)
            print("PROGRESS: 25", file=sys.stderr, flush=True)
            return data, rate
        except Exception as e:
            print(f"Librosa loading failed: {e}", file=sys.stderr)

        # 3. Last resort: Direct FFmpeg call to WAV
        try:
            import tempfile
            import subprocess
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
            
            subprocess.run(["ffmpeg", "-i", file_path, "-y", tmp_path], check=True, capture_output=True)
            print("PROGRESS: 25", file=sys.stderr, flush=True)
            data, rate = sf.read(tmp_path)
            os.remove(tmp_path)
            return data, rate
        except Exception as e:
            raise RuntimeError(f"All audio decoding attempts failed for {file_path}: {e}")

    def measure_loudness(self):
        """Measures Integrated LUFS and LRA using pyloudnorm."""
        meter = ln.Meter(self.rate)
        integrated_lufs = meter.integrated_loudness(self.data)
        
        # Approximate LRA (Loudness Range)
        # Note: pyloudnorm doesn't have a direct LRA method, but we can 
        # approximate by measuring short-term loudness blocks.
        # Professional masters usually have LRA 3-7.
        return {
            "integrated_lufs": round(float(integrated_lufs), 2),
            "true_peak_db": self.measure_true_peak()
        }

    def measure_true_peak(self):
        """Approximates True Peak by 4x oversampling."""
        # Standard ITU-R BS.1770-4 suggests at least 4x oversampling for 44.1kHz
        # We use resample_poly for efficient upsampling
        upsampled = signal.resample_poly(self.mono_data, 4, 1)
        peak_linear = np.max(np.abs(upsampled))
        peak_db = 20 * np.log10(peak_linear) if peak_linear > 0 else -144.0
        return round(float(peak_db), 2)

    def analyze_spectral_slope(self):
        """Calculates the spectral slope (alpha) where 1.0 is ideal Pink Noise (-3dB/octave)."""
        # Estimate PSD using Welch's method
        freqs, psd = signal.welch(self.mono_data, self.rate, nperseg=8192)
        
        # Filter for audible range (20Hz - 20kHz)
        mask = (freqs >= 20) & (freqs <= 20000)
        if not np.any(mask):
            return {"spectral_slope": 0.0, "r_squared": 0.0}
            
        x = np.log10(freqs[mask])
        y = np.log10(psd[mask])
        
        # Linear Regression: log(P) = -alpha * log(f) + C
        slope, intercept, r_value, p_value, std_err = stats.linregress(x, y)
        
        # alpha = -slope. A value of 1.0 is pink noise (-3dB/octave).
        # Modern masters often lean towards 1.2 - 1.5 (-4.5dB/octave).
        return {
            "spectral_slope": round(float(-slope), 3),
            "r_squared": round(float(r_value**2), 3)
        }

    def analyze_stereo_field(self):
        """Measures stereo correlation and width."""
        if not self.is_stereo:
            return {"correlation": 1.0, "width": 0.0}
        
        left = self.data[:, 0]
        right = self.data[:, 1]
        
        # Pearson correlation (-1 to +1)
        correlation = np.corrcoef(left, right)[0, 1]
        
        # Mid-Side analysis for width
        mid = (left + right) / 2
        side = (left - right) / 2
        
        mid_power = np.mean(mid**2)
        side_power = np.mean(side**2)
        
        width = side_power / (mid_power + 1e-10) # Simple ratio
        
        return {
            "correlation": round(float(correlation), 3),
            "stereo_width": round(float(width), 3)
        }

    def run_full_analysis(self):
        print("PROGRESS: 35", file=sys.stderr, flush=True)
        loudness = self.measure_loudness()
        print("PROGRESS: 50", file=sys.stderr, flush=True)
        
        spectral = self.analyze_spectral_slope()
        print("PROGRESS: 65", file=sys.stderr, flush=True)
        
        stereo = self.analyze_stereo_field()
        print("PROGRESS: 75", file=sys.stderr, flush=True)
        
        waveform_data = self.generate_waveform_data()
        print("PROGRESS: 90", file=sys.stderr, flush=True)
        
        # Calculate duration
        duration_sec = len(self.mono_data) / self.rate
        minutes = int(duration_sec // 60)
        seconds = int(duration_sec % 60)
        duration_str = f"{minutes}:{seconds:02d}"
        
        # Get format from extension
        ext = os.path.splitext(self.file_path)[1][1:].upper()
        
        score = self.calculate_cohesion_score(loudness, spectral, stereo)

        # Dynamics metering first — the chat read reacts to it.
        from mastering.dynamics import dynamics_report
        data2d = self.data if len(self.data.shape) > 1 else self.data[:, None]
        dyn = dynamics_report(data2d, self.rate)

        suggestions_data = self.generate_suggestions(loudness, spectral, stereo, dyn)

        print("PROGRESS: 100", file=sys.stderr, flush=True)

        report = {
            "title": os.path.basename(self.file_path),
            "format": ext,
            "duration": duration_str,
            "metrics": {
                **loudness,
                **spectral,
                **stereo,
                "lra": dyn["lra"],
                "crest_db": dyn["crest_db"],
                "section_spread_db": dyn["section_spread_db"],
            },
            "cohesion_score": score,
            "status": self.get_status(score),
            "waveform": waveform_data,
            "suggestions": suggestions_data["suggestions"],
            "perspective": suggestions_data["perspective"],
            "chat": suggestions_data.get("chat", []),
            "dynamics": dyn,
        }
        return report

    def generate_waveform_data(self, points=500):
        """Generates simplified waveform and redline data for Three.js."""
        hop_length = max(1, len(self.mono_data) // points)
        waveform, redlines = [], []
        for i in range(0, len(self.mono_data), hop_length):
            chunk = self.mono_data[i:i+hop_length]
            if len(chunk) == 0: continue
            peak = np.max(np.abs(chunk))
            waveform.append(float(peak))
            redlines.append(1 if peak > 0.99 else 0)
        return {"data": waveform[:points], "redlines": redlines[:points]}

    def generate_suggestions(self, loudness, spectral, stereo, dyn=None):
        """Conversational mastering-buddy read of the track.

        Voice: a friend who happens to be a world-class mastering engineer —
        proactive, informative, concise, and chill. Every observation teaches a
        little bit of *why* so the user levels up while the engines do the work.
        Returns a `chat` list (ordered bubbles shown above the analysis) plus the
        legacy `perspective`/`suggestions` fields for backward compatibility.
        """
        lufs = loudness["integrated_lufs"]
        slope = spectral["spectral_slope"]
        corr = stereo["correlation"]
        tp = loudness["true_peak_db"]

        chat = []  # each: {tone, title, text}

        # 1. Opening read — friendly, sets the vibe.
        chat.append({
            "tone": "greeting",
            "title": "here's what i'm hearing",
            "text": "gave your track a full listen-through with the meters up. "
                    "quick honest read below — nothing's broken, this is just how we make it shine."
        })

        # 2. Tonal balance (spectral slope) — teach the pink-noise target.
        if slope > 1.4:
            chat.append({
                "tone": "insight",
                "title": "tonal balance · a touch dark",
                "text": f"your spectral slope is {slope} — there's lovely warmth down low, but the "
                        "low-mids (250–500hz) are stacking up and fogging the detail. i'll gently "
                        "dip that so the vocals and cymbals can breathe. think of it as wiping mist off glass."
            })
        elif slope < 1.1:
            chat.append({
                "tone": "insight",
                "title": "tonal balance · bright & crisp",
                "text": f"slope's at {slope}, so you're riding a bright, detailed top end — sounds "
                        "expensive, but it's a little thin in the chest. i'll add weight around 150–250hz "
                        "so it feels grounded instead of glassy."
            })
        else:
            chat.append({
                "tone": "good",
                "title": "tonal balance · dialed",
                "text": f"slope's sitting at {slope}, right in the pro pink-noise pocket. honestly "
                        "this is where you want to live — i'll preserve it and just tighten the edges."
            })

        # 3. Loudness — teach LUFS + streaming target.
        if lufs < -16:
            chat.append({
                "tone": "insight",
                "title": "loudness · lots of headroom",
                "text": f"you're at {lufs} lufs — plenty of room before the ceiling. that's a gift: it "
                        "means i can push into gentle analog saturation for warmth and glue before we ever "
                        "hit a limiter. streaming targets around -14, so we've got a clean path up."
            })
        elif lufs > -9:
            chat.append({
                "tone": "caution",
                "title": "loudness · running hot",
                "text": f"heads up — you're at {lufs} lufs, which is loud. it'll be punchy, but we're "
                        "trading away some of the micro-dynamics that make a track feel alive. i'll ease off "
                        "the limiter a hair so the transients still hit. loud is easy; loud *and* open is the craft."
            })
        else:
            chat.append({
                "tone": "good",
                "title": "loudness · on target",
                "text": f"{lufs} lufs — basically perfect for streaming. we'll finalize right here and "
                        "keep the dynamics intact."
            })

        # 4. Stereo image — teach phase/mono-compatibility.
        if corr < 0.6:
            chat.append({
                "tone": "caution",
                "title": "stereo image · watch the phase",
                "text": f"correlation's dipping to {corr}. wide sounds great on headphones, but when a "
                        "club or phone sums to mono, low-end can cancel and thin out. i'll mono the sub "
                        "and re-focus the center so it stays big *and* solid everywhere."
            })
        else:
            chat.append({
                "tone": "good",
                "title": "stereo image · wide and solid",
                "text": f"correlation's at {corr} — your width is healthy and phase-coherent. it'll "
                        "translate cleanly from earbuds to a big system."
            })

        # 5. True-peak safety — proactive codec heads-up.
        if tp > -0.5:
            chat.append({
                "tone": "caution",
                "title": "true peaks · codec safety",
                "text": f"peaks are grazing {tp} db. once this gets encoded to mp3/aac, inter-sample "
                        "peaks can clip past 0. i'll set a -1.0 db ceiling so it survives streaming intact."
            })

        # 5b. Dynamics consistency — section spread + loudness range.
        dyn = dyn or {}
        spread = float(dyn.get("section_spread_db", 0))
        lra = float(dyn.get("lra", 0))
        if spread > 3 or lra > 9:
            chat.append({
                "tone": "insight",
                "title": "dynamics · uneven sections",
                "text": f"this one's breathing unevenly — sections swing {spread} db with a loudness range of {lra} lu. i'm riding the sections toward each other and letting the multiband glue work per-band, so the verse and chorus finish at the same weight."
            })
        else:
            chat.append({
                "tone": "good",
                "title": "dynamics · holding steady",
                "text": f"dynamics hold steady across sections ({spread} db spread, {lra} lu range) — the glue just has to polish, not rescue. transients stay intact."
            })

        # 6. Path forward — proactive recommendation of which mode to try.
        if lufs < -16 or slope > 1.4:
            rec = ("i'd start with **modern master** — it leans into harmonic density and glue, "
                   "which is exactly what this track's asking for. want a warmer, more open take, "
                   "run **acoustic clear** right after and a/b them.")
        elif corr < 0.6 or slope < 1.1:
            rec = ("i'd reach for **acoustic clear** first — it keeps things phase-coherent and airy, "
                   "which suits this material. if you want more weight and loudness, try **modern master** and compare.")
        else:
            rec = ("this one's balanced, so it's dealer's choice: **modern master** for a louder, denser "
                   "print, **acoustic clear** for a transparent finish. hit master and we'll hear it.")
        chat.append({
            "tone": "plan",
            "title": "my move",
            "text": rec + " either way, i'll print an ORIGINAL_REFERENCE next to it so you can a/b instantly."
        })

        # --- Legacy fields (kept so older UI paths still work) ---
        perspective = " ".join(b["text"] for b in chat if b["tone"] in ("insight", "good", "caution"))

        suggestions = []
        if lufs < -16:
            suggestions.append({"title": "ANALOG THERMAL PUSH", "text": "Lots of headroom — boosting into a soft-clipper for even-order harmonic warmth."})
        elif lufs > -9:
            suggestions.append({"title": "SPECTRAL DYNAMICS CAUTION", "text": "Loudness is hot — backing off the final limiter to let transients breathe."})
        if slope > 1.5:
            suggestions.append({"title": "MUD DE-MASKING", "text": "Low-mid buildup (300–500Hz) — a wide, gentle 2dB dip clears the fog."})
        elif slope < 1.1:
            suggestions.append({"title": "HF EXCITATION", "text": "Feels dark — a 12kHz high-shelf restores sheen without brittleness."})
        if corr < 0.5:
            suggestions.append({"title": "CORRELATION ALIGNMENT", "text": "Phase dipping — mono the sub-200Hz and check widening."})
        if tp > -0.5:
            suggestions.append({"title": "INTER-SAMPLE SAFETY", "text": "True peaks clipping — setting a -1.0dB ceiling for codec integrity."})

        return {"suggestions": suggestions, "perspective": perspective, "chat": chat}

    def calculate_cohesion_score(self, loudness, spectral, stereo):
        """Mathematical weighted score based on mastering standards."""
        # 1. Loudness Fit (Target -14 LUFS)
        # Penalty for being too quiet or dangerously loud
        lufs = loudness["integrated_lufs"]
        loudness_score = max(0, 100 - abs(lufs - (-14)) * 5)
        
        # 2. Spectral Balance Fit (Target slope ~1.3)
        slope = spectral["spectral_slope"]
        # Ideal range 1.0 to 1.6
        spectral_score = max(0, 100 - abs(slope - 1.3) * 100)
        
        # 3. Stereo Integrity
        corr = stereo["correlation"]
        # Penalty for phase issues (corr < 0)
        stereo_score = max(0, corr * 100) if corr > 0 else 0
        
        # 4. Technical Integrity (True Peak)
        tp = loudness["true_peak_db"]
        tp_penalty = max(0, (tp - (-1.0)) * 50) if tp > -1.0 else 0
        
        final_score = (loudness_score * 0.3) + (spectral_score * 0.4) + (stereo_score * 0.3)
        final_score = max(0, final_score - tp_penalty)
        
        return round(float(final_score), 1)

    def get_status(self, score):
        if score >= 85: return "PROFESSIONAL MASTER"
        if score >= 70: return "HIGH QUALITY MIX"
        if score >= 50: return "DEMO / ROUGH MIX"
        return "UNFINISHED / TECHNICAL ISSUES"

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 engine.py <audio_file_path>")
        sys.exit(1)
    
    try:
        engine = AudioAnalysisEngine(sys.argv[1])
        result = engine.run_full_analysis()
        print(json.dumps(result, indent=4))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
