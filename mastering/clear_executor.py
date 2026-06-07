import os
import soundfile as sf
from pedalboard import Pedalboard, Compressor, Gain, HighShelfFilter, LowShelfFilter, Limiter, PeakFilter, HighpassFilter
from pedalboard.io import AudioFile

class ClearExecutor:
    """
    Refined Acoustic Clarity Engine ('ACOUSTIC CLEAR').
    Focuses on the 'Expensive' acoustic sound:
    1. Sub-Rumble Tempering (Transparent Highpass)
    2. Boxiness Removal (Low-Mid Shelf)
    3. Spectral Unmasking (Mud-Range Peak)
    4. Harmonic Air (Ultra-High Shelf)
    5. Soft-Knee Glue (Transparent Leveling)
    """
    def __init__(self, target_lufs=-16.0): 
        self.target_lufs = target_lufs

    def apply_compensation(self, input_path, output_path, metrics):
        board = Pedalboard()
        
        # 1. Sub-Rumble Tempering (Highpass at 35Hz)
        # Using a gentle slope to remove DC and floor noise without affecting piano fundamentals.
        board.append(HighpassFilter(cutoff_frequency_hz=35))
        
        # 2. Boxiness / Room Resonance Suppression
        # Targetting the 'honky' 180Hz region often found in home acoustic recordings.
        board.append(LowShelfFilter(cutoff_frequency_hz=180, gain_db=-3.0))
        
        # 3. Spectral Unmasking (The 450Hz Mud Cut)
        # Surgical reduction of the 'masking' frequency to let the transients breathe.
        board.append(PeakFilter(cutoff_frequency_hz=450, gain_db=-2.0, q=0.4))
        
        # 4. Harmonic Air (12kHz Pultec-style lift)
        # Adding that 'expensive' sheen to the mechanical detail of the instrument.
        board.append(HighShelfFilter(cutoff_frequency_hz=12000, gain_db=3.5))
        
        # 5. Transparency Glue
        # 1.1:1 ratio, very soft knee, slow 60ms attack to keep the piano hammers punchy.
        board.append(Compressor(threshold_db=-18, ratio=1.1, attack_ms=60, release_ms=250))
        
        # 6. Level Matching
        lufs_diff = self.target_lufs - metrics['integrated_lufs']
        board.append(Gain(gain_db=lufs_diff))
        
        # 7. Final Safety Ceiling
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
    print("Clear Executor Blueprint Initialized.")
