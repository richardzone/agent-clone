#!/usr/bin/env node
//
// patch-asar-integrity-digest.js — re-sync the ASAR integrity digest that newer
// Electron embeds in its framework binary.
//
//   node tools/patch-asar-integrity-digest.js <App.app>
//
// Why:
//   Info.plist's ElectronAsarIntegrity holds each archive's header hash. Newer
//   Electron (Codex Framework 154.0.8037.57 is the first seen here) also embeds a
//   SHA256 of that whole dictionary in the framework binary, in a Mach-O section
//   __DATA_CONST,__asar_integrity, so an edited plist is caught too. Once the
//   plist hash changes, that digest is stale and launch fails with
//   FATAL: Failed to get integrity for validatable asar archive.
//
// Slot layout (shell/common/asar/integrity_digest.mm in electron/electron):
//   32-byte sentinel "AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A", uint8 used, uint8 version,
//   32-byte digest. Unused slots fail open; an unknown version fails closed. The
//   digest is SHA256 over, for each key of the dictionary in literal sort order,
//   key + algorithm + hash (UTF-8, no separators).
//
// How:
//   Parse each framework binary's Mach-O load commands (thin or fat) and patch only
//   that section, in place. The section size is fixed, so nothing moves; the
//   binary's code signature is invalidated, and step 9 re-signs every framework
//   anyway. Binaries without the section (older Electron) are left alone.
//
// Output (stderr): one line per framework saying what was done.
//
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const SENTINEL = Buffer.from('AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A', 'latin1');
const SLOT_SIZE = SENTINEL.length + 2 + 32;
const MH_MAGIC_64 = 0xfeedfacf;
const FAT_MAGIC = 0xcafebabe;
const FAT_MAGIC_64 = 0xcafebabf;
const LC_SEGMENT_64 = 0x19;

const [appPath] = process.argv.slice(2);
if (!appPath) {
  console.error('Usage: patch-asar-integrity-digest.js <App.app>');
  process.exit(1);
}

function fail(msg) {
  console.error(`ERROR: ${msg}`);
  process.exit(1);
}

// --- the digest Electron expects, computed from the plist as it now stands ---
const plist = path.join(appPath, 'Contents', 'Info.plist');
let integrity;
try {
  integrity = JSON.parse(execFileSync('/usr/bin/plutil',
    ['-extract', 'ElectronAsarIntegrity', 'json', '-o', '-', plist],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
} catch {
  fail(`${plist} has no readable ElectronAsarIntegrity dictionary`);
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
const digest = hasher.digest();

// --- locate every __DATA_CONST,__asar_integrity section in a Mach-O file ---
function sliceOffsets(buf) {
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
  return buf.readUInt32LE(0) === MH_MAGIC_64 ? [0] : [];
}

function integritySections(buf, base) {
  if (buf.readUInt32LE(base) !== MH_MAGIC_64) fail('unexpected Mach-O slice (not 64-bit)');
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

const frameworksDir = path.join(appPath, 'Contents', 'Frameworks');
const frameworks = fs.existsSync(frameworksDir)
  ? fs.readdirSync(frameworksDir).filter((f) => f.endsWith('.framework'))
  : [];

for (const fw of frameworks) {
  const bin = path.join(frameworksDir, fw, 'Versions', 'Current', fw.slice(0, -'.framework'.length));
  if (!fs.existsSync(bin)) continue;
  const buf = fs.readFileSync(bin);
  const sections = sliceOffsets(buf).flatMap((base) => integritySections(buf, base));
  if (sections.length === 0) continue;

  let patched = 0;
  let unused = 0;
  for (const { offset, size } of sections) {
    if (size !== SLOT_SIZE || !buf.subarray(offset, offset + SENTINEL.length).equals(SENTINEL)) {
      fail(`${fw}: __asar_integrity section has an unknown layout (size ${size})`);
    }
    const used = buf[offset + SENTINEL.length];
    const version = buf[offset + SENTINEL.length + 1];
    if (!used) { unused++; continue; }
    // Electron itself fails closed on any other version; so do we.
    if (version !== 1) fail(`${fw}: __asar_integrity digest version ${version} is not supported`);
    digest.copy(buf, offset + SENTINEL.length + 2);
    patched++;
  }
  if (patched) {
    const fd = fs.openSync(bin, 'r+');
    try {
      for (const { offset } of sections) {
        if (buf[offset + SENTINEL.length]) fs.writeSync(fd, buf, offset + SENTINEL.length + 2, 32, offset + SENTINEL.length + 2);
      }
    } finally {
      fs.closeSync(fd);
    }
  }
  console.error(`   ${fw}: embedded integrity digest ${patched ? `re-synced in ${patched} slice(s)` : 'unused'}${unused && patched ? `, ${unused} unused` : ''}`);
}
