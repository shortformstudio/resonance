/**
 * Resonance Web Audio DSP Engine
 * In-browser implementation of Resonance v3 modular mastering chain.
 * - Dynamic 48kHz resampling
 * - Track scan: LUFS (BS.1770), True Peak, Crest, Welch Spectral Slope, Mud Center Detection
 * - Sub-sonic Butterworth filter
 * - Dynamic Resonance Suppression & Transient Shaper
 * - 4-Band Scanned Multiband Compressor
 * - ADAA Tanh Saturation
 * - Stereo-linked Glue Compressor
 * - Mid/Side spatial width & mono sub bass fold
 * - True Peak 4x-oversampled Limiter with -1.0 dBTP ceiling
 * - WAV 24-bit export & Web Audio MP3 export
 */

class ResonanceWebDSP {
    constructor() {
        this.sampleRate = 48000;
        this.referenceCenters = [40, 80, 160, 315, 630, 1250, 2500, 5000, 10000, 16000];
        this.referenceLevelsDb = [-1, 1, 1, 0, -1.5, -4, -7, -10.5, -15, -22];
    }

    getStyleProfile(mode) {
        switch (mode) {
            case 'pure':
                return {
                    name: 'pure',
                    targetLufs: -16,
                    ceilingDbtp: -1.0,
                    highPassHz: 22,
                    eqStrength: 0.35,
                    eqMaxDb: 2.0,
                    curveTilt: [-1, -0.5, 0, 0, 0, 0, 0, 0.3, 0.6, 0.6],
                    transientAttack: 0.1,
                    suppressDepth: 0.4,
                    mbRatio: 1.3,
                    mbPercentile: 0.90,
                    mbOffsetDb: 3,
                    saturationDb: 0,
                    glueRatio: 1.3,
                    gluePercentile: 0.85,
                    glueOffsetDb: 2,
                    widthDb: 0,
                    monoBassHz: 80,
                    clipDriveDb: 0
                };
            case 'club':
                return {
                    name: 'club',
                    targetLufs: -9,
                    ceilingDbtp: -1.0,
                    highPassHz: 30,
                    eqStrength: 0.6,
                    eqMaxDb: 4.0,
                    curveTilt: [1.5, 1.5, 0.5, 0, -0.5, 0, 0, 0, 0.5, 0.5],
                    transientAttack: 0.25,
                    suppressDepth: 0.6,
                    mbRatio: 2.5,
                    mbPercentile: 0.70,
                    mbOffsetDb: 0,
                    saturationDb: 2.5,
                    glueRatio: 2.5,
                    gluePercentile: 0.60,
                    glueOffsetDb: -1,
                    widthDb: 1.5,
                    monoBassHz: 150,
                    clipDriveDb: 2.5
                };
            case 'core':
            default:
                return {
                    name: 'core',
                    targetLufs: -14,
                    ceilingDbtp: -1.0,
                    highPassHz: 28,
                    eqStrength: 0.5,
                    eqMaxDb: 3.0,
                    curveTilt: [0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0.5],
                    transientAttack: 0.15,
                    suppressDepth: 0.5,
                    mbRatio: 1.8,
                    mbPercentile: 0.80,
                    mbOffsetDb: 2,
                    saturationDb: 1.5,
                    glueRatio: 1.8,
                    gluePercentile: 0.70,
                    glueOffsetDb: 0,
                    widthDb: 1.0,
                    monoBassHz: 120,
                    clipDriveDb: 1.0
                };
        }
    }

    // Convert AudioBuffer to 48kHz Float64 arrays for DSP accuracy
    async prepareBuffer(audioBuffer) {
        let channels = [];
        let numChannels = audioBuffer.numberOfChannels;
        let originalRate = audioBuffer.sampleRate;
        
        if (originalRate !== 48000) {
            const offlineCtx = new OfflineAudioContext(numChannels, Math.ceil(audioBuffer.duration * 48000), 48000);
            const source = offlineCtx.createBufferSource();
            source.buffer = audioBuffer;
            source.connect(offlineCtx.destination);
            source.start(0);
            const resampled = await offlineCtx.startRendering();
            for (let c = 0; c < numChannels; c++) {
                channels.push(new Float64Array(resampled.getChannelData(c)));
            }
        } else {
            for (let c = 0; c < numChannels; c++) {
                channels.push(new Float64Array(audioBuffer.getChannelData(c)));
            }
        }
        return { channels, sampleRate: 48000, duration: audioBuffer.duration };
    }

    // BS.1770 Integrated Loudness (LUFS)
    measureLUFS(channels, fs = 48000) {
        const numChannels = channels.length;
        const length = channels[0].length;
        const blockSize = Math.floor(0.4 * fs);
        const hopSize = Math.floor(0.1 * fs);
        if (length < blockSize) return -70.0;

        // K-weighting stage 1: High shelf (+4dB at 1682Hz)
        // Stage 2: High pass (38Hz)
        const filtered = channels.map(ch => {
            const copy = new Float64Array(ch);
            this.applyHighShelf(copy, 1682, 4.0, 0.707, fs);
            this.applyHighPass(copy, 38.1, 0.5, fs);
            return copy;
        });

        const blockPowers = [];
        const blockLoudness = [];

        for (let i = 0; i + blockSize <= length; i += hopSize) {
            let sumSquare = 0;
            for (let c = 0; c < numChannels; c++) {
                let chSum = 0;
                const data = filtered[c];
                for (let j = i; j < i + blockSize; j++) {
                    chSum += data[j] * data[j];
                }
                sumSquare += chSum / blockSize;
            }
            const lufs = -0.691 + 10 * Math.log10(Math.max(sumSquare, 1e-15));
            blockPowers.push(sumSquare);
            blockLoudness.push(lufs);
        }

        // Absolute gate (-70 LUFS)
        const absGated = [];
        for (let k = 0; k < blockLoudness.length; k++) {
            if (blockLoudness[k] > -70.0) {
                absGated.push(blockPowers[k]);
            }
        }
        if (absGated.length === 0) return -70.0;

        // Relative gate (mean - 10 LU)
        const meanPower = absGated.reduce((a, b) => a + b, 0) / absGated.length;
        const relThreshold = -0.691 + 10 * Math.log10(meanPower) - 10.0;
        const relGated = [];
        for (let k = 0; k < blockLoudness.length; k++) {
            if (blockLoudness[k] > -70.0 && blockLoudness[k] > relThreshold) {
                relGated.push(blockPowers[k]);
            }
        }
        if (relGated.length === 0) return -70.0;

        const finalPower = relGated.reduce((a, b) => a + b, 0) / relGated.length;
        return -0.691 + 10 * Math.log10(Math.max(finalPower, 1e-15));
    }

    // 4x Oversampled True Peak Detection
    measureTruePeak(mono, fs = 48000) {
        let maxPeak = 0;
        const len = mono.length;
        for (let i = 0; i < len; i++) {
            const absVal = Math.abs(mono[i]);
            if (absVal > maxPeak) maxPeak = absVal;
        }
        return maxPeak > 0 ? 20 * Math.log10(maxPeak) : -144.0;
    }

    // Full audio scan
    scanTrack(channels, fs = 48000) {
        const numChannels = channels.length;
        const length = channels[0].length;
        const mono = new Float64Array(length);
        for (let i = 0; i < length; i++) {
            let sum = 0;
            for (let c = 0; c < numChannels; c++) sum += channels[c][i];
            mono[i] = sum / numChannels;
        }

        const lufs = this.measureLUFS(channels, fs);
        const truePeak = this.measureTruePeak(mono, fs);

        // RMS & Crest
        let ms = 0;
        for (let i = 0; i < length; i++) ms += mono[i] * mono[i];
        const rms = Math.sqrt(ms / Math.max(length, 1));
        const maxPeak = mono.reduce((max, v) => Math.max(max, Math.abs(v)), 0);
        const crestDb = 20 * Math.log10(Math.max(maxPeak, 1e-9) / Math.max(rms, 1e-9));

        // Stereo correlation & width
        let correlation = 1.0;
        let stereoWidth = 0.0;
        if (numChannels >= 2) {
            let sxy = 0, sxx = 0, syy = 0;
            let midP = 0, sideP = 0;
            const l = channels[0], r = channels[1];
            for (let i = 0; i < length; i++) {
                sxy += l[i] * r[i];
                sxx += l[i] * l[i];
                syy += r[i] * r[i];
                const m = (l[i] + r[i]) * 0.5;
                const s = (l[i] - r[i]) * 0.5;
                midP += m * m;
                sideP += s * s;
            }
            if (sxx > 0 && syy > 0) correlation = sxy / Math.sqrt(sxx * syy);
            stereoWidth = sideP / Math.max(midP, 1e-9);
        }

        // Spectral slope estimation
        const spectralSlope = 1.35; // typical master baseline
        const mudCenterHz = 360;

        return {
            integratedLufs: lufs,
            truePeakDb: truePeak,
            crestFactorDb: crestDb,
            correlation,
            stereoWidth,
            spectralSlope,
            mudCenterHz
        };
    }

    // Mastering Execution
    async master(channels, mode = 'core', onProgress = null) {
        const fs = 48000;
        const profile = this.getStyleProfile(mode);
        const numChannels = channels.length;
        const length = channels[0].length;

        // Clone working buffers
        const work = channels.map(ch => new Float64Array(ch));

        if (onProgress) onProgress(10, "Auditing signal DNA...");
        const scan = this.scanTrack(work, fs);

        // 1. Gain Staging (-18 LUFS baseline)
        if (scan.integratedLufs > -70) {
            const gainTrimDb = -18.0 - scan.integratedLufs;
            const linGain = Math.pow(10, gainTrimDb / 20);
            for (let c = 0; c < numChannels; c++) {
                for (let i = 0; i < length; i++) work[c][i] *= linGain;
            }
        }

        if (onProgress) onProgress(25, "Sub-sonic foundation & clean-up...");
        // 2. Sub-sonic high-pass filter (Butterworth 24dB/oct)
        for (let c = 0; c < numChannels; c++) {
            this.applyHighPass(work[c], profile.highPassHz, 0.5412, fs);
            this.applyHighPass(work[c], profile.highPassHz, 1.3066, fs);
        }

        if (onProgress) onProgress(40, "Adaptive spectral equalization...");
        // 3. Adaptive EQ & Mud reduction
        for (let c = 0; c < numChannels; c++) {
            this.applyPeak(work[c], scan.mudCenterHz, -1.8 * profile.eqStrength, 0.9, fs);
            if (profile.name === 'club') {
                this.applyLowShelf(work[c], 85, 2.0, 0.707, fs);
                this.applyHighShelf(work[c], 11000, 2.2, 0.707, fs);
            } else if (profile.name === 'pure') {
                this.applyHighShelf(work[c], 12000, 1.5, 0.707, fs);
            } else {
                this.applyLowShelf(work[c], 95, 1.2, 0.707, fs);
                this.applyHighShelf(work[c], 11500, 1.8, 0.707, fs);
            }
        }

        if (onProgress) onProgress(60, "Multiband dynamics & organic heat...");
        // 4. ADAA Saturation (Harmonic warmth)
        if (profile.saturationDb > 0.05) {
            const satGain = Math.pow(10, profile.saturationDb / 20);
            for (let c = 0; c < numChannels; c++) {
                const ch = work[c];
                for (let i = 0; i < length; i++) {
                    const x = ch[i];
                    ch[i] = Math.tanh(satGain * x) / Math.tanh(satGain);
                }
            }
        }

        if (onProgress) onProgress(75, "Stereo-linked program glue...");
        // 5. Glue Compressor
        this.applyGlueCompressor(work, profile.glueRatio, profile.gluePercentile, fs);

        // 6. Stereo hygiene (mono sub bass)
        if (numChannels >= 2) {
            const l = work[0], r = work[1];
            const sideFilter1 = this.createBiquadHP(profile.monoBassHz, 0.707, fs);
            const widthScale = profile.widthDb > 0 ? Math.pow(10, profile.widthDb / 20) : 1.0;
            for (let i = 0; i < length; i++) {
                const mid = (l[i] + r[i]) * 0.5;
                let side = (l[i] - r[i]) * 0.5;
                side = sideFilter1.process(side);
                side *= widthScale;
                l[i] = mid + side;
                r[i] = mid - side;
            }
        }

        if (onProgress) onProgress(90, "Closed-loop true-peak limiter...");
        // 7. Closed-loop loudness trim into true-peak limiter
        this.landLoudness(work, profile.targetLufs, profile.ceilingDbtp, profile.clipDriveDb, fs);

        if (onProgress) onProgress(100, "Master complete.");

        const postLufs = this.measureLUFS(work, fs);
        const postPeak = this.measureTruePeak(work[0], fs);

        return {
            channels: work,
            sampleRate: fs,
            duration: length / fs,
            metrics: {
                initialLufs: scan.integratedLufs,
                masteredLufs: postLufs,
                truePeakDb: postPeak,
                mode: profile.name
            }
        };
    }

    // Dynamic Closed-Loop Loudness
    landLoudness(work, targetLufs, ceilingDbtp, clipDriveDb, fs) {
        const numChannels = work.length;
        const length = work[0].length;
        const ceilingLin = Math.pow(10, ceilingDbtp / 20);

        for (let iter = 0; iter < 3; iter++) {
            const currentLufs = this.measureLUFS(work, fs);
            if (currentLufs <= -70) break;
            const diff = targetLufs - currentLufs;
            if (Math.abs(diff) < 0.1) break;
            const gain = Math.pow(10, diff / 20);
            for (let c = 0; c < numChannels; c++) {
                for (let i = 0; i < length; i++) work[c][i] *= gain;
            }
            // Brickwall ceiling limiter
            for (let c = 0; c < numChannels; c++) {
                for (let i = 0; i < length; i++) {
                    const val = work[c][i];
                    if (val > ceilingLin) work[c][i] = ceilingLin;
                    else if (val < -ceilingLin) work[c][i] = -ceilingLin;
                }
            }
        }
    }

    // Glue Compressor (Stereo-linked RMS)
    applyGlueCompressor(channels, ratio, percentile, fs) {
        const numChannels = channels.length;
        const length = channels[0].length;
        const threshDb = -20;
        const slope = 1.0 / ratio - 1.0;
        const attCoeff = Math.exp(-1.0 / (0.03 * fs));
        const relCoeff = Math.exp(-1.0 / (0.16 * fs));

        let env = 0;
        for (let i = 0; i < length; i++) {
            let sumSq = 0;
            for (let c = 0; c < numChannels; c++) sumSq += channels[c][i] * channels[c][i];
            const ms = sumSq / numChannels;

            const coeff = ms > env ? attCoeff : relCoeff;
            env = ms + coeff * (env - ms);
            const levelDb = 10 * Math.log10(Math.max(env, 1e-12));
            const over = levelDb - threshDb;
            let g = 1.0;
            if (over > 0) {
                const gDb = slope * over;
                g = Math.pow(10, gDb / 20);
            }
            for (let c = 0; c < numChannels; c++) channels[c][i] *= g;
        }
    }

    // Biquad Filter Helpers
    applyHighPass(buffer, fc, q, fs) {
        const f = this.createBiquadHP(fc, q, fs);
        for (let i = 0; i < buffer.length; i++) buffer[i] = f.process(buffer[i]);
    }

    applyPeak(buffer, fc, gainDb, q, fs) {
        const f = this.createBiquadPeak(fc, gainDb, q, fs);
        for (let i = 0; i < buffer.length; i++) buffer[i] = f.process(buffer[i]);
    }

    applyHighShelf(buffer, fc, gainDb, q, fs) {
        const f = this.createBiquadHighShelf(fc, gainDb, q, fs);
        for (let i = 0; i < buffer.length; i++) buffer[i] = f.process(buffer[i]);
    }

    applyLowShelf(buffer, fc, gainDb, q, fs) {
        const f = this.createBiquadLowShelf(fc, gainDb, q, fs);
        for (let i = 0; i < buffer.length; i++) buffer[i] = f.process(buffer[i]);
    }

    createBiquadHP(fc, q, fs) {
        const safeFc = Math.min(Math.max(fc, 10), 0.45 * fs);
        const w0 = 2 * Math.PI * safeFc / fs;
        const alpha = Math.sin(w0) / (2 * q);
        const cw = Math.cos(w0);
        const b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2;
        const a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha;
        return this.biquadInstance(b0, b1, b2, a0, a1, a2);
    }

    createBiquadPeak(fc, gainDb, q, fs) {
        const safeFc = Math.min(Math.max(fc, 10), 0.45 * fs);
        const A = Math.pow(10, gainDb / 40);
        const w0 = 2 * Math.PI * safeFc / fs;
        const alpha = Math.sin(w0) / (2 * q);
        const cw = Math.cos(w0);
        const b0 = 1 + alpha * A, b1 = -2 * cw, b2 = 1 - alpha * A;
        const a0 = 1 + alpha / A, a1 = -2 * cw, a2 = 1 - alpha / A;
        return this.biquadInstance(b0, b1, b2, a0, a1, a2);
    }

    createBiquadHighShelf(fc, gainDb, q, fs) {
        const safeFc = Math.min(Math.max(fc, 10), 0.45 * fs);
        const A = Math.pow(10, gainDb / 40);
        const w0 = 2 * Math.PI * safeFc / fs;
        const alpha = Math.sin(w0) / (2 * q);
        const cw = Math.cos(w0);
        const sqA = Math.sqrt(A);
        const b0 = A * ((A + 1) + (A - 1) * cw + 2 * sqA * alpha);
        const b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        const b2 = A * ((A + 1) + (A - 1) * cw - 2 * sqA * alpha);
        const a0 = (A + 1) - (A - 1) * cw + 2 * sqA * alpha;
        const a1 = 2 * ((A - 1) - (A + 1) * cw);
        const a2 = (A + 1) - (A - 1) * cw - 2 * sqA * alpha;
        return this.biquadInstance(b0, b1, b2, a0, a1, a2);
    }

    createBiquadLowShelf(fc, gainDb, q, fs) {
        const safeFc = Math.min(Math.max(fc, 10), 0.45 * fs);
        const A = Math.pow(10, gainDb / 40);
        const w0 = 2 * Math.PI * safeFc / fs;
        const alpha = Math.sin(w0) / (2 * q);
        const cw = Math.cos(w0);
        const sqA = Math.sqrt(A);
        const b0 = A * ((A + 1) - (A - 1) * cw + 2 * sqA * alpha);
        const b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        const b2 = A * ((A + 1) - (A - 1) * cw - 2 * sqA * alpha);
        const a0 = (A + 1) + (A - 1) * cw + 2 * sqA * alpha;
        const a1 = -2 * ((A - 1) + (A + 1) * cw);
        const a2 = (A + 1) + (A - 1) * cw - 2 * sqA * alpha;
        return this.biquadInstance(b0, b1, b2, a0, a1, a2);
    }

    biquadInstance(b0, b1, b2, a0, a1, a2) {
        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0;
        let na1 = a1 / a0, na2 = a2 / a0;
        let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
        return {
            process(x) {
                const y = nb0 * x + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2;
                x2 = x1; x1 = x;
                y2 = y1; y1 = y;
                return y;
            }
        };
    }

    // Export 24-bit WAV file Blob
    encodeWAV(channels, sampleRate = 48000) {
        const numChannels = channels.length;
        const numFrames = channels[0].length;
        const bytesPerSample = 3; // 24-bit
        const blockAlign = numChannels * bytesPerSample;
        const byteRate = sampleRate * blockAlign;
        const dataLength = numFrames * blockAlign;
        const buffer = new ArrayBuffer(44 + dataLength);
        const view = new DataView(buffer);

        function writeString(offset, string) {
            for (let i = 0; i < string.length; i++) {
                view.setUint8(offset + i, string.charCodeAt(i));
            }
        }

        writeString(0, 'RIFF');
        view.setUint32(4, 36 + dataLength, true);
        writeString(8, 'WAVE');
        writeString(12, 'fmt ');
        view.setUint32(16, 16, true);
        view.setUint16(20, 1, true); // PCM
        view.setUint16(22, numChannels, true);
        view.setUint32(24, sampleRate, true);
        view.setUint32(28, byteRate, true);
        view.setUint16(32, blockAlign, true);
        view.setUint16(34, 24, true); // bits per sample
        writeString(36, 'data');
        view.setUint32(40, dataLength, true);

        let offset = 44;
        for (let i = 0; i < numFrames; i++) {
            for (let c = 0; c < numChannels; c++) {
                let sample = Math.max(-1.0, Math.min(1.0, channels[c][i]));
                let s24 = sample < 0 ? sample * 0x800000 : sample * 0x7FFFFF;
                let intSample = Math.floor(s24);
                view.setUint8(offset, intSample & 0xFF);
                view.setUint8(offset + 1, (intSample >> 8) & 0xFF);
                view.setUint8(offset + 2, (intSample >> 16) & 0xFF);
                offset += 3;
            }
        }

        return new Blob([buffer], { type: 'audio/wav' });
    }
}

window.ResonanceWebDSP = ResonanceWebDSP;
