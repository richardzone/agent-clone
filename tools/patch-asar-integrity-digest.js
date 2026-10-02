#!/usr/bin/env node
//
// patch-asar-integrity-digest.js — re-sync the ASAR integrity digest that newer
// Electron embeds in its framework binary.
//
//   node tools/patch-asar-integrity-digest.js <App.app>           patch the clone (step 7)
//   node tools/patch-asar-integrity-digest.js --check <App.app>   validate the source (preflight)
//
// Why:
//   Info.plist's ElectronAsarIntegrity holds each archive's header hash. Newer
//   Electron (Codex Framework 154.0.8037.57 is the first seen here) can also embed a
//   SHA256 of that whole dictionary in the framework binary, in a Mach-O section
//   __DATA_CONST,__asar_integrity, filled in by the vendor's packager. Once the
//   plist hash changes, that digest is stale and launch fails with
//   FATAL: Failed to get integrity for validatable asar archive.
//
// Slot layout (shell/common/asar/integrity_digest.mm in electron/electron):
//   32-byte sentinel "AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A", uint8 used, uint8 version,
//   32-byte digest. Unused slots fail open; a used slot with an unknown version
//   fails closed. The digest is SHA256 over, for each key of the dictionary in
//   literal sort order, key + algorithm + hash (UTF-8, no separators).
//
// --check runs in preflight against the untouched source and writes nothing. It
//   fails before any write when the slot's layout or version is unknown, when the
//   stored digest does not match the source's own plist under the formula above
//   (upstream changed the hash input), or when a slot sits in a binary the patch
//   step would not reach. Every one of those would otherwise surface only in step 7
//   (after the old clone was deleted) or, worse, as a launch-time FATAL after a
//   build that reported success.
//
// Patch mode rewrites only the digest bytes of used slots, in place. The section
// size is fixed, so nothing moves; the binary's code signature is invalidated, and
// step 9 re-signs every framework anyway. Binaries without the sentinel are not
// parsed at all, so an unrelated framework the parser does not understand cannot
// abort a rebuild.
//
// Output (stderr): a summary line per framework holding a slot, or one line
// saying there is none.
//
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const SENTINEL = Buffer.from('AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A', 'latin1');
const USED = SENTINEL.length;
const VERSION = SENTINEL.length + 1;
const DIGEST = SENTINEL.length + 2;
const SLOT_SIZE = DIGEST + 32;
const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
const LC_SEGMENT_64 = 0x19;

const args = process.argv.slice(2);
const checkOnly = args[0] === '--check';
const appPath = checkOnly ? args[1] : args[0];
if (!appPath || args.length !== (checkOnly ? 2 : 1)) {
  console.error('Usage: patch-asar-integrity-digest.js [--check] <App.app>');
  process.exit(1);
}

function fail(msg) {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
}

function plistValue(plist, key, format) {
  try {
    return execFileSync('/usr/bin/plutil', ['-extract', key, format, '-o', '-', plist],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

// The digest Electron expects for this bundle's plist, as it now stands. Only
// computed when a used slot exists: an app without one need not carry the key.
let expectedDigest = null;
function digestForPlist() {
  if (expectedDigest) return expectedDigest;
  const plist = path.join(appPath, 'Contents', 'Info.plist');
  const json = plistValue(plist, 'ElectronAsarIntegrity', 'json');
  let integrity = null;
  try {
    integrity = JSON.parse(json);  // JSON.parse(null) returns null rather than throwing
  } catch { /* handled below */ }
  if (!integrity || typeof integrity !== 'object' || Array.isArray(integrity)) {
    fail(`${plist} has no readable ElectronAsarIntegrity dictionary, but a framework carries a used digest slot`);
  }
  const hasher = crypto.createHash('sha256');
  // NSLiteralSearch compares UTF-16 code units, which is also JS's default sort.
  for (const key of Object.keys(integrity).sort()) {
    const { algorithm, hash } = integrity[key] || {};
    if (typeof algorithm !== 'string' || typeof hash !== 'string') {
      fail(`ElectronAsarIntegrity:${key} lacks a string algorithm/hash`);
    }
    hasher.update(key, 'utf8').update(algorithm, 'utf8').update(hash, 'utf8');
  }
  expectedDigest = hasher.digest();
  return expectedDigest;
}

// --- Mach-O: every __DATA_CONST,__asar_integrity section, across fat slices ---
function sliceOffsets(buf, label) {
  if (buf.length < 8) return [];
  const magic = buf.readUInt32BE(0);
  if (magic === FAT_MAGIC || magic === FAT_MAGIC_64) {
    const n = buf.readUInt32BE(4);
    const entry = magic === FAT_MAGIC ? 20 : 32;
    const out = [];
    for (let i = 0; i < n; i++) {
      const at = 8 + i * entry + 8;
      out.push(magic === FAT_MAGIC ? buf.readUInt32BE(at) : Number(buf.readBigUInt64BE(at)));
    }
    return out;
  }
  if (buf.readUInt32LE(0) === MH_MAGIC_64) return [0];
  fail(`${label}: holds the integrity sentinel but is not a 64-bit Mach-O`);
}

function integritySections(buf, base, label) {
  if (buf.readUInt32LE(base) !== MH_MAGIC_64) fail(`${label}: slice at ${base} is not 64-bit Mach-O`);
  const ncmds = buf.readUInt32LE(base + 16);
  const found = [];
  let off = base + 32;
  for (let i = 0; i < ncmds; i++) {
    const cmd = buf.readUInt32LE(off);
    const size = buf.readUInt32LE(off + 4);
    if (cmd === LC_SEGMENT_64) {
      const nsects = buf.readUInt32LE(off + 64);
      for (let s = 0, sec = off + 72; s < nsects; s++, sec += 80) {
        const sectname = buf.toString('latin1', sec, sec + 16).replace(/\0+$/, '');
        const segname = buf.toString('latin1', sec + 16, sec + 32).replace(/\0+$/, '');
        if (segname === '__DATA_CONST' && sectname === '__asar_integrity') {
          found.push({ offset: base + buf.readUInt32LE(sec + 48), size: Number(buf.readBigUInt64LE(sec + 40)) });
        }
      }
    }
    off += size;
  }
  return found;
}

function sentinelOffsets(buf) {
  const out = [];
  for (let i = buf.indexOf(SENTINEL); i >= 0; i = buf.indexOf(SENTINEL, i + 1)) out.push(i);
  return out;
}

// Validate every slot in one binary; return them, or [] if it holds none.
function slotsIn(bin, label) {
  let buf;
  try {
    buf = fs.readFileSync(bin);
  } catch (e) {
    fail(`${label}: cannot read ${bin} (${e.code || e.message})`);
  }
  const hits = sentinelOffsets(buf);
  if (hits.length === 0) return { buf, slots: [] };
  let slots;
  try {
    slots = sliceOffsets(buf, label).flatMap((base) => integritySections(buf, base, label));
  } catch (e) {
    fail(`${label}: could not parse Mach-O load commands (${e.message})`);
  }
  for (const { offset, size } of slots) {
    if (size !== SLOT_SIZE || !buf.subarray(offset, offset + SENTINEL.length).equals(SENTINEL)) {
      fail(`${label}: __asar_integrity section has an unknown layout (size ${size})`);
    }
    // Electron itself fails closed on any other version of a used slot; so do we.
    if (buf[offset + USED] && buf[offset + VERSION] !== 1) {
      fail(`${label}: __asar_integrity digest version ${buf[offset + VERSION]} is not supported`);
    }
  }
  const inSection = new Set(slots.map((s) => s.offset));
  const stray = hits.filter((h) => !inSection.has(h));
  if (stray.length) fail(`${label}: integrity sentinel found outside an __asar_integrity section`);
  return { buf, slots };
}

// --- the binaries the patch step reaches: each framework's own executable ---
const appReal = fs.realpathSync(appPath);
const frameworksDir = path.join(appPath, 'Contents', 'Frameworks');
const targets = [];
if (fs.existsSync(frameworksDir)) {
  for (const fw of fs.readdirSync(frameworksDir).filter((f) => f.endsWith('.framework'))) {
    const current = path.join(frameworksDir, fw, 'Versions', 'Current');
    const exe = (plistValue(path.join(current, 'Resources', 'Info.plist'), 'CFBundleExecutable', 'raw') || '').trim()
      || fw.slice(0, -'.framework'.length);
    const bin = path.join(current, exe);
    if (!fs.existsSync(bin)) continue;
    const real = fs.realpathSync(bin);
    // cp -R keeps symlinks: never write through one that leaves the bundle.
    if (!real.startsWith(appReal + path.sep)) fail(`${fw}: executable resolves outside the bundle (${real})`);
    targets.push({ fw, bin: real });
  }
}

// Printed only once everything has passed, so a later refusal never follows a ✓.
const summary = [];
let anySlot = false;
for (const { fw, bin } of targets) {
  const { buf, slots } = slotsIn(bin, fw);
  if (slots.length === 0) continue;
  anySlot = true;
  const used = slots.filter((s) => buf[s.offset + USED]);
  const unusedNote = used.length < slots.length ? `, ${slots.length - used.length} unused` : '';
  if (used.length === 0) {
    summary.push(`   ${fw}: embedded integrity digest unused`);
    continue;
  }
  const digest = digestForPlist();
  if (checkOnly) {
    // On the untouched source the stored digest must equal the formula's result.
    // If it does not, upstream changed the hash input and a patched clone would
    // FATAL at launch — refuse now, before anything is deleted.
    for (const { offset } of used) {
      if (!buf.subarray(offset + DIGEST, offset + SLOT_SIZE).equals(digest)) {
        fail(`${fw}: stored integrity digest does not match this plist — upstream changed the digest formula, or the bundle was modified (reinstall it)`);
      }
    }
    summary.push(`   Embedded ASAR integrity digest ✓ (${fw}, ${used.length} slice(s)${unusedNote})`);
    continue;
  }
  const fd = fs.openSync(bin, 'r+');
  try {
    for (const { offset } of used) fs.writeSync(fd, digest, 0, 32, offset + DIGEST);
  } finally {
    fs.closeSync(fd);
  }
  summary.push(`   ${fw}: embedded integrity digest re-synced in ${used.length} slice(s)${unusedNote}`);
}

// --check also proves no slot sits somewhere the patch step does not reach: in the
// main executable, a helper, a dylib, or a framework whose executable resolves
// differently. Any such slot would go stale silently and FATAL at launch.
// Electron places the slot with __attribute__((section(...))), so it is always in
// an __asar_integrity section: reading each Mach-O's load commands (a few KB) finds
// it without reading whole binaries, which would cost ~30 s on a 1.6 GB bundle.
function readAt(fd, pos, len) {
  const b = Buffer.alloc(len);
  return b.subarray(0, fs.readSync(fd, b, 0, len, pos));
}
function hasIntegritySection(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = readAt(fd, 0, 8);
    if (head.length < 8) return false;
    const be = head.readUInt32BE(0);
    let bases;
    if (be === FAT_MAGIC || be === FAT_MAGIC_64) {
      const n = head.readUInt32BE(4);
      const entry = be === FAT_MAGIC ? 20 : 32;
      // Loose sanity bound only: Java class files also start 0xcafebabe, and the
      // per-slice magic check below is what actually rejects them.
      if (n > 64) return false;
      const table = readAt(fd, 8, n * entry);
      if (table.length < n * entry) return false;
      const fileSize = fs.fstatSync(fd).size;
      bases = [...Array(n).keys()].map((i) => (be === FAT_MAGIC
        ? table.readUInt32BE(i * entry + 8) : Number(table.readBigUInt64BE(i * entry + 8))))
        .filter((b) => Number.isSafeInteger(b) && b + 32 <= fileSize);   // junk headers
    } else if (head.readUInt32LE(0) === MH_MAGIC_64) {
      bases = [0];
    } else {
      return false;                                   // not a 64-bit Mach-O
    }
    for (const base of bases) {
      const mh = readAt(fd, base, 32);
      if (mh.length < 32 || mh.readUInt32LE(0) !== MH_MAGIC_64) continue;
      // Real load-command areas are a few KB; cap it so a corrupt header cannot
      // ask for gigabytes.
      const cmds = readAt(fd, base + 32, Math.min(mh.readUInt32LE(20), 1 << 24));
      if (cmds.indexOf('__asar_integrity', 0, 'latin1') >= 0) return true;
    }
    return false;
  } finally {
    fs.closeSync(fd);
  }
}
if (checkOnly) {
  const reached = new Set(targets.map((t) => t.bin));
  // An unreadable file or directory is refused by name: the build's `cp -R` could
  // not copy it either, so this only moves that failure earlier.
  const guarded = (p, what, fn) => {
    try {
      return fn();
    } catch (e) {
      return fail(`cannot ${what} ${path.relative(appPath, p) || p} (${e.code || e.message})`);
    }
  };
  const walk = (dir) => {
    for (const ent of guarded(dir, 'list', () => fs.readdirSync(dir, { withFileTypes: true }))) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) { walk(p); continue; }
      // Symlinks are skipped (their targets are walked directly); compare real paths
      // because the targets were resolved through Versions/Current.
      if (!ent.isFile() || reached.has(fs.realpathSync(p))) continue;
      if (guarded(p, 'read', () => hasIntegritySection(p))) {
        fail(`${path.relative(appPath, p)} has an __asar_integrity section the patch step does not reach`);
      }
    }
  };
  walk(path.join(appPath, 'Contents'));
}

for (const line of summary) console.error(line);
if (!anySlot) console.error('   Embedded ASAR integrity digest: none (older Electron)');
