# APPSPIRIT: TECHNICAL SPECIFICATION & DEVELOPMENT JOURNAL OF Waveform [AUDIO EVALUATOR+MIXING AND MASTERING ENGINE]

## 1. Utilitarian Overview & Purpose
- **App Name**: Waveform
- **Bento Slot**: resonance
- **Role/Responsibility**: Frequency evaluator and mastering engine.
- **Core Intent**: An audio signal processing workstation for spectral analyzer and loudness measurement, specifically for clarity and fullness, with slight warm analog feel (LUFS/peak/RMS).

## 2. Technical System Architecture & File Structure
- **Execution Target**: Desktop or browser execution pipeline.
- **Frontend Stack**: Monospace log outputs, sleek visual card layout indicators, translucent glassmorphism container styling.
- **Backend & Integrations**: Mapped sifter CLI node (`gemini.cjs`, `gemini`, `gemini.bat`), local JSON database storage (`history_log.json`).
- **Visual Design Parameters**:
  - Accent Color: #D4AF37 (Mitosis Gold)
  - Typography: High-contrast typography, ample negative space padding, absolute lack of nested visual views to prevent cognitive burden.
- **Structural Blueprint**:
  Main entrypoint: app.py, logging_config.py.
  DSP Engine: Employs librosa, numpy, and scipy algorithms to compute audio waveforms and frequency graphs.

## 3. Active Development Roadmap & Core Tasks
- [x] CLI Agent Deployment & Twin-Markdown Spec Scaffolding (GEMINI.MD & APPSPIRIT.MD)
- [ ] Implement robust local validation and input checking pipelines
- [ ] Optimize window render latency to < 100ms transitions
- [ ] Refine the sound chiming system and sync glowing pulse highlight indicators
- [ ] Fortify offline state restoration and error logging mechanisms

## 4. Sonic Philosophy & Engineering Logic
Waveform is not merely a utility; it is a digital-analog hybrid sifter. Its DSP logic is grounded in three core pillars:
1. **The 'Expensive' Air**: High-end frequency response (10kHz+) is treated with the 'Pultec' philosophy—broad, musical shelf boosts that prioritize phase coherence over raw gain.
2. **Harmonic Density**: Rather than binary limiting, we employ 'thermal pushes' using subtle saturation. This introduces even-order harmonics that solidify the phantom center and add 'chest' weight to the signal.
3. **Spectral Gravity**: Logic is implemented to identify and neutralize 'mud accumulation' (300-500Hz). By treating this as 'sonic gravity' that masks detail, we achieve clarity without sacrificing the organic warmth of the original recording.

## 5. System Concerns & Aspects Needing Work
- Spectral graph calculation causes UI latency on larger audio files. Move FFT calculations to background worker threads.
- Calibrate LUFS calculations against standard EBU R128 metering.
- Add robust fallbacks and descriptive error popups for corrupted or unreadable audio container formats.

## 5. Progress Journal & Reflective Agent Log
*Replicator Agent: Deliberate technical structures, code changes, and dry-run reasoning here before writing updates to the local workspace.*

- **Current Status**: Standalone Electron App (resonance V4.0) - Antigravity Framework Integrated.
- **Architectural Shift**: Fully migrated to the Antigravity Design Framework. Transitioned to a native macOS glassmorphic workstation with 'under-window' vibrancy and borderless architecture. Enforced strict lowercase typography (Avenir Next 100/200) across all structural elements. Removed all legacy aesthetic toggles to ensure singular, directive-compliant visual consistency.
- **Tandem Suite**: Maintained high-performance tandem mastering logic and critically-aware engineer audits within the new lightweight glassmorphic shell.

## 6. Development Changelog
- **2026-06-06**: Migrated to Antigravity Design Directive: Implemented native vibrancy, 30px frosted blurs, and strict lowercase global constraints.
- **2026-06-06**: Standardized Cyan Accent (#06b6d4) with multi-layered glow tokens for all interactive highlights.
- **2026-06-06**: Refactored window architecture in main.js for transparent, borderless macOS blur bleed.
- **2026-06-02**: Implemented 'Session History' tracking with click-to-reveal disclosure logic.
