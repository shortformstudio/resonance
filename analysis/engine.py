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
        print("PROGRESS: 10", flush=True)
        
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
                print("PROGRESS: 25", flush=True)
                data, rate = sf.read(tmp_path)
                os.remove(tmp_path)
                return data, rate
            except Exception as e:
                print(f"Symphonia decoding failed, falling back: {e}")

        # 2. Try librosa (which uses soundfile/audioread/ffmpeg)
        try:
            data, rate = librosa.load(file_path, sr=None, mono=False)
            print("PROGRESS: 25", flush=True)
            return data, rate
        except Exception as e:
            print(f"Librosa loading failed: {e}")

        # 3. Last resort: Direct FFmpeg call to WAV
        try:
            import tempfile
            import subprocess
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                tmp_path = tmp.name
            
            subprocess.run(["ffmpeg", "-i", file_path, "-y", tmp_path], check=True, capture_output=True)
            print("PROGRESS: 25", flush=True)
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
        print("PROGRESS: 35", flush=True)
        loudness = self.measure_loudness()
        print("PROGRESS: 50", flush=True)
        
        spectral = self.analyze_spectral_slope()
        print("PROGRESS: 65", flush=True)
        
        stereo = self.analyze_stereo_field()
        print("PROGRESS: 75", flush=True)
        
        waveform_data = self.generate_waveform_data()
        print("PROGRESS: 90", flush=True)
        
        # Calculate duration
        duration_sec = len(self.mono_data) / self.rate
        minutes = int(duration_sec // 60)
        seconds = int(duration_sec % 60)
        duration_str = f"{minutes}:{seconds:02d}"
        
        # Get format from extension
        ext = os.path.splitext(self.file_path)[1][1:].upper()
        
        score = self.calculate_cohesion_score(loudness, spectral, stereo)
        suggestions_data = self.generate_suggestions(loudness, spectral, stereo)
        
        print("PROGRESS: 100", flush=True)
        
        report = {
            "title": os.path.basename(self.file_path),
            "format": ext,
            "duration": duration_str,
            "metrics": {
                **loudness,
                **spectral,
                **stereo
            },
            "cohesion_score": score,
            "status": self.get_status(score),
            "waveform": waveform_data,
            "suggestions": suggestions_data["suggestions"],
            "perspective": suggestions_data["perspective"]
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

    def generate_suggestions(self, loudness, spectral, stereo):
        """Generates conversationally grounded engineering opinions and a cohesive narrative."""
        suggestions = []
        lufs = loudness["integrated_lufs"]
        slope = spectral["spectral_slope"]
        corr = stereo["correlation"]
        tp = loudness["true_peak_db"]

        # 1. Perspective Construction (The Cohesive Narrative)
        perspective = "Looking at this track, "
        if slope > 1.4: perspective += "we're leaning into a thick, dark warmth, but it's bordering on 'muddy'—we need to lift the veil and unmask the mid-highs. "
        elif slope < 1.1: perspective += "it has a striking, surgical high-end brilliance, but it lacks the 'chest weight' to feel truly grounded. "
        else: perspective += "it's sitting in a very professional spectral pocket. "

        if lufs < -16: perspective += "The signal is breathing deep with plenty of headroom, making it a prime candidate for a serious thermal push into the console stage. "
        elif lufs > -9: perspective += "We're pushing the absolute limits of density here; I'm worried we're trading micro-dynamics for raw volume. "
        else: perspective += "Loudness levels are targeted perfectly for contemporary streaming standards. "

        if corr < 0.6: perspective += "However, keep an eye on the side-signals—the phase correlation is dipping, which could cause center-image collapse. "
        else: perspective += "The stereo integrity is solid, maintaining a focused and wide image."

        # 2. Detailed Suggestions
        if lufs < -16:
            suggestions.append({"title": "ANALOG THERMAL PUSH", "text": "Signal is breathing with excessive headroom. Suggesting a boost into a soft-clipper to introduce even-order harmonics."})
        elif lufs > -9:
            suggestions.append({"title": "SPECTRAL DYNAMICS CAUTION", "text": "Loudness is in the 'war zone'. Recommend backing off the final limiter to let the transients breathe."})

        if slope > 1.5:
            suggestions.append({"title": "MUD DE-MASKING", "text": "Heavy accumulation in low-mids (300-500Hz). A surgical 2dB dip with a wide Q here will act like a lens flare reduction."})
        elif slope < 1.1:
            suggestions.append({"title": "HF EXCITATION", "text": "Track feels 'dark'. A high-shelf at 12kHz would restore that expensive sheen without sounding brittle."})

        if corr < 0.5:
            suggestions.append({"title": "CORRELATION ALIGNMENT", "text": "Phase correlation is dipping. Tighten sub-200Hz region to mono and check for excessive widening effects."})
        
        if tp > -0.5:
            suggestions.append({"title": "INTER-SAMPLE SAFETY", "text": "True peaks are clipping reconstruction filters. Suggesting a ceiling of -1.0dB for codec integrity."})

        return {"suggestions": suggestions, "perspective": perspective}

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
