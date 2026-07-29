# Worklog — 2026-07-01

## Session Summary
Launched the Resonance Electron app and investigated a Python engine import error.

## Actions Taken

### 1. App Launch
- Ran `npm start` — the Electron window opened successfully.

### 2. Bug: "Error importing numpy from its source directory"
- **Symptom:** When clicking Analyze/Master in the UI, the IPC `run-engine` handler threw:
  `Engine Error: Internal module import failed Error importing numpy, you should not try to import numpy from its source directory`
- **Root cause (likely):** In `main.js:74`, the `spawn()` call that launches the Python engine (`venv/bin/python3 engine_cli.py`) did not specify a `cwd`. On macOS, Electron processes can inherit a cwd of `/` or the app bundle's Resources directory, causing Python to import from unexpected locations or triggering numpy's source-tree detection.
- **Fix applied:** Added `{ cwd: __dirname }` to the spawn options in `main.js:74`:
  ```js
  // Before:
  const child = spawn(executable, spawnArgs);
  // After:
  const child = spawn(executable, spawnArgs, { cwd: __dirname });
  ```
  This ensures the Python subprocess always runs with the project root as its working directory.

### 3. Investigation Notes
- Confirmed numpy installs and imports correctly from the venv when run directly:
  - `venv/lib/python3.9/site-packages/numpy/__init__.py`
- Confirmed `engine_cli.py` runs fine from the venv Python on the CLI.
- No stray `numpy/` directory or PYTHONPATH issues found in the project.

### To Verify
- Relaunch the app and confirm the engine runs correctly after the `cwd` fix.
- If the error persists, the next step would be to also pass `env: { ...process.env, PYTHONPATH: '' }` in the spawn options to strip any inherited path contamination.
