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
// Idempotent. When `appliedId` is present and well-formed it merges into that
// configuration, so every key it already had survives. When `appliedId` is missing
// or malformed a fresh one is minted — any stale entry is left in place but stops
// being the applied one, which is the safe reading of "we cannot tell which config
// is live".
//
// The entry is given a name that says not to delete it, because the app's own
// Setup panel manages these same files: creating and applying a new configuration
// there, or deleting this one, silently drops the policy until the next rebuild.
//
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const UUID_RE = /^[a-f0-9-]{36}$/;

function readJson(p) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    if (e.code === 'ENOENT') return undefined;
    // A corrupt file is worth reporting rather than silently replacing: it may be
    // a real configuration the user set up through the app's own Setup panel.
    // Deleting it is the documented recovery, so name the path in the message.
    throw new Error(`${p} exists but is not valid JSON (${e.message}).\n` +
      `   Refusing to overwrite it. If you did not create it deliberately, delete it and re-run.`);
  }
}

// Write through a temp file in the same directory, then rename. rename(2) is
// atomic within a filesystem, so a reader never observes a half-written file and
// an interrupted run cannot leave a truncated one — which matters because a
// truncated _meta.json is exactly what readJson() then refuses to touch, turning
// one bad run into a permanently failing rebuild.
// Two concurrent runs can still race to mint separate ids and leave one orphaned
// <uuid>.json behind; that is harmless (a few bytes, and the patch is idempotent),
// and not worth a lockfile here since the engine only ever calls this serially.
function writeAtomic(p, data) {
  const tmp = `${p}.tmp.${process.pid}`;
  try {
    fs.writeFileSync(tmp, data);
    fs.renameSync(tmp, p);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    throw e;
  }
}

function main() {
  const [root, patchJson] = process.argv.slice(2);
  if (!root || !patchJson) {
    throw new Error("usage: write-config-library.js <configLibraryRoot> '<json object>'");
  }

  let patch;
  try {
    patch = JSON.parse(patchJson);
  } catch (e) {
    throw new Error(`the patch argument is not valid JSON (${e.message}): ${patchJson}`);
  }
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch)) {
    throw new Error(`the patch must be a JSON object, got: ${patchJson}`);
  }

  const metaPath = path.join(root, '_meta.json');
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
  // so the configuration stays selectable there. Do not call it "Default" — that is
  // the name the app gives its own auto-created first entry, which would make this
  // one indistinguishable from something safe to delete.
  const entries = Array.isArray(meta.entries) ? meta.entries : [];
  if (!entries.some(e => e && e.id === appliedId)) {
    entries.push({ id: appliedId, name: 'clone-agent.sh policy — do not delete' });
  }

  // Config first, then the meta that points at it: if this is interrupted between
  // the two, the orphaned config file is inert, whereas a meta pointing at a file
  // that does not exist yet would be a dangling reference.
  writeAtomic(configPath, JSON.stringify(merged, null, 2) + '\n');
  writeAtomic(metaPath, JSON.stringify({ ...meta, appliedId, entries }, null, 2) + '\n');

  const changed = Object.entries(patch).filter(([k, v]) => JSON.stringify(existing[k]) !== JSON.stringify(v));
  console.error(`   config library: ${reusedId ? 'updated existing' : 'created'} ${appliedId.slice(0, 8)}…`);
  console.error(changed.length
    ? `   set ${changed.map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(', ')}`
    : `   already had ${Object.keys(patch).join(', ')}, left unchanged`);
}

try {
  main();
} catch (e) {
  // The engine runs under `set -e` and calls this after the bundle is already
  // signed, so a raw stack trace here would strand the user with a working-looking
  // clone whose auto-update was never switched off. Say what broke and what to do.
  console.error(`ERROR: could not write the clone's policy file.\n   ${e.message}`);
  process.exit(1);
}
