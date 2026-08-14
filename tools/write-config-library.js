#!/usr/bin/env node
//
// write-config-library.js — set local-tier policy keys for a Claude clone.
//
//   node tools/write-config-library.js <configLibraryRoot> '<json object>'
//
// Claude Desktop resolves its managed configuration from two tiers:
//
//   managed  /Library/Managed Preferences/com.anthropic.claudefordesktop.plist
//            — the bundle ID in that path is hard-coded, so it is shared with the
//              original app and with every other clone. Useless for us: a policy
//              deployed there would stop the original updating too.
//   local    <userData>-3p/configLibrary/
//            — derived from userData, which --user-data-dir already isolates, so
//              this one is per-clone. This is what we write.
//
// The app reads the local tier only when the managed tier is absent or carries no
// non-app-behaviour keys (fNe() in the asar). With no MDM plist on the machine —
// the normal case — the local tier is applied in full.
//
// Layout, matching what the app itself writes:
//
//   configLibrary/_meta.json     {"appliedId":"<uuid>","entries":[{"id":"<uuid>","name":"..."}]}
//   configLibrary/<uuid>.json    {"disableAutoUpdates":true, ...}
//
// Keys are flat (the app unflattens them, so `disableAutoUpdates` becomes
// `autoUpdate.disabled` internally). appliedId must match /^[a-f0-9-]{36}$/ or the
// app ignores the file.
//
// Idempotent, and merges rather than overwrites: an existing configuration keeps
// every key it already had.
//
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const [root, patchJson] = process.argv.slice(2);
if (!root || !patchJson) {
  console.error("Usage: write-config-library.js <configLibraryRoot> '<json object>'");
  process.exit(1);
}

const patch = JSON.parse(patchJson);
if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
  throw new Error('the patch must be a JSON object');
}

const UUID_RE = /^[a-f0-9-]{36}$/;
const metaPath = path.join(root, '_meta.json');

function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    if (e.code === 'ENOENT') return undefined;
    // A corrupt file is worth reporting rather than silently replacing: it may be
    // a real configuration the user set up through the app's own Setup panel.
    throw new Error(`${p} exists but is not valid JSON (${e.message}); refusing to overwrite it`);
  }
}

fs.mkdirSync(root, { recursive: true });

const meta = readJson(metaPath) ?? {};
let appliedId = typeof meta.appliedId === 'string' && UUID_RE.test(meta.appliedId)
  ? meta.appliedId
  : null;

const reusedId = appliedId !== null;
if (!reusedId) appliedId = crypto.randomUUID();

const configPath = path.join(root, `${appliedId}.json`);
const existing = readJson(configPath) ?? {};
const merged = { ...existing, ...patch };

// entries is what the app's Setup panel lists; keep the applied id present in it
// so the configuration stays selectable there.
const entries = Array.isArray(meta.entries) ? meta.entries : [];
if (!entries.some(e => e && e.id === appliedId)) entries.push({ id: appliedId, name: 'Default' });

fs.writeFileSync(configPath, JSON.stringify(merged, null, 2) + '\n');
fs.writeFileSync(metaPath, JSON.stringify({ ...meta, appliedId, entries }, null, 2) + '\n');

const changed = Object.entries(patch).filter(([k, v]) => JSON.stringify(existing[k]) !== JSON.stringify(v));
console.error(`   config library: ${reusedId ? 'updated existing' : 'created'} ${appliedId.slice(0, 8)}…`);
console.error(changed.length
  ? `   set ${changed.map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(', ')}`
  : `   already had ${Object.keys(patch).join(', ')}, left unchanged`);
