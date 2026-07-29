const logEl = document.getElementById('status-log');
const lufsEl = document.getElementById('lufs-value');
const spectralEl = document.getElementById('spectral-value');
const widthEl = document.getElementById('width-value');
const btnExecute = document.getElementById('btn-execute');
const historyListEl = document.getElementById('session-history');

const dropZone = document.getElementById('drop-zone');
const btnAudioFile = document.getElementById('btn-audio-file');
const loadingBarContainer = document.getElementById('loading-bar-container');
const loadingBar = document.getElementById('loading-bar');
const trackMetadata = document.getElementById('track-metadata');
const metaTitle = document.getElementById('meta-title');
const metaDuration = document.getElementById('meta-duration');
const metaFormat = document.getElementById('meta-format');
const metaVolume = document.getElementById('meta-volume');
const perspectiveText = document.getElementById('perspective-text');
const suggestionsArea = document.getElementById('suggestions-area');

// Chat + batch elements
const chatStream = document.getElementById('chat-stream');
const assistantStatus = document.getElementById('assistant-status');
const batchQueueEl = document.getElementById('batch-queue');
const batchListEl = document.getElementById('batch-list');
const batchProgressLabel = document.getElementById('batch-progress-label');
const btnBatchMaster = document.getElementById('btn-batch-master');

// DNA Stats Elements
const dnaLufs = document.getElementById('dna-lufs');
const dnaSlope = document.getElementById('dna-slope');
const dnaWidth = document.getElementById('dna-width');
const loudComment = document.getElementById('audit-loudness-comment');
const spectralComment = document.getElementById('audit-spectral-comment');
const stereoComment = document.getElementById('audit-stereo-comment');
const proposedChain = document.getElementById('proposed-chain');

let currentFilePath = null;
let currentAnalysis = null;
let masterHistory = [];

// Batch state — each entry is a track with its own analysis + master output.
let batchTracks = [];   // { path, name, status, analysis, outputPath }
let isBatchRunning = false;

// --- Mastering Assistant chat (all advice appears here, above the analysis) ---
const CHAT_TONE_ICON = {
    greeting: '◉', insight: '✳', good: '✓', caution: '⚠', plan: '➤', working: '⟳', done: '✓',
};

function setAssistantStatus(text) {
    if (assistantStatus) assistantStatus.textContent = text;
}

/** Append one chat bubble. Markdown-lite: **bold** becomes <strong>. */
function addChatBubble(text, tone = 'insight', title = null) {
    if (!chatStream) return;
    const bubble = document.createElement('div');
    bubble.className = `chat-bubble ${tone}`;
    const safe = escapeText(text).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    const icon = CHAT_TONE_ICON[tone] || '✳';
    bubble.innerHTML = `
        ${title ? `<div class="bubble-title"><span class="bubble-icon">${icon}</span>${escapeText(title)}</div>` : ''}
        <p>${safe}</p>`;
    chatStream.appendChild(bubble);
    chatStream.scrollTop = chatStream.scrollHeight;
    return bubble;
}

function clearChat() {
    if (chatStream) chatStream.innerHTML = '';
}

function escapeText(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Render the assistant's conversational read from an analysis result. */
function renderAssistantChat(analysis, trackName) {
    clearChat();
    if (trackName) addChatBubble(`on it — reading **${trackName}** now.`, 'greeting');
    const chat = (analysis && analysis.chat) || [];
    if (chat.length) {
        chat.forEach(b => addChatBubble(b.text, b.tone || 'insight', b.title));
    } else if (analysis && analysis.perspective) {
        // Fallback for older engine output.
        addChatBubble(analysis.perspective, 'insight', "here's the read");
    }
    setAssistantStatus('analysis ready · your call');
}

// --- History Logic ---
function updateHistoryUI() {
    if (masterHistory.length === 0) {
        historyListEl.innerHTML = '<div class="history-placeholder">No recent masters.</div>';
        return;
    }
    
    historyListEl.innerHTML = '';
    masterHistory.forEach(item => {
        const div = document.createElement('div');
        div.className = 'history-item';
        div.textContent = item.name;
        div.title = `Click to reveal: ${item.path}`;
        div.onclick = () => window.api.showItemInFolder(item.path);
        historyListEl.appendChild(div);
    });
}

function addToHistory(name, path) {
    masterHistory.unshift({ name, path });
    if (masterHistory.length > 5) masterHistory.pop();
    updateHistoryUI();
}

// Three.js Visualization Engine
let scene, camera, renderer, bars = [], grid;
const vizContainer = document.getElementById('three-canvas-container');

function initThree() {
    scene = new THREE.Scene();
    camera = new THREE.PerspectiveCamera(45, vizContainer.offsetWidth / vizContainer.offsetHeight, 0.1, 1000);
    camera.position.set(0, 15, 120);
    camera.lookAt(0, 0, 0);

    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setSize(vizContainer.offsetWidth, vizContainer.offsetHeight);
    renderer.setPixelRatio(window.devicePixelRatio);
    vizContainer.appendChild(renderer.domElement);

    const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
    scene.add(ambientLight);

    const pointLight = new THREE.PointLight(0xD4AF37, 1);
    pointLight.position.set(0, 50, 50);
    scene.add(pointLight);

    const size = 200;
    const divisions = 20;
    grid = new THREE.GridHelper(size, divisions, 0xEEEEEE, 0xF5F5F5);
    grid.position.y = -35;
    scene.add(grid);

    animate();
}

function animate() {
    requestAnimationFrame(animate);
    if (scene) {
        scene.rotation.y = Math.sin(Date.now() * 0.0005) * 0.05;
    }
    renderer.render(scene, camera);
}

function updateWaveform(waveData) {
    if (!waveData || !waveData.data) return;
    
    bars.forEach(bar => {
        if (bar.geometry) bar.geometry.dispose();
        if (bar.material) bar.material.dispose();
        scene.remove(bar);
    });
    bars = [];

    const data = waveData.data;
    const redlines = waveData.redlines || [];
    const width = 180;
    const spacing = width / data.length;

    data.forEach((val, i) => {
        const height = val * 80 + 1; 
        const geometry = new THREE.CylinderGeometry(spacing * 0.4, spacing * 0.4, height, 8);
        const isRed = redlines[i];
        const color = isRed ? 0xCC0000 : 0xB8860B; 
        
        const material = new THREE.MeshPhongMaterial({ 
            color: color,
            emissive: color,
            emissiveIntensity: isRed ? 0.4 : 0.05,
            shininess: 100,
            transparent: true,
            opacity: 1.0
        });
        
        const bar = new THREE.Mesh(geometry, material);
        bar.position.x = (i * spacing) - (width / 2);
        bar.position.y = (height / 2) - 35;
        scene.add(bar);
        bars.push(bar);
    });

    const headGeom = new THREE.PlaneGeometry(0.5, 100);
    const headMat = new THREE.MeshBasicMaterial({ color: 0x000000, transparent: true, opacity: 0.1 });
    const head = new THREE.Mesh(headGeom, headMat);
    head.position.z = 5;
    head.position.y = 15;
    scene.add(head);
    
    let headPos = -width/2;
    function moveHead() {
        headPos += 0.5;
        if (headPos > width/2) headPos = -width/2;
        head.position.x = headPos;
        requestAnimationFrame(moveHead);
    }
    moveHead();
}

function addLog(message) {
    const now = new Date();
    const time = now.toLocaleTimeString([], { hour12: false });
    const entry = document.createElement('div');
    entry.className = 'log-entry';
    entry.textContent = `[${time}] ${message}`;
    logEl.appendChild(entry);
    logEl.scrollTop = logEl.scrollHeight;
}

function updateProposedCompensation() {
    if (!currentAnalysis) return;
    
    proposedChain.innerHTML = '';
    const metrics = currentAnalysis.metrics;
    
    const chain = [
        { name: 'Sub-Sonic Control', detail: metrics.spectral_slope > 1.4 ? '35Hz HPF' : '30Hz HPF' },
        { name: 'Organic Heat', detail: metrics.integrated_lufs < -18 ? '+1.5dB Drive' : '+1.0dB Drive' },
        { name: 'Spectral Balancing', detail: metrics.spectral_slope > 1.4 ? 'Mud Unmasking' : 'Air Excitation' },
        { name: 'Spatial Width', detail: metrics.correlation > 0.7 ? 'Phase-Safe Expansion' : 'Image Focus' },
        { name: 'Program Glue', detail: metrics.integrated_lufs > -12 ? '1.2:1 Comp' : '1.5:1 Comp' },
        { name: 'Final Offset', detail: `${(-14.0 - metrics.integrated_lufs).toFixed(1)}dB Gain` }
    ];

    chain.forEach(item => {
        const div = document.createElement('div');
        div.className = 'audit-item';
        div.innerHTML = `<div class="metric-line">${item.name}: <span>${item.detail}</span></div>`;
        proposedChain.appendChild(div);
    });
}

function generateEngineerComments(metrics) {
    const lufs = metrics.integrated_lufs;
    const slope = metrics.spectral_slope;
    const corr = metrics.correlation;

    if (lufs < -20) loudComment.textContent = "Signal is extremamente anemic. We're missing the saturation 'floor'—ready for a significant thermal lift.";
    else if (lufs > -10) loudComment.textContent = "Signal is aggressively hot. We're trading dynamic impact for raw RMS density.";
    else loudComment.textContent = "Healthy gain structure. Perfect foundation for transparent finalization.";

    if (slope > 1.6) spectralComment.textContent = "Heavy low-mid accumulation. It's creating a 'sonic fog' that masks upper-harmonic detail.";
    else if (slope < 1.1) spectralComment.textContent = "Top-heavy bias. Mix feels brittle and lacks mechanical weight in the 200Hz chest region.";
    else spectralComment.textContent = "Elegant spectral distribution. Sitting in a professional pink-noise pocket.";

    if (corr < 0.4) stereoComment.textContent = "Critical phase incoherence. Image collapse likely in mono. Tightening center focus.";
    else stereoComment.textContent = "Solid stereo integrity. Field is wide but focused and phase-coherent.";
}

async function runAnalysis() {
    addLog('Commencing hybrid signal audit...');
    btnExecute.disabled = true;

    try {
        const result = await window.api.runEngine(['analyze', currentFilePath]);
        if (result.error) throw new Error(result.error);

        currentAnalysis = result;
        perspectiveText.textContent = result.perspective;

        // Route the assistant's full read into the chat bubbles above analysis.
        renderAssistantChat(result, result.title);

        paintAnalysis(result);

        addLog('DNA mapped. Hybrid compensation plan initialized.');
        btnExecute.disabled = false;
    } catch (err) {
        console.error('Analysis Error:', err);
        addLog(`CRITICAL: ${err.message}`);
        addChatBubble(`hmm, i couldn't read that one — ${err.message}. try a wav or flac and i'll take another pass.`, 'caution', 'hit a snag');
    }
}

/** Paint metrics, audit comments, metadata, and waveform from an analysis result. */
function paintAnalysis(result) {
    if (result.metrics) {
        dnaLufs.textContent = `${result.metrics.integrated_lufs} LUFS`;
        dnaSlope.textContent = result.metrics.spectral_slope;
        dnaWidth.textContent = result.metrics.correlation;

        generateEngineerComments(result.metrics);
        updateProposedCompensation();

        lufsEl.textContent = result.metrics.integrated_lufs;
        spectralEl.textContent = result.metrics.spectral_slope;
        widthEl.textContent = result.metrics.correlation;

        metaTitle.textContent = result.title;
        metaDuration.textContent = result.duration;
        metaFormat.textContent = result.format;
        metaVolume.textContent = `${result.metrics.true_peak_db} dB`;
        trackMetadata.classList.remove('hidden');
    }

    if (result.waveform && result.waveform.data) {
        updateWaveform(result.waveform);
    }
}

async function handleFileSelection(filePath) {
    currentFilePath = filePath;
    addLog(`Target: ${filePath.split(/[\\/]/).pop()}`);
    
    loadingBarContainer.classList.remove('hidden');
    trackMetadata.classList.add('hidden');
    loadingBar.style.width = '0%';
    perspectiveText.textContent = "Auditing signal DNA...";
    
    await runAnalysis();
    loadingBarContainer.classList.add('hidden');
}

// IPC Listeners
window.api.onProgress((percent) => {
    loadingBar.style.width = `${percent}%`;
});

// UI Event Listeners
dropZone.addEventListener('dragover', (e) => { e.preventDefault(); dropZone.classList.add('drag-over'); });
dropZone.addEventListener('dragleave', () => { dropZone.classList.remove('drag-over'); });
dropZone.addEventListener('drop', async (e) => {
    e.preventDefault();
    dropZone.classList.remove('drag-over');
    const files = Array.from(e.dataTransfer.files).filter(f => f.path);
    if (files.length === 0) return;
    if (files.length === 1) {
        exitBatchMode();
        handleFileSelection(files[0].path);
    } else {
        loadBatch(files.map(f => f.path));
    }
});

btnAudioFile.addEventListener('click', async () => {
    const filePaths = await window.api.selectFiles();
    if (!filePaths || filePaths.length === 0) return;
    if (filePaths.length === 1) {
        exitBatchMode();
        handleFileSelection(filePaths[0]);
    } else {
        loadBatch(filePaths);
    }
});

// ================= BATCH MODE =================
// Each track keeps its own analysis, so every master is tailored to that track.

function baseNameOf(p) { return p.split(/[\\/]/).pop(); }

function loadBatch(paths) {
    batchTracks = paths.map(p => ({
        path: p,
        name: baseNameOf(p),
        status: 'queued',      // queued | analyzing | ready | mastering | done | error
        analysis: null,
        outputPath: null,
    }));
    batchQueueEl.classList.remove('hidden');
    btnBatchMaster.classList.remove('hidden');
    btnExecute.classList.add('hidden');
    renderBatchList();
    addLog(`Batch loaded: ${batchTracks.length} tracks.`);
    clearChat();
    addChatBubble(
        `loaded **${batchTracks.length} tracks**. i'll analyze each one individually and give every track its own custom master — no blanket presets. hit **master all** when you're ready, or tap any track to see its read.`,
        'greeting', 'batch ready'
    );
    setAssistantStatus(`${batchTracks.length} tracks queued`);
    // Pre-analyze all tracks so the user sees per-track reads before committing.
    analyzeBatchSequentially();
}

function exitBatchMode() {
    batchTracks = [];
    batchQueueEl.classList.add('hidden');
    btnBatchMaster.classList.add('hidden');
    btnExecute.classList.remove('hidden');
}

const BATCH_STATUS_LABEL = {
    queued: 'queued', analyzing: 'analyzing…', ready: 'ready',
    mastering: 'mastering…', done: 'done ✓', error: 'error',
};

function renderBatchList() {
    if (!batchListEl) return;
    const doneCount = batchTracks.filter(t => t.status === 'done').length;
    batchProgressLabel.textContent = `${doneCount} / ${batchTracks.length}`;
    batchListEl.innerHTML = '';
    batchTracks.forEach((track, index) => {
        const row = document.createElement('div');
        row.className = `batch-item ${track.status}`;
        const metricPreview = track.analysis
            ? `${track.analysis.metrics.integrated_lufs} LUFS · slope ${track.analysis.metrics.spectral_slope}`
            : '—';
        row.innerHTML = `
            <span class="batch-item-name" title="${escapeText(track.path)}">${escapeText(track.name)}</span>
            <span class="batch-item-metrics">${metricPreview}</span>
            <span class="batch-item-status ${track.status}">${BATCH_STATUS_LABEL[track.status] || track.status}</span>`;
        row.onclick = () => {
            if (track.analysis) showTrackRead(track);
            if (track.outputPath && track.status === 'done') window.api.showItemInFolder(track.outputPath);
        };
        batchListEl.appendChild(row);
    });
}

function showTrackRead(track) {
    currentAnalysis = track.analysis;
    currentFilePath = track.path;
    // Repaint metrics + audit for the tapped track.
    paintAnalysis(track.analysis);
    renderAssistantChat(track.analysis, track.name);
}

async function analyzeBatchSequentially() {
    for (const track of batchTracks) {
        if (track.analysis) continue;
        track.status = 'analyzing';
        renderBatchList();
        setAssistantStatus(`analyzing ${track.name}…`);
        try {
            const result = await window.api.runEngine(['analyze', track.path]);
            if (result.error) throw new Error(result.error);
            track.analysis = result;
            track.status = 'ready';
        } catch (err) {
            track.status = 'error';
            addLog(`Analysis failed for ${track.name}: ${err.message}`);
        }
        renderBatchList();
    }
    const readyCount = batchTracks.filter(t => t.status === 'ready').length;
    setAssistantStatus(`${readyCount} tracks analyzed`);
    addChatBubble(
        `done analyzing — each track's read is saved. tap any one to see its details. when you hit **master all**, i'll process them one by one, each with its own tailored chain.`,
        'plan', 'all analyzed'
    );
    // Show the first track's read by default.
    const first = batchTracks.find(t => t.analysis);
    if (first) showTrackRead(first);
}

async function runBatchMaster() {
    if (isBatchRunning) return;
    isBatchRunning = true;
    btnBatchMaster.disabled = true;
    addChatBubble(`starting the batch. i'll tailor each master to its own analysis — the loud ones get eased off, the dark ones get lifted. sit back.`, 'working', 'mastering all');

    for (const track of batchTracks) {
        if (!track.analysis) continue;
        track.status = 'mastering';
        renderBatchList();
        setAssistantStatus(`mastering ${track.name}…`);
        try {
            const baseName = track.name.replace(/\.[^/.]+$/, '');
            // Engine forces export into ~/Documents/Sound; we only supply the name.
            const outputPath = `UNIFIED_MASTER_${baseName}.wav`;
            const metricsJson = JSON.stringify(track.analysis.metrics);
            const res = await window.api.runEngine(['master', track.path, outputPath, metricsJson]);
            track.outputPath = (res && res.output_path) || outputPath;
            track.abPath = res && res.ab_sample_path;
            track.status = 'done';
            addToHistory(`MASTER: ${baseName}`, track.outputPath);
        } catch (err) {
            track.status = 'error';
            addLog(`Master failed for ${track.name}: ${err.message}`);
        }
        renderBatchList();
    }

    isBatchRunning = false;
    btnBatchMaster.disabled = false;
    const doneCount = batchTracks.filter(t => t.status === 'done').length;
    setAssistantStatus(`${doneCount} tracks mastered`);
    addChatBubble(
        `batch complete — **${doneCount} of ${batchTracks.length}** mastered, each with its own treatment. everything's in your **Sound** folder, and each track got a 30-second before/after clip in **Sound › AB sampling** (flips every 5s). tap any track to reveal it. nice work.`,
        'done', 'all done'
    );
}

if (btnBatchMaster) btnBatchMaster.addEventListener('click', runBatchMaster);

btnExecute.addEventListener('click', async () => {
    if (!currentAnalysis) return;

    addLog(`Initiating UNIFIED processing sequence...`);
    btnExecute.disabled = true;

    try {
        const fileName = currentFilePath.split(/[\\/]/).pop();
        const baseName = fileName.replace(/\.[^/.]+$/, "");
        // The engine forces all exports into ~/Documents/Sound; we just name the file.
        const outputPath = `UNIFIED_MASTER_${baseName}.wav`;
        const metricsJson = JSON.stringify(currentAnalysis.metrics);

        addLog(`Applying Hybrid Analog Compensation...`);
        addChatBubble(`printing your master now — tailored to this track's read. one sec.`, 'working', 'mastering');
        const res = await window.api.runEngine(['master', currentFilePath, outputPath, metricsJson]);

        const finalPath = (res && res.output_path) || outputPath;
        addToHistory(`MASTER: ${baseName}`, finalPath);
        addLog(`SEQUENCE COMPLETE. Exported to Documents/Sound.`);
        addChatBubble(`done — master's in your **Sound** folder, with an original reference beside it so you can a/b. trust your ears over the meters.`, 'done', 'ready to hear');
        if (res && res.ab_sample_path) {
            addChatBubble(`also dropped a **30-second a/b sample** in **Sound › AB sampling** — it flips between before and after every 5 seconds on the same passage, so the difference is easy to hear in context.`, 'plan', 'a/b sample ready');
        }
        window.api.showItemInFolder(finalPath);
        
    } catch (err) {
        addLog(`EXECUTION ERROR: ${err.message}`);
    } finally {
        btnExecute.disabled = false;
    }
});

// Custom Tooltip Logic
const tooltip = document.createElement('div');
tooltip.className = 'tooltip hidden';
document.body.appendChild(tooltip);

document.querySelectorAll('.metric-card').forEach(card => {
    card.addEventListener('mouseenter', (e) => {
        const text = card.getAttribute('data-tooltip');
        const [title, description] = text.split(': ');
        tooltip.innerHTML = `<span class="tooltip-title">${title}</span>${description}`;
        tooltip.classList.remove('hidden');
    });
    card.addEventListener('mousemove', (e) => {
        const x = e.clientX + 15, y = e.clientY + 15;
        const maxX = window.innerWidth - tooltip.offsetWidth - 20;
        const maxY = window.innerHeight - tooltip.offsetHeight - 20;
        tooltip.style.left = `${Math.min(x, maxX)}px`;
        tooltip.style.top = `${Math.min(y, maxY)}px`;
    });
    card.addEventListener('mouseleave', () => tooltip.classList.add('hidden'));
});

window.addEventListener('load', () => {
    initThree();
    updateHistoryUI();
});
window.addEventListener('resize', () => {
    if (camera && renderer) {
        camera.aspect = vizContainer.offsetWidth / vizContainer.offsetHeight;
        camera.updateProjectionMatrix();
        renderer.setSize(vizContainer.offsetWidth, vizContainer.offsetHeight);
    }
});
