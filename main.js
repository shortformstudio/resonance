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
    icon: path.join(__dirname, 'assets/icon.png'),
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

ipcMain.handle('run-engine', async (event, args) => {
  return new Promise((resolve, reject) => {
    // Determine executable path
    const isPackaged = app.isPackaged;
    let executable;
    let spawnArgs;

    if (isPackaged) {
      // In production, the binary is bundled
      executable = path.join(process.resourcesPath, 'resonance-engine');
      spawnArgs = args;
    } else {
      // In development, check if dist exists, otherwise use python3
      const distBinary = path.join(__dirname, 'dist', 'resonance-engine');
      if (require('fs').existsSync(distBinary)) {
        executable = distBinary;
        spawnArgs = args;
      } else {
        executable = 'python3';
        spawnArgs = [path.join(__dirname, 'engine_cli.py'), ...args];
      }
    }
    
    const child = spawn(executable, spawnArgs);
    
    let stdout = '';
    let stderr = '';

    child.on('error', (err) => {
      reject(`Failed to start engine: ${err.message}\nPath: ${executable}`);
    });

    child.stdout.on('data', (data) => {
      const output = data.toString();
      stdout += output;
      
      // Parse progress milestones
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
    child.stderr.on('data', (data) => stderr += data.toString());

    child.on('close', (code) => {
      if (code !== 0) {
        const errorDetail = stderr || `Engine exited with code ${code}`;
        reject(`Engine Error: ${errorDetail}`);
      } else {
        try {
          resolve(JSON.parse(stdout));
        } catch (e) {
          reject(`Failed to parse engine output: ${stdout}\nError: ${e.message}`);
        }
      }
    });
  });
});
