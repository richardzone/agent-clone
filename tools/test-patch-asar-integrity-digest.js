#!/usr/bin/env node
//
// test-patch-asar-integrity-digest.js — regression checks for
// patch-asar-integrity-digest.js against synthetic Mach-O bundles.
//
//   node tools/test-patch-asar-integrity-digest.js
//
// Everything is built in a fresh temp directory: minimal thin and fat Mach-O
// files carrying a __DATA_CONST,__asar_integrity section, inside fake .app
// bundles. No real app is read or written. Exits non-zero on the first failure.
//
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const TOOL = path.join(__dirname, 'patch-asar-integrity-digest.js');
const SENTINEL = Buffer.from('AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A', 'latin1');
const HASH = 'a'.repeat(64);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'asar-digest-test-'));
let failures = 0;
let n = 0;

function digestFor(entries) {
  const h = crypto.createHash('sha256');
  for (const [k, v] of Object.entries(entries).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    h.update(k).update(v.algorithm).update(v.hash);
  }
  return h.digest();
}
const DEFAULT_INTEGRITY = { 'Resources/app.asar': { algorithm: 'SHA256', hash: HASH } };
const EXPECTED = digestFor(DEFAULT_INTEGRITY);

// One 64-bit slice: header, one LC_SEGMENT_64 with one section, slot at 0x400.
function slice({ used = 1, version = 1, digest = Buffer.alloc(32), sectSize = 66, withSection = true } = {}) {
  const buf = Buffer.alloc(0x800);
  buf.writeUInt32LE(0xfeedfacf, 0);
  buf.writeUInt32LE(0x0100000c, 4);                  // CPU_TYPE_ARM64
  buf.writeUInt32LE(6, 12);                          // MH_DYLIB
  buf.writeUInt32LE(withSection ? 1 : 0, 16);        // ncmds
  buf.writeUInt32LE(72 + 80, 20);                    // sizeofcmds
  if (withSection) {
    const lc = 32;
    buf.writeUInt32LE(0x19, lc);                     // LC_SEGMENT_64
    buf.writeUInt32LE(72 + 80, lc + 4);
    buf.write('__DATA_CONST', lc + 8, 'latin1');
    buf.writeUInt32LE(1, lc + 64);                   // nsects
    const sec = lc + 72;
    buf.write('__asar_integrity', sec, 'latin1');
    buf.write('__DATA_CONST', sec + 16, 'latin1');
    buf.writeBigUInt64LE(BigInt(sectSize), sec + 40);
    buf.writeUInt32LE(0x400, sec + 48);
  }
  SENTINEL.copy(buf, 0x400);
  buf[0x420] = used;
  buf[0x421] = version;
  digest.copy(buf, 0x422);
  return buf;
}

function fat(slices, magic64 = false) {
  const entry = magic64 ? 32 : 20;
  const align = 0x1000;
  const parts = [];
  let off = align;
  const header = Buffer.alloc(align);
  header.writeUInt32BE(magic64 ? 0xcafebabf : 0xcafebabe, 0);
  header.writeUInt32BE(slices.length, 4);
  slices.forEach((s, i) => {
    const at = 8 + i * entry;
    header.writeUInt32BE(0x0100000c, at);
    if (magic64) {
      header.writeBigUInt64BE(BigInt(off), at + 8);
      header.writeBigUInt64BE(BigInt(s.length), at + 16);
    } else {
      header.writeUInt32BE(off, at + 8);
      header.writeUInt32BE(s.length, at + 12);
    }
    const padded = Buffer.alloc(Math.ceil(s.length / align) * align);
    s.copy(padded);
    parts.push(padded);
    off += padded.length;
  });
  return Buffer.concat([header, ...parts]);
}

function plistXml(dict) {
  const body = Object.entries(dict).map(([k, v]) => `<key>${k}</key>${v}`).join('');
  return `<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>${body}</dict></plist>`;
}

// A fake bundle. frameworks: { 'Name.framework': { exe, binary, execName } }
function makeApp(name, { frameworks = {}, integrity = DEFAULT_INTEGRITY, extra = {} } = {}) {
  const app = path.join(root, `${name}.app`);
  fs.mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true });
  const dict = {};
  if (integrity) {
    dict.ElectronAsarIntegrity = `<dict>${Object.entries(integrity).map(([k, v]) =>
      `<key>${k}</key><dict><key>algorithm</key><string>${v.algorithm}</string><key>hash</key><string>${v.hash}</string></dict>`).join('')}</dict>`;
  }
  fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), plistXml(dict));
  for (const [fw, { binary, execName }] of Object.entries(frameworks)) {
    const exe = execName || fw.replace(/\.framework$/, '');
    const ver = path.join(app, 'Contents', 'Frameworks', fw, 'Versions', 'A');
    fs.mkdirSync(path.join(ver, 'Resources'), { recursive: true });
    fs.writeFileSync(path.join(ver, exe), binary);
    if (execName) {
      fs.writeFileSync(path.join(ver, 'Resources', 'Info.plist'),
        plistXml({ CFBundleExecutable: `<string>${execName}</string>` }));
    }
    fs.symlinkSync('A', path.join(app, 'Contents', 'Frameworks', fw, 'Versions', 'Current'));
  }
  for (const [rel, data] of Object.entries(extra)) {
    fs.mkdirSync(path.dirname(path.join(app, rel)), { recursive: true });
    fs.writeFileSync(path.join(app, rel), data);
  }
  return app;
}

function run(...args) {
  const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: 'utf8' });
  return { code: r.status, err: r.stderr };
}
const fwBin = (app, fw, exe = fw.replace(/\.framework$/, '')) =>
  path.join(app, 'Contents', 'Frameworks', fw, 'Versions', 'A', exe);
const digestAt = (buf, off) => buf.subarray(off + 34, off + 66);

function check(name, cond, detail = '') {
  n++;
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

try {
  // 1. thin, used: patched to the expected digest, idempotently
  {
    const app = makeApp('thin', { frameworks: { 'E.framework': { binary: slice() } } });
    const r = run(app);
    const buf = fs.readFileSync(fwBin(app, 'E.framework'));
    check('thin used slot is patched', r.code === 0 && digestAt(buf, 0x400).equals(EXPECTED), r.err);
    run(app);
    check('re-running is idempotent', fs.readFileSync(fwBin(app, 'E.framework')).equals(buf));
    check('--check accepts the now-consistent bundle', run('--check', app).code === 0);
  }
  // 2. fat, both slices used; also fat64 headers
  for (const m64 of [false, true]) {
    const bin = fat([slice(), slice()], m64);
    const app = makeApp(`fat${m64 ? 64 : 32}`, { frameworks: { 'E.framework': { binary: bin } } });
    const r = run(app);
    const buf = fs.readFileSync(fwBin(app, 'E.framework'));
    check(`fat${m64 ? '64' : ''} binary: both slices patched`,
      r.code === 0 && digestAt(buf, 0x1000 + 0x400).equals(EXPECTED) && digestAt(buf, 0x2000 + 0x400).equals(EXPECTED), r.err);
  }
  // 3. fat, one used one unused: only the used slice changes
  {
    const bin = fat([slice(), slice({ used: 0, version: 0 })]);
    const app = makeApp('mixed', { frameworks: { 'E.framework': { binary: bin } } });
    const r = run(app);
    const buf = fs.readFileSync(fwBin(app, 'E.framework'));
    check('mixed fat: used slice patched, unused untouched',
      r.code === 0 && digestAt(buf, 0x1400).equals(EXPECTED) && digestAt(buf, 0x2400).equals(Buffer.alloc(32)), r.err);
  }
  // 4. unused only (Claude today): file byte-identical, no plist key required
  {
    const bin = slice({ used: 0, version: 0 });
    const app = makeApp('unused', { frameworks: { 'E.framework': { binary: bin } }, integrity: null });
    const r = run(app);
    check('unused slot: nothing written, no plist needed',
      r.code === 0 && fs.readFileSync(fwBin(app, 'E.framework')).equals(bin), r.err);
  }
  // 5. used slot with an unknown version fails, writes nothing, in both modes
  {
    const bin = slice({ version: 2 });
    const app = makeApp('v2', { frameworks: { 'E.framework': { binary: bin } } });
    const r = run(app);
    check('unknown version fails closed', r.code !== 0 && /version 2/.test(r.err), r.err);
    check('…and writes nothing', fs.readFileSync(fwBin(app, 'E.framework')).equals(bin));
    check('--check refuses it too', run('--check', app).code !== 0);
  }
  // 6. unused slot with a nonzero version is not an error (Electron fails open)
  {
    const app = makeApp('unusedv2', { frameworks: { 'E.framework': { binary: slice({ used: 0, version: 2 }) } } });
    check('unused slot with odd version is ignored', run(app).code === 0);
  }
  // 7. wrong section size fails
  {
    const app = makeApp('badsize', { frameworks: { 'E.framework': { binary: slice({ sectSize: 64 }) } } });
    const r = run(app);
    check('unknown section layout fails', r.code !== 0 && /unknown layout/.test(r.err), r.err);
  }
  // 8. sentinel present but no section describing it fails
  {
    const app = makeApp('stray', { frameworks: { 'E.framework': { binary: slice({ withSection: false }) } } });
    const r = run(app);
    check('sentinel outside a section fails', r.code !== 0 && /outside/.test(r.err), r.err);
  }
  // 9. an unrelated framework the parser would reject (fat, with a 32-bit slice)
  //    but without the sentinel is never parsed, so it cannot abort a rebuild
  {
    const slice32 = Buffer.alloc(64);
    slice32.writeUInt32LE(0xfeedface, 0);
    const app = makeApp('unrelated', {
      frameworks: {
        'E.framework': { binary: slice() },
        'Junk.framework': { binary: fat([slice32]) },
      },
    });
    const r = run(app);
    check('unrelated framework does not abort', r.code === 0 && digestAt(fs.readFileSync(fwBin(app, 'E.framework')), 0x400).equals(EXPECTED), r.err);
  }
  // 10. executable named by CFBundleExecutable, not after the bundle
  {
    const app = makeApp('execname', { frameworks: { 'E.framework': { binary: slice(), execName: 'Other' } } });
    const r = run(app);
    check('CFBundleExecutable is honoured', r.code === 0 && digestAt(fs.readFileSync(fwBin(app, 'E.framework', 'Other')), 0x400).equals(EXPECTED), r.err);
  }
  // 11. used slot but no ElectronAsarIntegrity in the plist
  {
    const app = makeApp('noplist', { frameworks: { 'E.framework': { binary: slice() } }, integrity: null });
    const r = run(app);
    check('used slot without a plist dictionary fails with its own message',
      r.code !== 0 && /no readable ElectronAsarIntegrity/.test(r.err) && !/TypeError/.test(r.err), r.err);
  }
  // 12. multiple keys: literal sort order, key+algorithm+hash
  {
    const integrity = {
      'Resources/b.asar': { algorithm: 'SHA256', hash: 'b'.repeat(64) },
      'Resources/A.asar': { algorithm: 'SHA256', hash: 'c'.repeat(64) },
      'Resources/app.asar': { algorithm: 'SHA256', hash: HASH },
    };
    const app = makeApp('multikey', { frameworks: { 'E.framework': { binary: slice() } }, integrity });
    const r = run(app);
    check('multi-key dictionary digest', r.code === 0 && digestAt(fs.readFileSync(fwBin(app, 'E.framework')), 0x400).equals(digestFor(integrity)), r.err);
  }
  // 13. --check: source whose stored digest disagrees with its plist (formula drift)
  {
    const app = makeApp('drift', { frameworks: { 'E.framework': { binary: slice({ digest: Buffer.alloc(32, 7) }) } } });
    const before = fs.readFileSync(fwBin(app, 'E.framework'));
    const r = run('--check', app);
    check('--check detects a digest the formula does not reproduce', r.code !== 0 && /formula/.test(r.err), r.err);
    check('--check writes nothing', fs.readFileSync(fwBin(app, 'E.framework')).equals(before));
  }
  // 14. --check: a slot in a binary the patch step does not reach
  {
    const app = makeApp('elsewhere', {
      frameworks: { 'E.framework': { binary: slice({ digest: EXPECTED }) } },
      extra: { 'Contents/MacOS/Main': slice({ digest: EXPECTED }) },
    });
    const r = run('--check', app);
    check('--check finds a slot outside the frameworks', r.code !== 0 && /does not reach/.test(r.err), r.err);
  }
  // 15. --check: consistent source passes
  {
    const app = makeApp('source', { frameworks: { 'E.framework': { binary: slice({ digest: EXPECTED }) } } });
    const r = run('--check', app);
    check('--check accepts a consistent source', r.code === 0 && /✓/.test(r.err), r.err);
  }
  // 16. executable symlinked outside the bundle is refused, and not written
  {
    const outside = path.join(root, 'outside-binary');
    fs.writeFileSync(outside, slice());
    const app = makeApp('escape', { frameworks: {} });
    const ver = path.join(app, 'Contents', 'Frameworks', 'E.framework', 'Versions', 'A');
    fs.mkdirSync(ver, { recursive: true });
    fs.symlinkSync(outside, path.join(ver, 'E'));
    fs.symlinkSync('A', path.join(app, 'Contents', 'Frameworks', 'E.framework', 'Versions', 'Current'));
    const before = fs.readFileSync(outside);
    const r = run(app);
    check('executable outside the bundle is refused', r.code !== 0 && /outside the bundle/.test(r.err), r.err);
    check('…and the outside file is untouched', fs.readFileSync(outside).equals(before));
  }
  // 18. --check: an unreadable file is refused by name, with no ✓ printed first
  {
    const app = makeApp('unreadable', {
      frameworks: { 'E.framework': { binary: slice({ digest: EXPECTED }) } },
      extra: { 'Contents/Resources/secret.bin': Buffer.from('x') },
    });
    fs.chmodSync(path.join(app, 'Contents/Resources/secret.bin'), 0o000);
    const r = run('--check', app);
    fs.chmodSync(path.join(app, 'Contents/Resources/secret.bin'), 0o644);
    check('unreadable file is refused by name, not with a stack trace',
      r.code !== 0 && /cannot read Contents\/Resources\/secret\.bin/.test(r.err) && !/✓/.test(r.err) && !/at /.test(r.err), r.err);
  }
  // 19. --check: junk headers that look fat (offset past EOF, Java class file) are not slots
  {
    const junk64 = Buffer.alloc(64);
    junk64.writeUInt32BE(0xcafebabf, 0);
    junk64.writeUInt32BE(1, 4);
    junk64.writeBigUInt64BE(0xfffffffffffff000n, 16);   // slice offset far past EOF
    const javaClass = Buffer.alloc(64);
    javaClass.writeUInt32BE(0xcafebabe, 0);
    javaClass.writeUInt32BE(52, 4);                      // minor/major of a Java 8 class
    const app = makeApp('junkfat', {
      frameworks: { 'E.framework': { binary: slice({ digest: EXPECTED }) } },
      extra: { 'Contents/Resources/junk64': junk64, 'Contents/Resources/A.class': javaClass },
    });
    const r = run('--check', app);
    check('junk fat headers are ignored by the bundle scan', r.code === 0 && /✓/.test(r.err), r.err);
  }
  // 17. no slot anywhere: succeed and say so
  {
    const app = makeApp('none', { frameworks: { 'E.framework': { binary: Buffer.alloc(64) } } });
    const r = run('--check', app);
    check('no slot anywhere is reported, not an error', r.code === 0 && /none/.test(r.err), r.err);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}

console.log(`\n${n - failures}/${n} passed`);
process.exit(failures ? 1 : 0);
