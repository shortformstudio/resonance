"""Dynamics stages: multiband compression, soft clipping, transient design,
upward detail path, dynamic resonance suppression, section metering + trim.

Mirrors native/Sources/Resonance/Audio/Dynamics.swift. Everything is
vectorized numpy/scipy — no per-sample Python loops.
"""
import numpy as np
from scipy import signal


# ---------------- filter helpers (RBJ cookbook) ----------------

def _rbj_lp(f0, fs, q=0.7071):
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    return ([(1 - cw) / 2, 1 - cw, (1 - cw) / 2],
            [1 + alpha, -2 * cw, 1 - alpha])


def _rbj_peak(f0, gain_db, q, fs):
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    return ([1 + alpha * A, -2 * cw, 1 - alpha * A],
            [1 + alpha / A, -2 * cw, 1 - alpha / A])


def _rbj_bp(f0, q, fs):
    w0 = 2 * np.pi * f0 / fs
    alpha = np.sin(w0) / (2 * q)
    cw = np.cos(w0)
    return ([alpha, 0, -alpha], [1 + alpha, -2 * cw, 1 - alpha])


def _lp24(x, f0, fs):
    """24dB/oct low-pass: two cascaded RBJ stages, per channel."""
    b, a = _rbj_lp(f0, fs)
    y = signal.lfilter(b, a, x, axis=0)
    return signal.lfilter(b, a, y, axis=0)


def _onepole(x, ms, fs):
    """Symmetric one-pole smoother (fast follower)."""
    a = np.exp(-1.0 / (ms * 0.001 * fs))
    return signal.lfilter([1 - a], [1, -a], np.abs(x), axis=0)


# ---------------- per-mode configuration (mirrors ModeDynamics) ----------------

MODE_DYNAMICS = {
    "core": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.6,) * 4, mb_att=30, mb_rel=200,
                 clip_drive=1.5, trans=(0.25, 0.0), up=(0.35, 0.25), sup=0.5, trim=1.5),
    "resonance_v2": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.6,) * 4, mb_att=30, mb_rel=200,
                 clip_drive=1.5, trans=(0.25, 0.0), up=(0.35, 0.25), sup=0.5, trim=1.5),
    "pure": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.4,) * 4, mb_att=40, mb_rel=250,
                 clip_drive=0.0, trans=(0.15, 0.0), up=(0.3, 0.2), sup=0.7, trim=1.0),
    "clear": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.4,) * 4, mb_att=40, mb_rel=250,
                 clip_drive=0.0, trans=(0.15, 0.0), up=(0.3, 0.2), sup=0.7, trim=1.0),
    "heat": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.5,) * 4, mb_att=35, mb_rel=220,
                 clip_drive=2.0, trans=(0.2, 0.1), up=(0.4, 0.3), sup=0.4, trim=1.5),
    "unified_hybrid_v1": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.5,) * 4, mb_att=35, mb_rel=220,
                 clip_drive=2.0, trans=(0.2, 0.1), up=(0.4, 0.3), sup=0.4, trim=1.5),
    "club": dict(mb_thr=(-24, -22, -22, -26), mb_ratio=(2.2,) * 4, mb_att=20, mb_rel=150,
                 clip_drive=3.0, trans=(0.35, 0.0), up=(0.3, 0.2), sup=0.6, trim=2.0),
    "ivory": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.3,) * 4, mb_att=50, mb_rel=300,
                 clip_drive=0.0, trans=(0.1, 0.0), up=(0.25, 0.2), sup=0.3, trim=1.0),
    "vox": dict(mb_thr=(-22, -20, -20, -24), mb_ratio=(1.6,) * 4, mb_att=30, mb_rel=200,
                 clip_drive=1.0, trans=(0.2, 0.0), up=(0.35, 0.25), sup=0.8, trim=1.5),
}


def mode_cfg(mode):
    return MODE_DYNAMICS.get(mode, MODE_DYNAMICS["core"])


# ---------------- multiband compression ----------------

def _softknee_gain(level_db, thr_db, ratio, knee=6.0):
    over = level_db - thr_db
    g = np.where(over <= -knee / 2, 0.0,
        np.where(over >= knee / 2, (1.0 / ratio - 1.0) * over,
                 (1.0 / ratio - 1.0) * (over + knee / 2) ** 2 / (2 * knee)))
    return 10 ** (g / 20)


def multiband(data, fs, cfg, crossovers=(120, 900, 5000)):
    """Corrective 4-band RMS compression. data: (samples, channels)."""
    f1, f2, f3 = crossovers
    b1 = _lp24(data, f1, fs)
    r1 = data - b1
    b2 = _lp24(r1, f2, fs)
    r2 = r1 - b2
    b3 = _lp24(r2, f3, fs)
    b4 = r2 - b3
    out = np.zeros_like(data)
    for i, band in enumerate((b1, b2, b3, b4)):
        env = _onepole(band, cfg["mb_att"], fs)
        lvl = 20 * np.log10(np.maximum(env, 1e-9))
        g = _softknee_gain(lvl, cfg["mb_thr"][i], cfg["mb_ratio"][i])
        # release smoothing on the gain itself for gentleness
        out += band * g
    return out


# ---------------- soft clipper ----------------

def soft_clip(data, drive_db, ceiling_db=-1.0):
    if drive_db <= 0.05:
        return data
    g = 10 ** (drive_db / 20)
    c = 10 ** (ceiling_db / 20)
    return c * np.tanh(g * data) / np.tanh(g)


# ---------------- transient designer (two bands) ----------------

def transient(data, fs, attack, sustain, split_hz=900):
    if attack == 0 and sustain == 0:
        return data
    lo = _lp24(data, split_hz, fs)
    hi = data - lo
    out = np.zeros_like(data)
    for band in (lo, hi):
        fast = _onepole(band, 0.8, fs)
        slow = _onepole(band, 40, fs)
        onset = np.clip((fast - slow) / (slow + 1e-4), 0, 1.5)
        body = np.clip(slow * 3.0, 0, 1.0)
        gain = (1 + attack * onset) * (1 + sustain * body)
        out += band * np.maximum(gain, 0)
    return out


# ---------------- upward parallel path ----------------

def upward(data, fs, depth, mix, threshold_db=-36.0, max_boost_db=6.0):
    if depth <= 0 or mix <= 0:
        return data
    level = _onepole(data, 150, fs)
    level_db = 20 * np.log10(np.maximum(level, 1e-9))
    boost = np.clip((threshold_db - level_db) * depth * 0.5, 0, max_boost_db)
    wet = data * 10 ** (boost / 20)
    return data * (1 - mix) + wet * mix


# ---------------- dynamic resonance suppressor (2–8 kHz) ----------------

_SUPPRESS_SPOTS = (2200, 2800, 3500, 4400, 5600, 7000)


def suppress(data, fs, depth, max_cut_db=6.0, q=3.0):
    """Subtractive dynamic bells: cut exists only while harshness sounds."""
    if depth <= 0:
        return data
    out = data.copy()
    body = _onepole(data, 120, fs)
    for f0 in _SUPPRESS_SPOTS:
        b, a = _rbj_bp(f0, q, fs)
        band = signal.lfilter(b, a, data, axis=0)
        env = _onepole(band, 60, fs)
        excess_db = 20 * np.log10(np.maximum(env, 1e-9) / np.maximum(body, 1e-9))
        cut_db = np.clip((excess_db - 4.0) * depth * 0.75, 0, max_cut_db)
        g = 1 - (1 - 10 ** (-cut_db / 20))
        # smooth the control signal to avoid zipper noise
        g = _onepole(g, 25, fs)
        out = out - band * (1 - g)
    return out


# ---------------- section metering + adaptive trim ----------------

def analyze_sections(data, fs, count=8):
    """Per-section loudness. Returns list of dicts with start_sec + lufs."""
    try:
        import pyloudnorm as ln
    except ImportError:
        ln = None
    n = data.shape[0]
    per = max(1, n // count)
    out = []
    for s in range(count):
        start = min(s * per, n - 1)
        end = n if s == count - 1 else min(start + per, n)
        if end <= start:
            continue
        seg = data[start:end]
        if ln is not None:
            try:
                lufs = float(ln.Meter(fs).integrated_loudness(seg))
            except Exception:
                lufs = -70.0
        else:
            rms = np.sqrt(np.mean(seg ** 2) + 1e-12)
            lufs = float(20 * np.log10(rms + 1e-12) - 3.0)
        out.append({"start_sec": start / fs, "lufs": round(lufs, 2)})
    return out


def short_term_lra(data, fs, block_sec=3.0, hop_sec=1.5):
    try:
        import pyloudnorm as ln
        meter = ln.Meter(fs)
        block, hop = int(block_sec * fs), int(hop_sec * fs)
        vals = []
        s = 0
        while s + block <= data.shape[0]:
            try:
                v = float(meter.integrated_loudness(data[s:s + block]))
            except Exception:
                v = -70.0
            if v > -70:
                vals.append(v)
            s += hop
        if len(vals) < 2:
            return 0.0
        arr = np.sort(np.array(vals))
        mean = arr.mean()
        rel = arr[arr >= mean - 20]
        if len(rel) < 2:
            return 0.0
        return round(float(np.percentile(rel, 95) - np.percentile(rel, 10)), 1)
    except ImportError:
        return 0.0


def crest_factor(data):
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    rms = float(np.sqrt(np.mean(data ** 2))) if data.size else 0.0
    if rms <= 0:
        return 0.0
    return round(float(20 * np.log10(max(peak, 1e-9) / rms)), 1)


def histogram(data, points=120):
    mono = data.mean(axis=1) if data.ndim > 1 else data
    if mono.size == 0:
        return []
    hop = max(1, mono.size // points)
    peaks = [float(np.max(np.abs(mono[i:i + hop]))) for i in range(0, mono.size, hop)][:points]
    mx = max(peaks) if peaks else 1.0
    return [round(p / max(mx, 1e-6), 3) for p in peaks]


def section_trim_gains(sections, target_lufs, max_db):
    trims = []
    for s in sections:
        trims.append(float(np.clip(target_lufs - s["lufs"], -max_db, max_db)))
    return trims


def apply_section_trim(data, fs, sections, target_lufs, max_db):
    if len(sections) < 2 or max_db <= 0:
        return data
    n = data.shape[0]
    per = max(1, n // len(sections))
    fade = int(0.5 * fs)
    trims = section_trim_gains(sections, target_lufs, max_db)
    idx = np.minimum(np.arange(n) // per, len(sections) - 1)
    gain_db = np.array(trims)[idx].astype(float)
    # raised-cosine crossfade across boundaries
    for s in range(1, len(sections)):
        b = s * per
        lo, hi = max(0, b - fade), min(n, b + fade)
        if hi <= lo:
            continue
        t = (np.arange(lo, hi) - (b - fade)) / max(2 * fade, 1)
        w = 0.5 - 0.5 * np.cos(np.pi * np.clip(t, 0, 1))
        gain_db[lo:hi] = trims[s - 1] * (1 - w) + trims[s] * w
    return data * (10 ** (gain_db / 20))[:, None]


# ---------------- one-call chain ----------------

def apply_transient(data, fs, mode):
    cfg = mode_cfg(mode)
    atk, sus = cfg["trans"]
    return transient(data, fs, atk, sus)


def apply_dynamics(data, fs, mode, target_lufs):
    """Tamer → multiband → upward → section trim. data: (samples, channels)."""
    cfg = mode_cfg(mode)
    out = suppress(data, fs, cfg["sup"])
    out = multiband(out, fs, cfg)
    out = upward(out, fs, cfg["up"][0], cfg["up"][1])
    sections = analyze_sections(out, fs)
    out = apply_section_trim(out, fs, sections, target_lufs, cfg["trim"])
    return out, sections


def dynamics_report(data, fs):
    if data.ndim == 1:
        data = data[:, None]
    sections = analyze_sections(data, fs)
    lufs = [s["lufs"] for s in sections if s["lufs"] > -70]
    spread = round(max(lufs) - min(lufs), 1) if lufs else 0.0
    return {
        "lra": short_term_lra(data, fs),
        "crest_db": crest_factor(data),
        "section_spread_db": spread,
        "sections": sections,
        "histogram": histogram(data),
    }
