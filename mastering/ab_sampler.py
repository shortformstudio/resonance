import os
import numpy as np
import soundfile as sf

try:
    import librosa
    _HAS_LIBROSA = True
except Exception:
    _HAS_LIBROSA = False


class ABSampler:
    """Builds a cohesive before/after comparison clip.

    Produces a single ~30s file that alternates between the ORIGINAL (before)
    and the MASTERED (after) version every `segment_seconds`, pulling each
    segment from the SAME time region of both files so the listener hears the
    exact same musical content flip between untreated and treated. Short
    equal-power crossfades at each boundary keep the switches seamless.
    """

    def __init__(self, segment_seconds=5, total_seconds=30, crossfade_ms=60):
        self.segment_seconds = segment_seconds
        self.total_seconds = total_seconds
        self.crossfade_ms = crossfade_ms

    # ---- loading helpers ----------------------------------------------------

    def _load(self, path, target_rate=None):
        """Load audio as float32 (samples, channels), optionally resampled."""
        try:
            data, rate = sf.read(path, always_2d=True, dtype='float32')
        except Exception:
            if not _HAS_LIBROSA:
                raise
            mono_or_multi, rate = librosa.load(path, sr=None, mono=False)
            data = mono_or_multi.T if mono_or_multi.ndim > 1 else mono_or_multi[:, None]
            data = data.astype(np.float32)

        if target_rate and rate != target_rate:
            if _HAS_LIBROSA:
                # librosa resamples (channels, samples)
                res = librosa.resample(data.T, orig_sr=rate, target_sr=target_rate)
                data = res.T.astype(np.float32)
            rate = target_rate
        return data, rate

    @staticmethod
    def _match_channels(a, b):
        """Force both signals to the same channel count (upmix mono, or downmix)."""
        ca, cb = a.shape[1], b.shape[1]
        target = max(ca, cb)
        def fit(x):
            if x.shape[1] == target:
                return x
            if x.shape[1] == 1:                      # mono -> stereo
                return np.repeat(x, target, axis=1)
            return np.mean(x, axis=1, keepdims=True) # multi -> mono, then repeat
        a2, b2 = fit(a), fit(b)
        if a2.shape[1] != b2.shape[1]:
            t = min(a2.shape[1], b2.shape[1])
            a2, b2 = a2[:, :t], b2[:, :t]
        return a2, b2

    @staticmethod
    def _equal_power_fades(segment, fade_len):
        """Apply an equal-power fade-in and fade-out to a segment in place."""
        n = segment.shape[0]
        if fade_len <= 0 or n < 2 * fade_len:
            return segment
        t = np.linspace(0, np.pi / 2, fade_len, dtype=np.float32)
        fade_in = np.sin(t)[:, None]
        fade_out = np.cos(t)[:, None]
        segment[:fade_len] *= fade_in
        segment[-fade_len:] *= fade_out
        return segment

    # ---- main ---------------------------------------------------------------

    @staticmethod
    def _take_segment(src, seg_start, seg_len):
        """Return exactly `seg_len` frames from `src` starting at `seg_start`,
        tiling (looping) the source when it is shorter than a full segment so
        every segment is the same length and the 30s target is always met."""
        total = src.shape[0]
        if total == 0:
            return np.zeros((seg_len, src.shape[1]), dtype=np.float32)
        idx = (np.arange(seg_start, seg_start + seg_len) % total)
        return np.array(src[idx], dtype=np.float32, copy=True)

    def build(self, before_path, after_path, output_path, start_seconds=None):
        """Render the alternating A/B comparison clip to `output_path`."""
        after, rate = self._load(after_path)
        before, _ = self._load(before_path, target_rate=rate)
        before, after = self._match_channels(before, after)

        channels = after.shape[1]
        seg_len = int(self.segment_seconds * rate)
        fade_len = int((self.crossfade_ms / 1000.0) * rate)
        num_segments = max(1, int(round(self.total_seconds / self.segment_seconds)))

        usable = min(before.shape[0], after.shape[0])
        needed = seg_len * num_segments

        # Pick a representative window. Default: skip a short lead-in if there's
        # room (tracks tend to open quietly), else start at 0.
        if start_seconds is None:
            start = max(0, int(min(usable * 0.15, max(0, usable - needed))))
        else:
            start = max(0, int(start_seconds * rate))

        sources = {'before': before, 'after': after}
        order = []
        pieces = []
        for i in range(num_segments):
            which = 'before' if i % 2 == 0 else 'after'  # A, B, A, B, ...
            order.append(which)
            # Both versions are pulled from the SAME region so identical musical
            # content flips between untreated and treated.
            seg_start = start + i * seg_len
            segment = self._take_segment(sources[which], seg_start, seg_len)
            segment = self._equal_power_fades(segment, fade_len)
            pieces.append(segment)

        clip = np.concatenate(pieces, axis=0) if pieces else np.zeros((seg_len, channels), np.float32)

        # Guard against inter-sample clipping in the concatenated clip.
        peak = float(np.max(np.abs(clip))) if clip.size else 0.0
        if peak > 0.999:
            clip = clip * (0.999 / peak)

        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        sf.write(output_path, clip, rate, subtype='PCM_16')

        return {
            'output_path': output_path,
            'sample_rate': rate,
            'channels': channels,
            'segment_seconds': self.segment_seconds,
            'total_seconds': round(len(clip) / rate, 2),
            'segments': num_segments,
            'order': order,
        }


if __name__ == '__main__':
    print('AB Sampler ready.')
