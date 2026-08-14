#!/usr/bin/env node
'use strict';

const path = require('node:path');
const { spawn } = require('node:child_process');

// This file is run by Codex's bundled, OpenAI-signed Node executable. Keep that
// process alive as the parent of the original signed codex binary so Browser
// Use sees a trusted three-process chain: node_repl -> codex -> node.
const env = { ...process.env };
delete env.CODEX_CLI_PATH;

const child = spawn(path.join(__dirname, 'codex'), process.argv.slice(2), {
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
    // If it does not go down on its own, stop wedging the parent.
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
