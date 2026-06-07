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
    """
    def __init__(self, target_lufs=-14.0):
        self.target_lufs = target_lufs

    def apply_compensation(self, input_path, output_path, metrics):
        board = Pedalboard()
        
        lufs = metrics.get('integrated_lufs', -18.0)
        slope = metrics.get('spectral_slope', 1.3)
        corr = metrics.get('correlation', 1.0)
        
        # --- Stage 1: Sub-Sonic Control (Foundation) ---
        # Adaptive HPF: steeper for dark mixes, gentler for acoustic clarity
        hpf_freq = 35 if slope > 1.4 else 30
        board.append(HighpassFilter(cutoff_frequency_hz=hpf_freq))
        
        # --- Stage 2: Multi-Stage Saturation (Organic Heat) ---
        # We blend saturation depth based on the input signal's 'thinness'
        drive = 1.5 if lufs < -18 else 1.0
        board.append(Distortion(drive_db=drive))
        
        # --- Stage 3: Adaptive Spectral Balancing ---
        # Dynamically addresses 'Sonic Gravity' (Mud) and 'Expensive Air'
        
        # Address Mud (300-500Hz)
        if slope > 1.4:
            # Dark mix: surgical cut to unmask
            board.append(PeakFilter(cutoff_frequency_hz=420, gain_db=-2.5, q=0.4))
        
        # Address Air (10kHz+)
        # We use a broad Pultec-style shelf for that expensive sheen
        air_gain = 3.5 if slope > 1.2 else 2.0
        board.append(HighShelfFilter(cutoff_frequency_hz=12000, gain_db=air_gain))
        
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
        comp_ratio = 1.2 if lufs > -12 else 1.5
        board.append(Compressor(threshold_db=-22, ratio=comp_ratio, attack_ms=50, release_ms=200))
        
        # --- Stage 6: Gain Normalization ---
        lufs_diff = self.target_lufs - lufs
        board.append(Gain(gain_db=lufs_diff))
        
        # --- Stage 7: Safety Finalization (Brickwall) ---
        board.append(Limiter(threshold_db=-1.0, release_ms=100))

        # Processing loop
        with AudioFile(input_path) as f:
            with AudioFile(output_path, 'w', f.samplerate, f.num_channels) as o:
                while f.tell() < f.frames:
                    chunk = f.read(f.samplerate)
                    processed_chunk = board(chunk, f.samplerate, reset=False)
                    o.write(processed_chunk)
        
        return output_path

if __name__ == "__main__":
    print("Unified Mastering Executor Initialized.")
