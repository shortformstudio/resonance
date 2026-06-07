# CLEAR Mode Design Summary: Acoustic Clarity Engine

## 1. Inspiration & Provenance
This mode is designed to emulate the "expensive" sound of high-end acoustic recordings. The DSP architecture is inspired by the following professional tools:
- **FabFilter Pro-Q 3:** For the surgical "De-Mudding" approach in the 300Hz-600Hz range.
- **Izotope Ozone Clarity Module:** Specifically the "Spectral Flatness" compensation used to restore tonal balance.
- **Soundtoys Radiator:** For the "Air" excitation logic that brings out mechanical details (piano hammers, string vibration).
- **SSL G-Bus Compressor:** For the "Acoustic Glue" logic (low ratio, slow attack).

## 2. Mathematical DSP Sequence
The 'CLEAR' mode executes the following sequence to ensure phase coherence and transparent enhancement:

### Step 1: Sub-Frequency Tempering (High-Pass Filter)
- **Math:** 24dB/octave Butterworth High-Pass at **40Hz**.
- **Purpose:** Removes non-musical sub-rumble and DC offset that causes "redlining" without affecting the piano's fundamental weight.

### Step 2: Resonance Suppression (Low-Shelf)
- **Math:** Low-Shelf Filter at **180Hz** with a **-3.5dB** gain and a Q-factor of **0.7**.
- **Purpose:** Tempers the "boxy" resonance typical of home acoustic recordings. Prevents the "thump" from overpowering the mid-high harmonics.

### Step 3: Spectral Unmasking (De-Mudding)
- **Math:** Wide Bell Filter (PeakFilter) centered at **450Hz**, gain **-2.0dB**, Q **0.5**.
- **Purpose:** This is the "Mud" frequency. Reducing this range physically unmasks the high-end transients, allowing the instrument to "breathe."

### Step 4: High-End Excitation (Air Shelf)
- **Math:** High-Shelf Filter at **12kHz** with a **+3.0dB** gain.
- **Purpose:** Restores the "felt" presence of the instrument. Brings out the mechanical clarity of the performance.

### Step 5: Transparency Compression (The Glue)
- **Math:** **1.15:1 Ratio**, Threshold **-18dB**, Attack **60ms**, Release **250ms**, Soft Knee.
- **Purpose:** This is NOT for loudness. It is for "leveling" the performance so that fortissimo passages don't spike while pianissimo passages remain audible.

## 3. Acoustic Scoring Rubric
The grading engine for CLEAR mode shifts its focus:
- **Primary Metric:** Spectral Flatness (Higher = more cohesive/less resonant spikes).
- **Secondary Metric:** Transients-to-Body Ratio (ensuring the compression hasn't dulled the attack).

---
*Blueprint initialized for mitosisOS by Vortex.*
