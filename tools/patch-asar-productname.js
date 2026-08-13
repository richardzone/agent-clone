#!/usr/bin/env node
//
// patch-asar-productname.js — rewrite productName inside app.asar's package.json, in place.
//
//   node tools/patch-asar-productname.js <app.asar> <NewProductName>
//
// Why not unpack and repack:
//   The asar's unpack rules (which files must stay outside the archive) cannot be
//   inferred from a finished bundle. Codex keeps an entire node_modules subtree
//   outside — down to .md and .h files — so reproducing it with globs is guaranteed
//   to miss some, and missing any yields an app that installs and doesn't work.
//   All we need is one field.
//
// How:
//   An asar is a pickle header plus a data section. Serialise package.json
//   compactly, pad the tail with spaces until its byte length matches the original
//   entry's size exactly (JSON permits trailing whitespace), and overwrite in place.
//   Every offset in the data section stays valid.
//   The entry's integrity.hash and blocks in the header must be updated too — both
//   are fixed-length hex, so the header length is unchanged and, again, so are
//   dataStart and every file offset.
//
// Output: the new header SHA256 (hex). The caller must write it into Info.plist's
//   ElectronAsarIntegrity:Resources/app.asar:hash, or Electron reports
//   "Integrity check failed".
//
const fs = require('fs');
const crypto = require('crypto');

const [asarPath, newName] = process.argv.slice(2);
if (!asarPath || !newName) {
  console.error('Usage: patch-asar-productname.js <app.asar> <NewProductName>');
  process.exit(1);
}

const fd = fs.openSync(asarPath, 'r+');
try {
  // --- read the pickle header ---
  const head = Buffer.alloc(16);
  fs.readSync(fd, head, 0, 16, 0);
  const payloadSize = head.readUInt32LE(4);   // data section starts at 8 + payloadSize
  const jsonLen = head.readUInt32LE(12);
  const dataStart = 8 + payloadSize;

  const headerBuf = Buffer.alloc(jsonLen);
  fs.readSync(fd, headerBuf, 0, jsonLen, 16);
  const headerRaw = headerBuf.toString('utf8');
  const header = JSON.parse(headerRaw.replace(/\0+$/, ''));

  const entry = header.files && header.files['package.json'];
  if (!entry) throw new Error('no top-level package.json in the asar');
  if (entry.unpacked) throw new Error('package.json is marked unpacked, which should never happen');

  const absOffset = dataStart + parseInt(entry.offset, 10);

  // --- read the original package.json ---
  const orig = Buffer.alloc(entry.size);
  fs.readSync(fd, orig, 0, entry.size, absOffset);
  const pkg = JSON.parse(orig.toString('utf8'));
  const oldName = pkg.productName;
  if (oldName === newName) {
    console.error(`   productName is already ${newName}, nothing to change`);
  }
  pkg.productName = newName;

  // --- build equal-length replacement content ---
  const compact = Buffer.from(JSON.stringify(pkg), 'utf8');
  if (compact.length > entry.size) {
    throw new Error(
      `new package.json (${compact.length} bytes) exceeds the original entry size (${entry.size}); cannot rewrite in place`);
  }
  const padded = Buffer.alloc(entry.size, 0x20);  // space padding; JSON ignores trailing whitespace
  compact.copy(padded, 0);

  // --- update the entry's content checksums in the header ---
  // The asar records a SHA256 and per-block hashes for every file; changing content
  // means syncing both, or the read-time integrity check fails.
  const contentHash = crypto.createHash('sha256').update(padded).digest('hex');
  if (entry.integrity) {
    if (entry.integrity.algorithm !== 'SHA256') {
      throw new Error(`unexpected integrity algorithm: ${entry.integrity.algorithm}`);
    }
    entry.integrity.hash = contentHash;
    const blockSize = entry.integrity.blockSize;
    if (!blockSize || entry.size > blockSize) {
      // Files larger than one block need per-block hashing; package.json is far
      // below 4MB, so this should be unreachable.
      throw new Error(`package.json (${entry.size}) exceeds the block size (${blockSize}); per-block hashing needed`);
    }
    entry.integrity.blocks = [contentHash];
  }

  // --- the header length must not change, or every data offset breaks ---
  const newHeaderJson = JSON.stringify(header);
  const newHeaderBuf = Buffer.from(newHeaderJson, 'utf8');
  if (newHeaderBuf.length !== jsonLen) {
    throw new Error(
      `header length changed after re-serialising (${jsonLen} -> ${newHeaderBuf.length}); ` +
      `the original header may not be compact JSON, so in-place rewriting is unsafe`);
  }

  // --- write back: header first, then file content ---
  fs.writeSync(fd, newHeaderBuf, 0, newHeaderBuf.length, 16);
  fs.writeSync(fd, padded, 0, padded.length, absOffset);

  const headerHash = crypto.createHash('sha256').update(newHeaderBuf).digest('hex');
  console.error(`   productName: ${oldName} -> ${newName} (rewritten in place, not repacked)`);
  console.error(`   package.json content hash: ${contentHash.slice(0, 16)}…`);
  process.stdout.write(headerHash);
} finally {
  fs.closeSync(fd);
}
