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

let spawnFailed = false;
child.once('error', (error) => {
  spawnFailed = true;
  console.error(`Failed to launch the bundled codex binary: ${error.message}`);
  process.exitCode = 1;
});

for (const signal of ['SIGINT', 'SIGHUP', 'SIGTERM']) {
  process.on(signal, () => {
    if (!child.killed) child.kill(signal);
  });
}

child.once('exit', (code, signal) => {
  if (spawnFailed) return;
  if (signal) {
    process.removeAllListeners(signal);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
