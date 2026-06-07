#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');

const SETTINGS_PATH = path.join(os.homedir(), '.moonpond_settings.json');
const CURRENT_DIR = __dirname;

function loadSettings() {
  if (fs.existsSync(SETTINGS_PATH)) {
    try {
      return JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    } catch(e) {}
  }
  return null;
}

function saveSettings(settings) {
  try {
    fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2), 'utf8');
    return true;
  } catch(e) {
    return false;
  }
}

function getVisionSummary() {
  const geminiPath = path.join(CURRENT_DIR, 'GEMINI.MD');
  const appSpiritPath = path.join(CURRENT_DIR, 'APPSPIRIT.MD');
  
  let summary = "";
  if (fs.existsSync(geminiPath)) {
    const geminiContent = fs.readFileSync(geminiPath, 'utf8');
    const parts = geminiContent.split('\n## ');
    if (parts.length > 0) {
      summary += "# CORE SECURITY RULES & PROTOCOLS (from GEMINI.MD):\n" + parts[0] + "\n\n";
    }
  }
  
  if (fs.existsSync(appSpiritPath)) {
    const spiritContent = fs.readFileSync(appSpiritPath, 'utf8');
    summary += "# SYSTEM ARCHITECTURE & Roadmaps (from APPSPIRIT.MD):\n";
    const lines = spiritContent.split('\n');
    let capture = false;
    for (const line of lines) {
      if (line.startsWith('## 1. ') || line.startsWith('## 4. ') || line.startsWith('## 3. ')) {
        capture = true;
      } else if (line.startsWith('## ') && !line.startsWith('## 1. ') && !line.startsWith('## 4. ') && !line.startsWith('## 3. ')) {
        capture = false;
      }
      if (capture) {
        summary += line + "\n";
      }
    }
  }
  
  return summary;
}

function getSpecFile() {
  const geminiPath = path.join(CURRENT_DIR, 'GEMINI.MD');
  const appSpiritPath = path.join(CURRENT_DIR, 'APPSPIRIT.MD');

  let geminiContent = fs.existsSync(geminiPath) ? fs.readFileSync(geminiPath, 'utf8') : null;
  let appSpiritContent = fs.existsSync(appSpiritPath) ? fs.readFileSync(appSpiritPath, 'utf8') : null;

  if (!geminiContent && !appSpiritContent) {
    const files = fs.readdirSync(CURRENT_DIR);
    for (const file of files) {
      const filePath = path.join(CURRENT_DIR, file);
      const stat = fs.statSync(filePath);
      if (stat.isFile() && file.endsWith('.md') && file !== 'REPLICATOR.md' && file !== 'GEMINI.MD' && file !== 'APPSPIRIT.MD') {
        return { name: file, content: fs.readFileSync(filePath, 'utf8') };
      }
    }
    return null;
  }

  let combined = "";
  if (geminiContent) {
    combined += '# GEMINI SPECIFICATION CORE\n\n' + geminiContent + '\n\n';
  }
  if (appSpiritContent) {
    combined += '# APPLICATION SOUL & JOURNAL (APPSPIRIT.MD)\n\n' + appSpiritContent;
  }
  return { name: 'Combined Spec (GEMINI.MD & APPSPIRIT.MD)', content: combined };
}

async function queryLlm(args) {
  const { provider, apiKey, model, systemPrompt, context, prompt } = args;
  let url = "";
  let options = {
    method: "POST",
    headers: { "Content-Type": "application/json" }
  };

  if (provider === "gemini") {
    const finalModel = (!model || model === 'auto') ? 'gemini-2.5-flash' : model;
    url = `https://generativelanguage.googleapis.com/v1beta/models/${finalModel}:generateContent?key=${apiKey}`;
    options.body = JSON.stringify({
      contents: [{
        parts: [{
          text: `System instructions:\n${systemPrompt}\n\nSpecification Context:\n${context}\n\nUser Request:\n${prompt}`
        }]
      }]
    });
  } else if (provider === "claude") {
    url = "https://api.anthropic.com/v1/messages";
    options.headers["x-api-key"] = apiKey;
    options.headers["anthropic-version"] = "2023-06-01";
    options.body = JSON.stringify({
      model: model || "claude-3-5-sonnet-20241022",
      max_tokens: 1024,
      system: systemPrompt,
      messages: [{
        role: "user",
        content: `Specification Context:\n${context}\n\nUser Request:\n${prompt}`
      }]
    });
  } else if (provider === "ollama") {
    const port = model.includes(":") ? model : "http://localhost:11434";
    url = `${port}/api/generate`;
    options.body = JSON.stringify({
      model: "llama3",
      system: systemPrompt,
      prompt: `Specification Context:\n${context}\n\nUser Request:\n${prompt}`,
      stream: false
    });
  } else {
    throw new Error("Invalid provider selection in moonpond settings");
  }

  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(url);
    const lib = parsedUrl.protocol === 'https:' ? require('https') : require('http');
    const reqHeaders = { ...options.headers };
    if (options.body) {
      reqHeaders['Content-Length'] = Buffer.byteLength(options.body);
    }
    const req = lib.request(parsedUrl, {
      method: options.method,
      headers: reqHeaders
    }, (res) => {
      let chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(body);
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${body || res.statusMessage}`));
        }
      });
    });
    req.on('error', (err) => reject(err));
    if (options.body) {
      req.write(options.body);
    }
    req.end();
  });
}

function backupWorkspace() {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupDirName = '.moonpond_backup';
  const backupDir = path.join(CURRENT_DIR, backupDirName);
  const targetDir = path.join(backupDir, timestamp);

  if (!fs.existsSync(backupDir)) {
    fs.mkdirSync(backupDir, { recursive: true });
  }
  fs.mkdirSync(targetDir, { recursive: true });

  const ignoreList = ['.git', 'node_modules', '__pycache__', backupDirName, '.DS_Store', 'gemini', 'gemini.cjs'];

  function copyRecursive(src, dest) {
    const exists = fs.existsSync(src);
    const stats = exists && fs.statSync(src);
    const isDirectory = exists && stats.isDirectory();
    if (isDirectory) {
      fs.mkdirSync(dest, { recursive: true });
      fs.readdirSync(src).forEach((childItemName) => {
        if (ignoreList.includes(childItemName)) return;
        copyRecursive(path.join(src, childItemName), path.join(dest, childItemName));
      });
    } else {
      fs.copyFileSync(src, dest);
    }
  }

  copyRecursive(CURRENT_DIR, targetDir);
  
  return timestamp;
}

function rollbackWorkspace(targetTimestamp) {
  const backupDir = path.join(CURRENT_DIR, '.moonpond_backup');
  if (!fs.existsSync(backupDir)) {
    console.error("❌ No backups found in this directory.");
    return;
  }

  const backups = fs.readdirSync(backupDir).filter(f => fs.statSync(path.join(backupDir, f)).isDirectory());
  if (backups.length === 0) {
    console.error("❌ No backups found in this directory.");
    return;
  }

  let selectedBackup = targetTimestamp;
  if (!selectedBackup) {
    console.log("🔮 Available snapshots for rollback:");
    backups.forEach((b, idx) => {
      console.log(`  [${idx + 1}] ${b}`);
    });
    console.log("\nTo rollback, run: ./gemini --rollback <timestamp>");
    return;
  }

  const targetPath = path.join(backupDir, selectedBackup);
  if (!fs.existsSync(targetPath)) {
    console.error(`❌ Backup checkpoint '${selectedBackup}' not found.`);
    return;
  }

  const ignoreList = ['.git', 'node_modules', '__pycache__', '.moonpond_backup', '.DS_Store', 'gemini', 'gemini.cjs'];
  fs.readdirSync(CURRENT_DIR).forEach(file => {
    if (ignoreList.includes(file)) return;
    const filePath = path.join(CURRENT_DIR, file);
    if (fs.statSync(filePath).isDirectory()) {
      fs.rmSync(filePath, { recursive: true, force: true });
    } else {
      fs.unlinkSync(filePath);
    }
  });

  function copyRecursive(src, dest) {
    const stats = fs.statSync(src);
    if (stats.isDirectory()) {
      fs.mkdirSync(dest, { recursive: true });
      fs.readdirSync(src).forEach((childItemName) => {
        copyRecursive(path.join(src, childItemName), path.join(dest, childItemName));
      });
    } else {
      fs.copyFileSync(src, dest);
    }
  }

  fs.readdirSync(targetPath).forEach(file => {
    copyRecursive(path.join(targetPath, file), path.join(CURRENT_DIR, file));
  });

  console.log(`🔮 Workspace successfully rolled back to snapshot: ${selectedBackup}`);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    console.log(`
🔮 MITOSIS_OS // MOONPOND DEVELOPER AGENT CLI
Usage:
  ./gemini "your prompt"               - Run sifter query using current specification and spec context.
  ./gemini -a "your goal"              - Run self-correcting autonomous sandbox execution loop.
  ./gemini --autonomous "your goal"    - Run self-correcting autonomous sandbox execution loop.
  ./gemini --status                    - View app directory spec status and slots registry mapping.
  ./gemini --backup                    - Capture a backup snapshot of current development files.
  ./gemini --rollback                  - List available backup checkpoints.
  ./gemini --rollback <timestamp>     - Rollback directory files to a specific snapshot.
  ./gemini --register <slot_id>        - Register this directory to a Bento slot in desktop hub.
  ./gemini --remove-slot <slot_id>     - Remove/clear slot mapping in desktop hub settings.
`);
    return;
  }

  const settings = loadSettings();
  if (!settings) {
    console.error("❌ Error: ~/.moonpond_settings.json not found.");
    return;
  }

  const firstArg = args[0];

  if (firstArg === '--status') {
    console.log("🔮 App Directory Status [OFFLINE_INTEGRITY]:");
    console.log(`- Path: ${CURRENT_DIR}`);
    const spec = getSpecFile();
    console.log(`- App Specification File: ${spec ? spec.name : "❌ MISSING"}`);
    let mappedSlot = "None";
    Object.keys(settings.slots).forEach(key => {
      if (settings.slots[key].folder === CURRENT_DIR) {
        mappedSlot = `${key.toUpperCase()} (Slot ID: ${key})`;
      }
    });
    console.log(`- Dynamic Bento Slot Mapping: ${mappedSlot}`);
    return;
  }

  if (firstArg === '--backup') {
    backupWorkspace();
    return;
  }

  if (firstArg === '--rollback') {
    rollbackWorkspace(args[1]);
    return;
  }

  if (firstArg === '--register') {
    const slotIdInput = args[1];
    if (!slotIdInput) {
      console.error("❌ Error: Please specify a slot ID (e.g. tether, lens, resonance, prism, jazz, sovereign, pond, mitosis).");
      return;
    }
    const slotId = slotIdInput.toLowerCase();
    if (!settings.slots[slotId]) {
      console.error(`❌ Error: Unknown slot ID '${slotId}'.`);
      return;
    }
    settings.slots[slotId].folder = CURRENT_DIR;
    settings.slots[slotId].active = true;
    if (saveSettings(settings)) {
      console.log(`🔮 Mapped '${slotId}' bento card to: ${CURRENT_DIR}`);
    } else {
      console.error("❌ Failed to save changes.");
    }
    return;
  }

  if (firstArg === '--remove-slot') {
    const slotId = args[1]?.toLowerCase();
    if (!slotId || !settings.slots[slotId]) {
      console.error("❌ Error: Please specify a valid slot ID.");
      return;
    }
    settings.slots[slotId].active = false;
    settings.slots[slotId].folder = "";
    settings.slots[slotId].launch = "";
    if (saveSettings(settings)) {
      console.log(`🔮 Dynamic bento slot '${slotId}' cleared.`);
    } else {
      console.error("❌ Failed to save settings.");
    }
    return;
  }

  const apiSettings = settings.api_settings;

  if (firstArg === '--autonomous' || firstArg === '-a') {
    const goal = args.slice(1).join(" ");
    if (!goal) {
      console.error("❌ Error: Please specify a goal for autonomous execution.");
      return;
    }

    if (apiSettings.provider !== 'ollama' && !apiSettings.api_key) {
      console.log("\n'no llm hooked up - please enter api key' in Dev Hub settings.\n");
      return;
    }

    const vision = getVisionSummary();
    const filesList = fs.readdirSync(CURRENT_DIR)
      .filter(f => {
        const stats = fs.statSync(path.join(CURRENT_DIR, f));
        return stats.isFile() && f !== 'gemini' && f !== 'gemini.cjs' && f !== 'gemini.bat' && f !== 'history_log.json';
      })
      .join(", ");

    console.log(`\n🤖 Launching Autonomous Sandbox Loop...`);
    console.log(`🎯 Goal: ${goal}`);
    console.log(`📁 Files in directory: ${filesList}`);

    let activePrompt = `Autonomous Sandbox Loop initialized.
Your primary Goal: "${goal}"

You have been set loose on this local project workspace.
Here is the compressed vision, safety specification context, and roadmaps:
${vision}

Files currently in the slot directory: [${filesList}]

To achieve your goal, you MUST use the local sandbox tool calls in your response. 
Use [READ_FILE: filename] to read, [WRITE_FILE: filename] ... [END_WRITE] to edit, or [RUN_COMMAND: command] to execute code or run test files.
Output [COMPLETE] only when the goal is achieved and fully verified.

Formulate your plan, call your first tools, and execute!`;

    const historyPath = path.join(CURRENT_DIR, "history_log.json");
    let iteration = 0;
    const maxIterations = 8;
    let completed = false;

    let conversationHistory = [];

    const autonomousSystemPrompt = `You are a self-directed, autonomous software developer executing under the Moonpond Engineering Paradigm.
Goal: "${goal}"
You have direct read/write access to files and local shell execution inside this sandboxed directory.

Tool Call Syntax (MUST use exactly as written):
1. Read file contents:
   [READ_FILE: filename]
2. Create or write a file:
   [WRITE_FILE: filename]
   file content
   [END_WRITE]
3. Execute shell command locally (e.g. run test suite):
   [RUN_COMMAND: command]
4. Complete the goal:
   [COMPLETE]

Rules:
- Be highly precise.
- Only modify files inside the slot directory.
- Verify your changes by executing commands (e.g. python3 test.py) to check stdout/stderr output.
- Conclude your turns with clear tool call tags to execute the next action.`;

    while (iteration < maxIterations && !completed) {
      iteration++;
      console.log(`\n--- [Turn Target: ${iteration}/${maxIterations}] Contacting Sifter... ---`);

      let turnContext = conversationHistory.join("\n\n");
      
      try {
        const response = await queryLlm({
          provider: apiSettings.provider,
          apiKey: apiSettings.api_key,
          model: apiSettings.model,
          systemPrompt: autonomousSystemPrompt,
          context: turnContext,
          prompt: activePrompt
        });

        let cleanText = "";
        try {
          const data = JSON.parse(response);
          if (apiSettings.provider === 'gemini') {
            cleanText = data.candidates[0].content.parts[0].text;
          } else if (apiSettings.provider === 'claude') {
            cleanText = data.content[0].text;
          } else if (apiSettings.provider === 'ollama') {
            cleanText = data.response || data.choices[0].message.content;
          } else {
            cleanText = response;
          }
        } catch(e) {
          cleanText = response;
        }

        console.log(`\n🤖 SIFTER REASONING:`);
        console.log(cleanText);
        console.log(`-----------------------------------`);

        conversationHistory.push(`Turn ${iteration} Agent Response:\n${cleanText}`);

        if (cleanText.includes('[COMPLETE]')) {
          console.log(`\n🎉 Goal achieved autonomously! Complete tag detected.`);
          completed = true;
          break;
        }

        let toolExecuted = false;
        let toolLogs = [];

        const writeRegex = /\[WRITE_FILE:\s*([a-zA-Z0-9_\-\.]+)\s*\]([\s\S]*?)\[END_WRITE\]/g;
        let writeMatch;
        while ((writeMatch = writeRegex.exec(cleanText)) !== null) {
          const filename = writeMatch[1].trim();
          const content = writeMatch[2];
          const fullPath = path.join(CURRENT_DIR, filename);
          console.log(`💾 Tool Call: Writing file -> ${filename}...`);
          try {
            fs.writeFileSync(fullPath, content, 'utf-8');
            toolLogs.push(`Success: Wrote/updated file "${filename}" locally.`);
            toolExecuted = true;
          } catch(err) {
            toolLogs.push(`Error writing file "${filename}": ${err.message}`);
            toolExecuted = true;
          }
        }

        const readRegex = /\[READ_FILE:\s*([a-zA-Z0-9_\-\.]+)\s*\]/g;
        let readMatch;
        while ((readMatch = readRegex.exec(cleanText)) !== null) {
          const filename = readMatch[1].trim();
          const fullPath = path.join(CURRENT_DIR, filename);
          console.log(`📖 Tool Call: Reading file -> ${filename}...`);
          try {
            if (fs.existsSync(fullPath)) {
              const content = fs.readFileSync(fullPath, 'utf-8');
              toolLogs.push("Success: Read contents of file " + filename + ":\n" + content);
            } else {
              toolLogs.push(`Error: File "${filename}" does not exist.`);
            }
            toolExecuted = true;
          } catch(err) {
            toolLogs.push(`Error reading file "${filename}": ${err.message}`);
            toolExecuted = true;
          }
        }

        const cmdRegex = /\[RUN_COMMAND:\s*(.*?)\s*\]/g;
        let cmdMatch;
        while ((cmdMatch = cmdRegex.exec(cleanText)) !== null) {
          const command = cmdMatch[1].trim();
          console.log(`⚡ Tool Call: Executing shell command -> "${command}"...`);
          try {
            const { execSync } = require('child_process');
            const stdout = execSync(command, { cwd: CURRENT_DIR, encoding: 'utf-8', timeout: 30000 });
            toolLogs.push("Success: Shell command " + command + " executed with output:\n" + (stdout || "(no stdout output)"));toolExecuted = true;
          } catch(err) {
            toolLogs.push("Error executing command " + command + ":\n" + (err.stdout || "") + "\n" + (err.stderr || "") + "\n" + err.message);toolExecuted = true;
          }
        }

        if (!toolExecuted) {
          console.log(`⚠️ Warning: No valid tool tags detected in sifter response.`);
          toolLogs.push(`Feedback: Sifter, you did not call any tools or signal completion. If your task is not done, you MUST call [READ_FILE], [WRITE_FILE], or [RUN_COMMAND] in the exact bracket format. If you are finished, output [COMPLETE].`);
        }

        const nextPrompt = `Tool execution results for Turn ${iteration}:\n${toolLogs.join("\n\n")}\n\nPlease proceed with your next reasoning step.`;
        conversationHistory.push(`Turn ${iteration} Sandbox Output:\n${nextPrompt}`);
        activePrompt = nextPrompt;

      } catch (err) {
        console.error(`\n❌ Autonomous Loop API Error on Turn ${iteration}: ${err.message}\n`);
        break;
      }
    }

    if (!completed) {
      console.log(`\n⚠️ Cap reached. Autonomous Sandbox Loop ended after Target turns.`);
    }

    let history = [];
    if (fs.existsSync(historyPath)) {
      try {
        history = JSON.parse(fs.readFileSync(historyPath, 'utf8'));
      } catch(e) {}
    }
    history.push({
      timestamp: new Date().toISOString(),
      prompt: `[Autonomous Run] Goal: ${goal}`,
      response: `Completed: ${completed}. Iterations: ${iteration}. History logged.`
    });
    fs.writeFileSync(historyPath, JSON.stringify(history, null, 2), 'utf8');

    try {
      require('child_process').exec('afplay /System/Library/Sounds/Glass.aiff', () => {});
    } catch(e) {}

    return;
  }

  const prompt = args.join(" ");

  if (apiSettings.provider !== 'ollama' && !apiSettings.api_key) {
    console.log("\n'no llm hooked up - please enter api key' in Dev Hub settings.\n");
    return;
  }

  const spec = getSpecFile();
  if (!spec) {
    console.error("❌ Error: No app specification (.md) file found.");
    return;
  }

  
  try {
    const backupTs = backupWorkspace();
    const response = await queryLlm({
      provider: apiSettings.provider,
      apiKey: apiSettings.api_key,
      model: apiSettings.model,
      systemPrompt: apiSettings.system_prompt,
      context: spec.content,
      prompt: prompt
    });

    let cleanText = "";
    try {
      const data = JSON.parse(response);
      if (apiSettings.provider === 'gemini') {
        cleanText = data.candidates[0].content.parts[0].text;
      } else if (apiSettings.provider === 'claude') {
        cleanText = data.content[0].text;
      } else if (apiSettings.provider === 'ollama') {
        cleanText = data.response || data.choices[0].message.content;
      } else {
        cleanText = response;
      }
    } catch(e) {
      cleanText = response;
    }

    console.log("\n--- REPLICATOR RESPONSE ---");
    console.log(cleanText);
    console.log("---------------------------\n");

    try {
      require('child_process').exec('afplay /System/Library/Sounds/Glass.aiff', () => {});
    } catch(e) {}

    const historyPath = path.join(CURRENT_DIR, "history_log.json");
    let history = [];
    if (fs.existsSync(historyPath)) {
      try {
        history = JSON.parse(fs.readFileSync(historyPath, 'utf8'));
      } catch(e) {}
    }
    history.push({
      timestamp: new Date().toISOString(),
      prompt: prompt,
      response: cleanText
    });
    fs.writeFileSync(historyPath, JSON.stringify(history, null, 2), 'utf8');
    
    
  } catch (e) {
    console.error(`\n❌ Sifter API Error: ${e.message}\n`);
  }
}
main();
