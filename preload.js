const { contextBridge, ipcRenderer, shell } = require('electron');

contextBridge.exposeInMainWorld('api', {
  selectFile: () => ipcRenderer.invoke('select-file'),
  selectFiles: () => ipcRenderer.invoke('select-files'),
  runEngine: (args) => ipcRenderer.invoke('run-engine', args),
  showItemInFolder: (path) => shell.showItemInFolder(path),
  onProgress: (callback) => ipcRenderer.on('engine-progress', (event, percent) => callback(percent)),
  onLog: (callback) => ipcRenderer.on('log', (event, message) => callback(message))
});
