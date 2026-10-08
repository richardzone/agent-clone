#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

// This file is run by Codex's bundled, OpenAI-signed Node executable. Keep that
// process alive as the parent of the original signed codex binary so Browser
// Use sees a trusted three-process chain: node_repl -> codex -> node.
const env = { ...process.env };
delete env.CODEX_CLI_PATH;

// Keep in step with _a_codex_signed in adapters/codex.sh: the nested bundle since
// 26.928, else the bare binary earlier builds shipped. A layout counts only if
// its executable is a regular file with the execute bit — the same test preflight
// used to choose the binary it verified, so the clone never spawns another one.
const isExecutableFile = (p) => {
  try {
    if (!fs.statSync(p).isFile()) return false;
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
};
const bundledCodex = path.join(__dirname, 'codex-cli', 'CodexCLI.app', 'Contents', 'MacOS', 'codex');
const codexPath = isExecutableFile(bundledCodex) ? bundledCodex : path.join(__dirname, 'codex');

// The app appends dirname(CODEX_CLI_PATH) to the app-server's PATH, if absent, as
// a fallback `codex` for agent shells; a user's own codex earlier on PATH still
// wins. For a clone that directory is Resources/, which no longer holds codex
// (it moved into CodexCLI.app in 26.928), so append the real binary's directory
// the same way. Appending, not prepending, keeps the original's precedence. On
// the old layout that directory is Resources/ itself, already present: a no-op.
const codexDir = path.dirname(codexPath);
const currentPath = env.PATH || '';
if (!currentPath.split(path.delimiter).includes(codexDir)) {
  env.PATH = currentPath ? `${currentPath}${path.delimiter}${codexDir}` : codexDir;
}

const child = spawn(codexPath, process.argv.slice(2), {
  env,
  stdio: 'inherit',
});

// Track liveness ourselves. `child.killed` only records that kill() was once
// called on the handle, not that the child died — using it as the guard makes
// every signal after the first a no-op, so a child that ignores the first
// SIGTERM can never be signalled again. Registering the listeners below also
// suppresses Node's own default disposition, so failing to forward would leave
// the pair killable only by SIGKILL.
let childAlive = true;
let spawnFailed = false;

child.once('error', (error) => {
  spawnFailed = true;
  childAlive = false;
  console.error(`Failed to launch the bundled codex binary: ${error.message}`);
  process.exitCode = 1;
});

for (const signal of ['SIGINT', 'SIGHUP', 'SIGTERM']) {
  process.on(signal, () => {
    if (!childAlive) return;
    try {
      child.kill(signal);
    } catch {
      // Already gone; the exit handler will propagate.
    }
    // Escalate only for shutdown signals. SIGINT often means "cancel the current
    // turn, keep the session" to a TUI, and hard-killing it five seconds later
    // would destroy work the user was only trying to interrupt.
    if (signal === 'SIGINT') return;
    setTimeout(() => {
      if (!childAlive) return;
      try {
        child.kill('SIGKILL');
      } catch {
        /* nothing left to kill */
      }
    }, 5000).unref();
  });
}

child.once('exit', (code, signal) => {
  childAlive = false;
  if (spawnFailed) return;
  if (signal) {
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
