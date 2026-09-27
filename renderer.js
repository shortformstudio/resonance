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
let batchTracks = [];   // { path, name, status, analysis, outputPath, mode }
let isBatchRunning = false;

// ================= ENGINE MODES =================
// Six engines, picked before print. Ids match engine_cli modes + meta.json.
const MODE_META = [
    { id: 'resonance_v2',     name: 'core',  target: '-14 balanced',   blurb: 'balanced modern master' },
    { id: 'clear',            name: 'pure',  target: '-14 transparent', blurb: 'transparent acoustic finish' },
    { id: 'unified_hybrid_v1', name: 'heat', target: '-14 vintage',    blurb: 'vintage hybrid warmth' },
    { id: 'club',             name: 'club',  target: '-8 loud',        blurb: 'loud club print' },
    { id: 'ivory',            name: 'ivory', target: '-14 piano',      blurb: 'gentle piano voicing' },
    { id: 'vox',              name: 'vox',   target: '-14 vocal',      blurb: 'forward vocal presence' },
];
let selectedMode = localStorage.getItem('resonanceEngine') || 'resonance_v2';
if (!MODE_META.some(m => m.id === selectedMode)) selectedMode = 'resonance_v2';

function modeName(id) {
    const m = MODE_META.find(m => m.id === id);
    return m ? m.name : id;
}

/** Suggested engine for the current read (★ badge). */
function getRecommendedMode(metrics) {
    if (!metrics) return 'resonance_v2';
    if (metrics.correlation < 0.6 || metrics.spectral_slope < 1.1) return 'clear';
    if (metrics.integrated_lufs > -9) return 'club';
    return 'resonance_v2';
}

/** Per-mode processing chain detail for the current read. */
function getChainForMode(modeId, metrics) {
    const m = metrics || {};
    const slope = m.spectral_slope, lufs = m.integrated_lufs, corr = m.correlation;
    const mud = (m.mud_center_hz != null && isFinite(m.mud_center_hz))
        ? `Mud Cut @ ${Math.round(m.mud_center_hz)}Hz` : 'Mud Cut';
    const wide = corr > 0.7 ? 'M/S Expansion' : (corr < 0.6 ? 'Sub Mono-Fold' : 'Image Hold');
    const glueSoft = lufs > -12 ? '1.2:1 Soft Knee' : '1.5:1 Soft Knee';
    const heatSoft = lufs < -18 ? '+1.5dB Drive' : '+1.0dB Drive';
    const hpfSoft = slope > 1.4 ? '35Hz HPF' : '30Hz HPF';
    const airSoft = slope > 1.4 ? mud : 'Air Excitation';
    switch (modeId) {
        case 'clear':
            return [['Sub-Sonic Control', '40Hz HPF ×2'], ['Organic Heat', 'no saturation'],
                    ['Spectral Balancing', '450Hz unmask · 12kHz air'], ['Spatial Width', 'Image Hold'],
                    ['Program Glue', '1.15:1 Transparent'], ['Final Offset', '→ -14.0 LUFS exact']];
        case 'unified_hybrid_v1':
            return [['Sub-Sonic Control', hpfSoft], ['Organic Heat', heatSoft],
                    ['Spectral Balancing', slope > 1.4 ? mud : 'Air Excitation'],
                    ['Spatial Width', corr < 0.6 ? 'Sub Mono-Fold' : 'Image Hold'],
                    ['Program Glue', glueSoft], ['Final Offset', '→ -14.0 LUFS exact']];
        case 'club':
            return [['Sub-Sonic Control', '30Hz HPF'], ['Organic Heat', '+2.5dB Drive'],
                    ['Spectral Balancing', slope > 1.4 ? mud : 'Air +4dB'],
                    ['Spatial Width', wide], ['Program Glue', '2.0:1 Club Glue'],
                    ['Final Offset', '→ -8.0 LUFS exact']];
        case 'ivory':
            return [['Sub-Sonic Control', '25Hz HPF'], ['Organic Heat', 'no saturation'],
                    ['Spectral Balancing', slope > 1.6 ? mud : 'Air +2dB'],
                    ['Spatial Width', 'Image Hold'], ['Program Glue', '1.15:1 Transparent'],
                    ['Final Offset', '→ -14.0 LUFS exact']];
        case 'vox':
            return [['Sub-Sonic Control', '80Hz HPF'], ['Organic Heat', '+1.0dB Drive'],
                    ['Spectral Balancing', '3kHz presence · 12kHz air'],
                    ['Spatial Width', 'Center Focus'], ['Program Glue', '1.3:1 Vocal Glue'],
                    ['Final Offset', '→ -14.0 LUFS exact']];
        default:
            return [['Sub-Sonic Control', hpfSoft], ['Organic Heat', heatSoft],
                    ['Spectral Balancing', airSoft], ['Spatial Width', wide],
                    ['Program Glue', glueSoft], ['Final Offset', '→ -14.0 LUFS exact']];
    }
}

function renderModeGrid() {
    const grid = document.getElementById('mode-grid');
    if (!grid) return;
    const suggested = currentAnalysis ? getRecommendedMode(currentAnalysis.metrics) : null;
    const map = currentPreviewMap();
    grid.innerHTML = '';
    MODE_META.forEach(meta => {
        const card = document.createElement('button');
        card.className = `mode-card${meta.id === selectedMode ? ' selected' : ''}`;
        let stateIcon = '<span class="mode-card-state">○</span>';
        if (playingPreviewMode === meta.id) stateIcon = '<span class="mode-card-state playing">❚❚</span>';
        else if (previewGenerating && previewProgressMode === meta.id) stateIcon = '<span class="mode-card-state">…</span>';
        else if (map[meta.id]) stateIcon = '<span class="mode-card-state">▶</span>';
        card.innerHTML = `
            <div class="mode-card-top">
                <span class="mode-card-name">${meta.name}</span>
                ${suggested === meta.id ? '<span class="mode-card-star">★</span>' : ''}
                ${stateIcon}
            </div>
            <div class="mode-card-target">${meta.target}</div>
            <div class="mode-card-blurb">${meta.blurb}</div>`;
        card.onclick = () => selectMode(meta.id);
        grid.appendChild(card);
    });
}

function renderModeDetail() {
    const detail = document.getElementById('mode-detail');
    if (!detail) return;
    if (!currentAnalysis) {
        detail.innerHTML = 'pick an engine, then drop a track — tapping any card auditions 10 seconds.';
        return;
    }
    const chain = getChainForMode(selectedMode, currentAnalysis.metrics);
    detail.innerHTML = chain.map(([name, item]) =>
        `<div class="chain-stage"><b>${escapeText(name)}:</b> ${escapeText(item)}</div>`).join('');
}

function updatePreviewIndicators() {
    renderModeGrid();
    const footnote = document.getElementById('mode-footnote');
    if (footnote) {
        footnote.textContent = playingPreviewMode != null
            ? 'auditioning 10 sec — middle slice'
            : (previewGenerating ? 'rendering 10 sec preview…' : 'tap to audition 10 sec');
    }
}

/** Pick an engine: persist, push to pending batch tracks, audition it. */
function selectMode(id) {
    selectedMode = id;
    try { localStorage.setItem('resonanceEngine', id); } catch (e) {}
    batchTracks.forEach(t => {
        if (t.status === 'queued' || t.status === 'ready') t.mode = id;
    });
    renderBatchList();
    renderModeDetail();
    updatePreviewIndicators();
    addLog(`Engine switched to ${modeName(id)}`);
    playPreview(id);
}

function initModeSelector() {
    renderModeGrid();
    renderModeDetail();
    updatePreviewIndicators();
}

// ================= AUDITION PREVIEWS =================
// Middle 10 seconds, every engine. Played back via <audio>.
let previewMap = {};         // single-track: mode -> path
let batchPreviewStore = {};  // trackName -> { mode -> path }
let previewAudio = null;
let previewGenerating = false;
let previewProgressMode = null;
let playingPreviewMode = null;

function currentPreviewMap() {
    if (batchTracks.length && currentAnalysis && batchPreviewStore[currentAnalysis.title]) {
        return batchPreviewStore[currentAnalysis.title];
    }
    return previewMap;
}

function stopPreview() {
    if (previewAudio) { try { previewAudio.pause(); } catch (e) {} previewAudio = null; }
    playingPreviewMode = null;
    updatePreviewIndicators();
}

async function generatePreviews(filePath, metrics, trackName) {
    previewGenerating = true;
    previewProgressMode = null;
    updatePreviewIndicators();
    try {
        const res = await window.api.runEngine(['preview', filePath, JSON.stringify(metrics)]);
        const map = (res && res.previews) || {};
        if (trackName) batchPreviewStore[trackName] = map;
        else previewMap = map;
        if (Object.keys(map).length) {
            setAssistantStatus('previews ready · tap an engine to audition');
            addLog(`10-sec previews ready (${Object.keys(map).length} engines).`);
        }
    } catch (err) {
        addLog(`Preview render failed: ${err.message}`);
    }
    previewGenerating = false;
    previewProgressMode = null;
    updatePreviewIndicators();
}

function playPreview(modeId) {
    const map = currentPreviewMap();
    const path = map[modeId];
    if (!path) return;
    if (playingPreviewMode === modeId && previewAudio && !previewAudio.paused) {
        stopPreview();
        return;
    }
    stopPreview();
    previewAudio = new Audio(`file://${path}`);
    previewAudio.onended = () => stopPreview();
    previewAudio.play().catch(err => addLog(`Preview playback failed: ${err.message}`));
    playingPreviewMode = modeId;
    setAssistantStatus('auditioning 10 sec — middle slice');
    updatePreviewIndicators();
}

// --- Mastering Assistant chat: single-blurb viewport (one bubble at a time) ---
const CHAT_TONE_ICON = {
    greeting: '◉', insight: '✳', good: '✓', caution: '⚠', plan: '➤', working: '⟳', done: '✓',
};

let allChatBubbles = [];   // { text, tone, title }
let visibleChatIdx = 0;
let chatCycleTimer = null;
let chatPaused = false;

function setAssistantStatus(text) {
    if (assistantStatus) assistantStatus.textContent = text;
}

function chatDotsEl() {
    let dots = document.getElementById('chat-dots');
    if (!dots && chatStream) {
        dots = document.createElement('div');
        dots.id = 'chat-dots';
        dots.className = 'chat-dots';
        chatStream.after(dots);
    }
    return dots;
}

/** Paint exactly one bubble with a soft fade, plus 1/N dots. */
function renderVisibleBubble() {
    if (!chatStream) return;
    chatStream.innerHTML = '';
    const bubble = allChatBubbles[visibleChatIdx];
    if (bubble) {
        const safe = escapeText(bubble.text).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        const icon = CHAT_TONE_ICON[bubble.tone] || '✳';
        const div = document.createElement('div');
        div.className = `chat-bubble ${bubble.tone}`;
        div.innerHTML = `
            ${bubble.title ? `<div class="bubble-title"><span class="bubble-icon">${icon}</span>${escapeText(bubble.title)}</div>` : ''}
            <p>${safe}</p>`;
        div.onclick = () => advanceChat();
        chatStream.appendChild(div);
    }
    const dots = chatDotsEl();
    if (dots) {
        dots.innerHTML = '';
        if (allChatBubbles.length > 1) {
            allChatBubbles.forEach((_, i) => {
                const d = document.createElement('span');
                d.className = `chat-dot${i === visibleChatIdx ? ' active' : ''}`;
                d.onclick = () => { visibleChatIdx = i; renderVisibleBubble(); };
                dots.appendChild(d);
            });
            const pause = document.createElement('button');
            pause.className = 'chat-pause';
            pause.textContent = chatPaused ? '▶' : '❚❚';
            pause.onclick = (e) => { e.stopPropagation(); chatPaused = !chatPaused; renderVisibleBubble(); };
            dots.appendChild(pause);
        }
    }
}

function advanceChat() {
    if (!allChatBubbles.length) return;
    visibleChatIdx = (visibleChatIdx + 1) % allChatBubbles.length;
    renderVisibleBubble();
}

function startChatCycle() {
    stopChatCycle();
    chatCycleTimer = setInterval(() => {
        if (chatPaused || isBatchRunning) return;
        advanceChat();
    }, 5800);
}

function stopChatCycle() {
    if (chatCycleTimer) clearInterval(chatCycleTimer);
    chatCycleTimer = null;
}

/** Append one chat bubble; single-append jumps to newest. */
function addChatBubble(text, tone = 'insight', title = null) {
    allChatBubbles.push({ text, tone, title });
    visibleChatIdx = allChatBubbles.length - 1;
    renderVisibleBubble();
}

function clearChat() {
    allChatBubbles = [];
    visibleChatIdx = 0;
    renderVisibleBubble();
}

function escapeText(s) {
    return String(s == null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Render the assistant's conversational read from an analysis result. */
function renderAssistantChat(analysis, trackName) {
    clearChat();
    if (trackName) allChatBubbles.push({ text: `on it — reading **${trackName}** now.`, tone: 'greeting' });
    const chat = (analysis && analysis.chat) || [];
    if (chat.length) {
        chat.forEach(b => allChatBubbles.push({ text: b.text, tone: b.tone || 'insight', title: b.title }));
    } else if (analysis && analysis.perspective) {
        // Fallback for older engine output.
        allChatBubbles.push({ text: analysis.perspective, tone: 'insight', title: "here's the read" });
    }
    visibleChatIdx = 0; // wholesale rebuild resets to the top
    renderVisibleBubble();
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
    const chain = getChainForMode(selectedMode, currentAnalysis.metrics);

    chain.forEach(([name, detail]) => {
        const div = document.createElement('div');
        div.className = 'audit-item';
        div.innerHTML = `<div class="metric-line">${escapeText(name)}: <span>${escapeText(detail)}</span></div>`;
        proposedChain.appendChild(div);
    });
    renderModeDetail();
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
        renderModeGrid();

        addLog('DNA mapped. Hybrid compensation plan initialized.');
        btnExecute.disabled = false;
        generatePreviews(currentFilePath, result.metrics, null);
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

    stopPreview();
    previewMap = {};
    updatePreviewIndicators();
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
        mode: selectedMode,
    }));
    batchPreviewStore = {};
    stopPreview();
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
        const modeSelect = document.createElement('select');
        modeSelect.className = 'batch-item-mode';
        modeSelect.title = 'Engine for this track';
        MODE_META.forEach(meta => {
            const opt = document.createElement('option');
            opt.value = meta.id;
            opt.textContent = meta.name;
            if (track.mode === meta.id) opt.selected = true;
            modeSelect.appendChild(opt);
        });
        modeSelect.onchange = () => { track.mode = modeSelect.value; };
        modeSelect.onclick = (e) => e.stopPropagation();
        row.appendChild(modeSelect);
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
    stopPreview();
    // Repaint metrics + audit for the tapped track.
    paintAnalysis(track.analysis);
    renderAssistantChat(track.analysis, track.name);
    renderModeGrid();
    updatePreviewIndicators();
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
            generatePreviews(track.path, result.metrics, track.name);
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
    addChatBubble(`starting the batch with **${modeName(selectedMode)}**. i'll tailor each master to its own analysis — the loud ones get eased off, the dark ones get lifted. sit back.`, 'working', 'mastering all');

    for (const track of batchTracks) {
        if (!track.analysis) continue;
        const trackMode = track.mode || selectedMode;
        track.status = 'mastering';
        renderBatchList();
        setAssistantStatus(`mastering ${track.name}…`);
        addLog(`MASTER: ${track.name} [${modeName(trackMode)}]`);
        try {
            const baseName = track.name.replace(/\.[^/.]+$/, '');
            // Engine forces export into ~/Documents/Sound; we only supply the name.
            const outputPath = `UNIFIED_MASTER_${baseName}.wav`;
            const metricsJson = JSON.stringify(track.analysis.metrics);
            const res = await window.api.runEngine(['master', track.path, outputPath, metricsJson, trackMode]);
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

    addLog(`Initiating ${modeName(selectedMode)} processing sequence...`);
    btnExecute.disabled = true;

    try {
        const fileName = currentFilePath.split(/[\\/]/).pop();
        const baseName = fileName.replace(/\.[^/.]+$/, "");
        // The engine forces all exports into ~/Documents/Sound; we just name the file.
        const outputPath = `UNIFIED_MASTER_${baseName}.wav`;
        const metricsJson = JSON.stringify(currentAnalysis.metrics);

        addLog(`Applying Hybrid Analog Compensation...`);
        addChatBubble(`printing your master now with **${modeName(selectedMode)}** — tailored to this track's read. one sec.`, 'working', 'mastering');
        const res = await window.api.runEngine(['master', currentFilePath, outputPath, metricsJson, selectedMode]);

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
    initModeSelector();
    startChatCycle();
});
window.addEventListener('resize', () => {
    if (camera && renderer) {
        camera.aspect = vizContainer.offsetWidth / vizContainer.offsetHeight;
        camera.updateProjectionMatrix();
        renderer.setSize(vizContainer.offsetWidth, vizContainer.offsetHeight);
    }
});
