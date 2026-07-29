const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 850,
    backgroundColor: '#0A0E17',
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile('index.html');
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

// --- IPC HANDLERS ---

ipcMain.handle('select-file', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog({
    properties: ['openFile'],
    filters: [{ name: 'Audio', extensions: ['mp3', 'wav', 'm4a', 'flac'] }]
  });
  if (canceled) return null;
  return filePaths[0];
});

// Batch selection — pick multiple tracks; each is mastered uniquely.
ipcMain.handle('select-files', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog({
    properties: ['openFile', 'multiSelections'],
    filters: [{ name: 'Audio', extensions: ['mp3', 'wav', 'm4a', 'flac'] }]
  });
  if (canceled) return [];
  return filePaths;
});

ipcMain.handle('run-engine', async (event, args) => {
  return new Promise((resolve, reject) => {
    // Determine executable path
    const isPackaged = app.isPackaged;
    const fs = require('fs');
    let executable;
    let spawnArgs;

    if (isPackaged) {
      // In production, the binary is bundled
      executable = path.join(process.resourcesPath, 'resonance-engine');
      spawnArgs = args;
    } else {
      // In development, check if dist exists, otherwise use python3
      const distBinary = path.join(__dirname, 'dist', 'resonance-engine');
      const venvPython = path.join(__dirname, 'venv', 'bin', 'python3');
      const systemPython = 'python3';
      
      if (fs.existsSync(distBinary)) {
        executable = distBinary;
        spawnArgs = args;
      } else if (fs.existsSync(venvPython)) {
        executable = venvPython;
        spawnArgs = [path.join(__dirname, 'engine_cli.py'), ...args];
      } else {
        executable = systemPython;
        spawnArgs = [path.join(__dirname, 'engine_cli.py'), ...args];
      }
    }
    
    const child = spawn(executable, spawnArgs, { cwd: __dirname });
    
    let stdout = '';
    let stderr = '';

    child.on('error', (err) => {
      reject(`Failed to start engine: ${err.message}\nPath: ${executable}`);
    });

    child.stdout.on('data', (data) => {
      stdout += data.toString();
    });
    child.stderr.on('data', (data) => {
      const output = data.toString();
      stderr += output;
      const lines = output.split('\n');
      for (const line of lines) {
        if (line.startsWith('PROGRESS:')) {
          const percent = parseInt(line.split(':')[1].trim());
          if (!isNaN(percent)) {
            event.sender.send('engine-progress', percent);
          }
        }
      }
    });

    child.on('close', (code) => {
      const lastJsonLine = stdout.split('\n').filter(l => l.trim().startsWith('{')).pop() || '';
      if (code !== 0) {
        let errorMsg = `Engine exited with code ${code}`;
        if (lastJsonLine) {
          try {
            const parsed = JSON.parse(lastJsonLine);
            if (parsed.error) errorMsg = parsed.error;
          } catch (_) {}
        }
        if (stderr.trim()) errorMsg += '\n' + stderr.trim();
        reject(`Engine Error: ${errorMsg}`);
      } else {
        try {
          resolve(JSON.parse(lastJsonLine));
        } catch (e) {
          reject(`Failed to parse engine output: ${stdout}\nError: ${e.message}`);
        }
      }
    });
  });
});
