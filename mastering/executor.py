import os
import soundfile as sf
import numpy as np
from pedalboard import Pedalboard, Compressor, Gain, HighShelfFilter, LowShelfFilter, Limiter, PeakFilter, Distortion, HighpassFilter, Chorus
from pedalboard.io import AudioFile

class MasteringExecutor:
    """
    Unified Hybrid Mastering Engine.
    Dynamically blends Modern harmonic density with Acoustic transparency.
    1. Sub-Sonic Control
    2. Multi-Stage Saturation (Organic Heat)
    3. Adaptive Spectral Balancing (Variable Slope)
    4. Phase-Coherent Horizontal Expansion
    5. Program-Dependent Compression (The Glue)
    6. Transparent Brickwall Finalization

    Mode-aware: club lands at -8 LUFS with hotter drive; ivory/vox stay
    transparent at -14 with voicing tweaks. Unknown modes fall back to core.
    """
    MODE_TARGETS = {
        "resonance_v2": -14.0, "core": -14.0,
        "clear": -14.0, "pure": -14.0,
        "unified_hybrid_v1": -14.0, "heat": -14.0,
        "club": -8.0,
        "ivory": -14.0,
        "vox": -14.0,
    }

    def __init__(self, target_lufs=-14.0, mode="resonance_v2"):
        self.mode = mode if mode in self.MODE_TARGETS else "resonance_v2"
        # An explicit target always wins; otherwise the mode decides.
        self.target_lufs = target_lufs if target_lufs != -14.0 else self.MODE_TARGETS[self.mode]

    def apply_compensation(self, input_path, output_path, metrics):
        from .dynamics import apply_transient, apply_dynamics, soft_clip, mode_cfg
        cfg = mode_cfg(self.mode)

        # Whole-file flow: transient shaping wants the clean signal first,
        # corrective stages sit after the tonal chain, clipper ahead of the wall.
        data, sr = sf.read(input_path, dtype="float64", always_2d=True)
        data = apply_transient(data, sr, self.mode)

        board = Pedalboard()
        
        lufs = metrics.get('integrated_lufs', -18.0)
        slope = metrics.get('spectral_slope', 1.3)
        corr = metrics.get('correlation', 1.0)
        
        # --- Stage 1: Sub-Sonic Control (Foundation) ---
        # Adaptive HPF: steeper for dark mixes, gentler for acoustic clarity
        hpf_freq = 35 if slope > 1.4 else 30
        board.append(HighpassFilter(cutoff_frequency_hz=hpf_freq))
        
        # --- Stage 2: Multi-Stage Saturation (Organic Heat) ---
        # We blend saturation depth based on the input signal's 'thinness'.
        # Club runs hotter; ivory stays clean to protect transients.
        if self.mode == "club":
            drive = 2.5
        elif self.mode == "ivory":
            drive = 0.0
        else:
            drive = 1.5 if lufs < -18 else 1.0
        if drive > 0:
            board.append(Distortion(drive_db=drive))
        
        # --- Stage 3: Adaptive Spectral Balancing ---
        # Dynamically addresses 'Sonic Gravity' (Mud) and 'Expensive Air'
        
        # Address Mud (300-500Hz)
        if slope > 1.4:
            # Dark mix: surgical cut to unmask
            board.append(PeakFilter(cutoff_frequency_hz=420, gain_db=-2.5, q=0.4))
        
        # Address Air (10kHz+)
        # We use a broad Pultec-style shelf for that expensive sheen
        if self.mode == "club":
            air_gain = 4.0
        elif self.mode == "ivory":
            air_gain = 2.0
        else:
            air_gain = 3.5 if slope > 1.2 else 2.0
        board.append(HighShelfFilter(cutoff_frequency_hz=12000, gain_db=air_gain))

        # Vox presence lift — the voice sits on top without harshness.
        if self.mode == "vox":
            board.append(PeakFilter(cutoff_frequency_hz=3000, gain_db=2.5, q=1.0))
        
        # Address Body (150-250Hz)
        if slope < 1.1:
            # Brittle mix: add weight
            board.append(LowShelfFilter(cutoff_frequency_hz=200, gain_db=2.0))

        # --- Stage 4: Phase-Coherent Horizontal Expansion ---
        # Adaptive width: only widen if the track isn't already phase-risky
        if corr > 0.7:
            board.append(Chorus(rate_hz=0.1, depth=0.05, centre_delay_ms=7.0, feedback=0.0, mix=0.08))
        
        # --- Stage 5: Program-Dependent Glue (Compression) ---
        # Very low ratio for transparent leveling (Acoustic influence)
        # but with enough control to solidify the foundation (Modern influence).
        # Club squeezes harder for density.
        if self.mode == "club":
            comp_ratio = 2.0
        else:
            comp_ratio = 1.2 if lufs > -12 else 1.5
        board.append(Compressor(threshold_db=-22, ratio=comp_ratio, attack_ms=50, release_ms=200))
        
        # --- Stage 6: Gain Normalization ---
        # NOTE: neutral here — the true landing happens after the dynamics
        # stages below (measured trim, mirroring the native closed loop).
        # A unity placeholder keeps stage numbering stable.
        lufs_diff = 0.0
        board.append(Gain(gain_db=lufs_diff))
        
        # --- Stage 7: Safety Finalization (Brickwall, second pass) ---
        # The clipper below eats transient peaks first so the limiter
        # barely works — loudness without pumping.
        processed = board(data, sr)

        # --- Dynamics stages: tamer → multiband → upward → section trim ---
        processed, _sections = apply_dynamics(processed, sr, self.mode, self.target_lufs)

        # --- Measured landing: trim to target AFTER dynamics (closed loop) ---
        # The loop runs THROUGH clip + wall because the limiter wears
        # makeup gain — measuring before it would land hot every time.
        wall = Pedalboard([Limiter(threshold_db=-1.0, release_ms=100)])
        pre = processed
        trim_db = 0.0
        try:
            import pyloudnorm as ln
            for _ in range(3):
                cand = pre * (10 ** (trim_db / 20))
                cand = soft_clip(cand, cfg["clip_drive"])
                cand = wall(cand, sr)
                measured = float(ln.Meter(sr).integrated_loudness(cand))
                residual = self.target_lufs - measured
                if abs(residual) < 0.05:
                    processed = cand
                    break
                trim_db += residual
                processed = cand
        except Exception:
            processed = soft_clip(pre, cfg["clip_drive"])
            processed = wall(processed, sr)

        with AudioFile(output_path, 'w', sr, processed.shape[1]) as o:
            o.write(processed)

        return output_path

if __name__ == "__main__":
    print("Unified Mastering Executor Initialized.")
