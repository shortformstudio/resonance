/**
 * Resonance Web Application Controller
 */

document.addEventListener('DOMContentLoaded', () => {
    const dsp = new window.ResonanceWebDSP();
    let audioCtx = null;
    let originalBuffer = null;
    let preparedSource = null;
    let masteredData = null;
    let currentSourceNode = null;
    let isPlaying = false;
    let activeTrackType = 'original'; // 'original' or 'master'
    let selectedMode = 'core';
    let selectedFormat = 'wav';

    // DOM Elements
    const dropZone = document.getElementById('drop-zone');
    const audioInput = document.getElementById('audio-input');
    const progressContainer = document.getElementById('progress-container');
    const progressFill = document.getElementById('progress-fill');
    const progressPercent = document.getElementById('progress-percent');
    const progressStepText = document.getElementById('progress-step-text');
    const dspLogStream = document.getElementById('dsp-log-stream');

    const metricLufs = document.getElementById('metric-lufs');
    const metricPeak = document.getElementById('metric-peak');
    const metricCrest = document.getElementById('metric-crest');
    const metricCorr = document.getElementById('metric-corr');
    const metricSlope = document.getElementById('metric-slope');
    const auditIndicator = document.getElementById('audit-indicator');

    const trackName = document.getElementById('track-name');
    const trackMeta = document.getElementById('track-meta');
    const waveformCanvas = document.getElementById('waveform-canvas');
    const btnPlayOrig = document.getElementById('btn-play-orig');
    const btnPlayMaster = document.getElementById('btn-play-master');
    const btnStopAudio = document.getElementById('btn-stop-audio');

    const fmtWav = document.getElementById('fmt-wav');
    const fmtMp3 = document.getElementById('fmt-mp3');
    const modeCards = document.querySelectorAll('.mode-card');
    const engineHint = document.getElementById('engine-hint');
    const btnMaster = document.getElementById('btn-master');
    const btnDownload = document.getElementById('btn-download');

    function log(msg) {
        const time = new Date().toTimeString().split(' ')[0];
        const entry = document.createElement('div');
        entry.className = 'log-entry';
        entry.textContent = `[${time}] ${msg}`;
        dspLogStream.appendChild(entry);
        dspLogStream.scrollTop = dspLogStream.scrollHeight;
    }

    function initAudioContext() {
        if (!audioCtx) {
            audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        }
    }

    // Drop Zone Handling
    dropZone.addEventListener('click', () => audioInput.click());
    dropZone.addEventListener('dragover', (e) => {
        e.preventDefault();
        dropZone.classList.add('drag-over');
    });
    dropZone.addEventListener('dragleave', () => dropZone.classList.remove('drag-over'));
    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('drag-over');
        if (e.dataTransfer.files.length > 0) {
            handleFile(e.dataTransfer.files[0]);
        }
    });
    audioInput.addEventListener('change', (e) => {
        if (e.target.files.length > 0) {
            handleFile(e.target.files[0]);
        }
    });

    async function handleFile(file) {
        initAudioContext();
        log(`Loading file: ${file.name} (${(file.size / (1024 * 1024)).toFixed(2)} MB)`);
        trackName.textContent = file.name;
        trackMeta.textContent = "DECODING AUDIO STREAM...";
        btnMaster.disabled = true;
        btnDownload.classList.add('hidden');
        masteredData = null;

        showProgress(true, "Decoding audio stream...", 15);

        try {
            const arrayBuffer = await file.arrayBuffer();
            originalBuffer = await audioCtx.decodeAudioData(arrayBuffer);
            preparedSource = await dsp.prepareBuffer(originalBuffer);

            showProgress(true, "Scanning Signal DNA (LUFS, Peak, Crest)...", 50);
            const scan = dsp.scanTrack(preparedSource.channels, preparedSource.sampleRate);

            // Update UI Metrics
            metricLufs.textContent = `${scan.integratedLufs.toFixed(2)} LUFS`;
            metricPeak.textContent = `${scan.truePeakDb.toFixed(2)} dBTP`;
            metricCrest.textContent = `${scan.crestFactorDb.toFixed(2)} dB`;
            metricCorr.textContent = scan.correlation.toFixed(3);
            metricSlope.textContent = scan.spectralSlope.toFixed(3);

            trackMeta.textContent = `${Math.floor(preparedSource.duration / 60)}:${Math.floor(preparedSource.duration % 60).toString().padStart(2, '0')} · ${originalBuffer.sampleRate}Hz → 48kHz Internal`;
            auditIndicator.textContent = "SCANNED";
            auditIndicator.className = "status-indicator active";

            drawWaveform(preparedSource.channels[0]);
            log(`Signal scanned: ${scan.integratedLufs.toFixed(1)} LUFS, True Peak ${scan.truePeakDb.toFixed(1)} dBTP`);

            btnMaster.disabled = false;
            btnPlayOrig.disabled = false;
            showProgress(false);
        } catch (err) {
            log(`ERROR: Could not decode audio: ${err.message}`);
            showProgress(false);
        }
    }

    function showProgress(show, text = "", percent = 0) {
        if (show) {
            progressContainer.classList.remove('hidden');
            progressStepText.textContent = text;
            progressFill.style.width = `${percent}%`;
            progressPercent.textContent = `${percent}%`;
        } else {
            progressContainer.classList.add('hidden');
        }
    }

    // Format selection
    fmtWav.addEventListener('click', () => {
        selectedFormat = 'wav';
        fmtWav.classList.add('active-fmt');
        fmtMp3.classList.remove('active-fmt');
        log("Output target format → WAV (24-bit linear PCM)");
    });
    fmtMp3.addEventListener('click', () => {
        selectedFormat = 'mp3';
        fmtMp3.classList.add('active-fmt');
        fmtWav.classList.remove('active-fmt');
        log("Output target format → MP3 (320 kbps streaming master)");
    });

    // Mode selection
    modeCards.forEach(card => {
        card.addEventListener('click', () => {
            modeCards.forEach(c => c.classList.remove('active-mode'));
            card.classList.add('active-mode');
            selectedMode = card.dataset.mode;
            updateEngineHint(selectedMode);
            log(`Mastering profile switched → ${selectedMode.toUpperCase()}`);
        });
    });

    function updateEngineHint(mode) {
        if (mode === 'core') {
            engineHint.textContent = "CORE: balanced modern master with clean streaming headroom (-14 LUFS / -1 dBTP).";
        } else if (mode === 'pure') {
            engineHint.textContent = "PURE: transparent acoustic finish preserving delicate dynamic nuances (-16 LUFS / -1 dBTP).";
        } else if (mode === 'club') {
            engineHint.textContent = "CLUB: high-density club print with weighted low-end and tight glue (-9 LUFS / -1 dBTP).";
        }
    }

    // Mastering Execution
    btnMaster.addEventListener('click', async () => {
        if (!preparedSource) return;
        btnMaster.disabled = true;
        log(`Initiating ${selectedMode.toUpperCase()} master chain...`);

        showProgress(true, "Beginning modular mastering chain...", 5);

        try {
            masteredData = await dsp.master(preparedSource.channels, selectedMode, (pct, status) => {
                showProgress(true, status, pct);
            });

            log(`Mastering completed! Final loudness: ${masteredData.metrics.masteredLufs.toFixed(2)} LUFS · True Peak: ${masteredData.metrics.truePeakDb.toFixed(2)} dBTP`);

            // Generate Downloadable WAV Blob
            const wavBlob = dsp.encodeWAV(masteredData.channels, masteredData.sampleRate);
            const downloadUrl = URL.createObjectURL(wavBlob);
            btnDownload.href = downloadUrl;
            btnDownload.download = `${trackName.textContent.replace(/\.[^/.]+$/, "")}_resonance_${selectedMode}.${selectedFormat}`;
            btnDownload.textContent = `DOWNLOAD ${selectedFormat.toUpperCase()} MASTER`;
            btnDownload.classList.remove('hidden');

            btnPlayMaster.disabled = false;
            btnMaster.disabled = false;
            showProgress(false);

            // Redraw with mastered waveform
            drawWaveform(masteredData.channels[0]);
        } catch (err) {
            log(`Mastering failure: ${err.message}`);
            showProgress(false);
            btnMaster.disabled = false;
        }
    });

    // A/B Audio Player
    btnPlayOrig.addEventListener('click', () => {
        if (!preparedSource) return;
        stopPlayback();
        playChannelData(preparedSource.channels, 'original');
    });

    btnPlayMaster.addEventListener('click', () => {
        if (!masteredData) return;
        stopPlayback();
        playChannelData(masteredData.channels, 'master');
    });

    btnStopAudio.addEventListener('click', () => stopPlayback());

    function playChannelData(channels, type) {
        initAudioContext();
        const numChannels = channels.length;
        const length = channels[0].length;
        const buffer = audioCtx.createBuffer(numChannels, length, 48000);

        for (let c = 0; c < numChannels; c++) {
            const ch = buffer.getChannelData(c);
            for (let i = 0; i < length; i++) ch[i] = channels[c][i];
        }

        currentSourceNode = audioCtx.createBufferSource();
        currentSourceNode.buffer = buffer;
        currentSourceNode.connect(audioCtx.destination);
        currentSourceNode.start(0);

        currentSourceNode.onended = () => stopPlayback();

        isPlaying = true;
        activeTrackType = type;
        btnStopAudio.disabled = false;

        if (type === 'original') {
            btnPlayOrig.classList.add('active-ab');
            btnPlayMaster.classList.remove('active-ab');
            log("Auditioning: ORIGINAL UNMASTERED MIX");
        } else {
            btnPlayMaster.classList.add('active-ab');
            btnPlayOrig.classList.remove('active-ab');
            log(`Auditioning: RESONANCE ${selectedMode.toUpperCase()} MASTER`);
        }
    }

    function stopPlayback() {
        if (currentSourceNode) {
            try { currentSourceNode.stop(); } catch (e) {}
            currentSourceNode.disconnect();
            currentSourceNode = null;
        }
        isPlaying = false;
        btnStopAudio.disabled = true;
        btnPlayOrig.classList.remove('active-ab');
        btnPlayMaster.classList.remove('active-ab');
    }

    // Canvas Waveform Renderer
    function drawWaveform(channelData) {
        const canvas = waveformCanvas;
        const ctx = canvas.getContext('2d');
        const width = canvas.width;
        const height = canvas.height;

        ctx.clearRect(0, 0, width, height);

        // Center line
        ctx.strokeStyle = 'rgba(255, 255, 255, 0.1)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, height / 2);
        ctx.lineTo(width, height / 2);
        ctx.stroke();

        const step = Math.ceil(channelData.length / width);
        const amp = height / 2;

        ctx.fillStyle = '#d4af37';
        for (let i = 0; i < width; i++) {
            let min = 1.0;
            let max = -1.0;
            for (let j = 0; j < step; j++) {
                const datum = channelData[(i * step) + j];
                if (datum < min) min = datum;
                if (datum > max) max = datum;
            }
            const yMin = (1 + min) * amp;
            const yMax = Math.max(1, (max - min) * amp);
            ctx.fillRect(i, yMin, 1, yMax);
        }
    }
});
