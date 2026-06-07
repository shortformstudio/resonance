import numpy as np
import soundfile as sf
import os

def generate_test_wav(filename="test_control.wav"):
    rate = 44100
    duration = 5
    t = np.linspace(0, duration, rate * duration)
    
    # Generate pink noise-ish spectrum
    # White noise filtered to -3dB/octave
    white = np.random.normal(0, 0.1, size=t.shape)
    
    # Simple FFT filter to create a -3dB/octave slope (Pink Noise)
    f = np.fft.rfftfreq(len(white))
    f[0] = 1 # Avoid div by zero
    filter_curve = 1 / np.sqrt(f)
    
    white_fft = np.fft.rfft(white)
    pink_fft = white_fft * filter_curve
    pink_noise = np.fft.irfft(pink_fft)
    
    # Normalize to -14 LUFS (approx linear amplitude 0.2)
    pink_noise = pink_noise / np.max(np.abs(pink_noise)) * 0.2
    
    # Create stereo with slight decorrelation for width
    stereo = np.vstack([pink_noise, np.roll(pink_noise, 100)]).T
    
    sf.write(filename, stereo, rate)
    print(f"Created control file: {filename}")

if __name__ == "__main__":
    generate_test_wav()
