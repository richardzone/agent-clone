# AGENTS.md

Notes for whoever maintains this repository next — human or AI.

> **Scope note:** this file is about maintaining *this repo*. It is not about the
> agent applications the repo clones. If you are just trying to run a second copy
> of Claude or Codex, you want [README.md](README.md) instead.

Every item below corresponds to a real failure. Read them before changing
anything under `clone-agent.sh`, `adapters/`, or `tools/`.

---

## 1. Never unpack and repack the asar

**This is the single most important design decision in this repo.**

An earlier version used `@electron/asar extract` + `pack` to change
`productName`. The problem: repacking requires reproducing the original unpack
rules (which files stay outside, in `app.asar.unpacked/`), and those rules cannot
be reliably inferred from the finished bundle.

- Claude's unpacked set is only 10 files — a glob can just about cover it.
- Codex's unpacked set is an **entire `node_modules` subtree, 643 files**, down to
  `.md` / `.h` / `.gypi`. Reproducing it with globs missed **418 of them**, which
  produced an app that installed fine and was functionally broken.

`tools/patch-asar-productname.js` now does an **in-place rewrite**: it serialises
`package.json` compactly, pads the tail with spaces until the byte length matches
the original entry's `size` exactly (JSON ignores trailing whitespace), then
overwrites in place. Every offset in the data section stays valid. There is
plenty of headroom (763 spare bytes for Claude, 637 for Codex).

Side benefits: no unpacking of a 1.2 GB archive, and `app.asar.unpacked/` is
copied along with the bundle untouched.

**Do not "clean this up" by going back to unpack-and-repack.**

## 2. Rewriting asar content means rewriting the header checksums too

The asar header records an `integrity.hash` and a list of `blocks` per file.
After an in-place content rewrite both must be updated, or Electron fails its
check when it reads that file.

Both are fixed-length hex, so replacing them **leaves the header JSON length
unchanged** — which is exactly what makes in-place rewriting viable, since
`dataStart` and every file offset depend on it. `patch-asar-productname.js`
asserts this: if the re-serialised header changes length, it aborts rather than
writing a corrupt asar.

## 3. ASAR integrity validates the header, not the whole file

**Symptom:** `FATAL:asar_util.cc: Integrity check failed for asar archive (A vs B)`

`ElectronAsarIntegrity` in `Info.plist` holds the **SHA256 of the asar header**.
After modifying the header, write the new hash back (engine step 7).

## 4. Claude's helpers must be renamed; Codex's must not

**Symptom:** `FATAL:electron_main_delegate_mac.mm: Unable to find helper app`

Claude uses the standard Electron layout, where helper paths are derived from the
main app's `CFBundleName` (`Contents/Frameworks/<CFBundleName> Helper.app`).
Changing `CFBundleName` therefore requires renaming all 4 helpers — **bundle
directory name, inner executable name, and `CFBundleExecutable`**.

Codex uses the Chromium-style layout, with helpers under
`Codex Framework.framework/Versions/<version>/Helpers/`. Those paths are anchored
to the framework name and are independent of `CFBundleName`, so no renaming is
needed — its adapter's `a_rename_helpers()` does no renaming and just prints a line
saying so, which keeps the step from looking skipped in the log.

Note that Codex's framework version directory is named after the **Chromium
version** (e.g. `151.0.7922.76`, not Claude's `A`). Resolve it through the
`Versions/Current` symlink; never hard-code it.

## 5. Sign inside-out, and never with `--deep`

**Symptom:** Electron crashes, or Gatekeeper blocks the app

`codesign --deep` is deprecated by Apple **for signing** and produces mismatched
signatures on nested helpers. The correct order is: adapter-specific deep content
(helpers inside the framework, `Libraries`, `PlugIns`) → the frameworks themselves
→ native modules outside the asar → the real main binary → **the outer bundle
last**, so its seal covers everything already signed. Codex's `Resources/codex`
is the deliberate exception: keep its original Developer ID signature (section 10).

`--deep` is fine — and recommended — for **verification**
(`codesign --verify --deep --strict`).

Do not try to inject custom entitlements. Ad-hoc signatures cannot carry things
like `team-identifier` or `keychain-access-groups`, which require a real
developer certificate.

## 6. Keychain isolation works differently for the two apps

**Claude:** Chromium's Safe Storage service name is `"<app name> Safe Storage"`,
and for a packaged Electron app that name comes from **`productName` in the
`package.json` inside the asar** — *not* from `Info.plist`'s `CFBundleName`
(changing that has been measured to have no effect). Changing `productName`
yields a separate keychain entry whose ACL records the clone's own signature on
first use, so there is no recurring prompt.

**Codex:** the service names are compiled into the native layer, so
`productName` has no effect and the entries are shared with the original. See
"Codex keychain limitation" in the README.

**Switching to a self-signed certificate does not fix keychain prompts.** The ACL
binds to a specific signature hash, and a self-signed cert is no more on the
original entry's allowlist than an ad-hoc one is. Also, don't blame ad-hoc
signing itself: non-Electron apps signed ad-hoc don't prompt either, because they
never touch the Keychain. The prompt comes from Chromium's Safe Storage.

## 7. Custom icons require deleting `CFBundleIconName`

Recent Electron versions load the icon from `Assets.car` via `CFBundleIconName`.
That key must be **deleted**, with `CFBundleIconFile` pointed at the custom
`.icns`, or the icon will not change.

## 8. Profile values must be written single-quoted

`P_DATA_DIR` stores a literal `$HOME/Library/...`. Writing it double-quoted would
expand `$HOME` at `source` time into an absolute path, pinning the profile to one
user and breaking portability. The engine uses zsh's `${(qq)}` to single-quote
and escape.

Related, when changing bundle IDs: macOS grants TCC permissions (notifications,
microphone, screen recording, …) per bundle ID, so a new ID means the clone has
to be re-authorised.

## 9. Icon padding and "centering"

`tools/make-icon.sh` finds the content bounding box by background colour, then
centers it. Two traps:

- **The tolerance must be generous.** Source images often carry a nearly
  invisible drop shadow (say 240–253 grey over a 255 white background). Too low a
  tolerance folds that into the bounding box, pushing the visible artwork off
  centre. Default is 28; override with `ICON_BG_TOLERANCE`.
- **Non-square artwork will never have equal padding on all sides.** The long
  edge meets the margin while the short edge is centered proportionally, leaving
  more room along the short axis. That is dictated by the aspect ratio; it can
  only be reduced by scaling the content up overall, not eliminated. Default
  content ratio is 0.88; override with `ICON_CONTENT_RATIO`.

## 10. Browser Use needs three consecutive OpenAI-signed processes

**Symptom:** Browser Use hangs or reports no available browser in a Codex clone,
even though the app has created sockets under `/tmp/codex-browser-use/`.

`browser-use-peer-authorization.node` validates the connecting `node_repl`
process, its parent and its grandparent. All three must have an allowed OpenAI
Team ID and signing identifier. A direct clone launch produces
`node_repl → codex → <clone main>`; re-signing the latter two ad-hoc makes the
socket reject the client immediately.

The Codex adapter sets `CODEX_CLI_PATH` to a tiny shell launcher which immediately
`exec`s the original signed Node binary. That Node process runs a JS launcher and
spawns the untouched signed `Resources/codex`, producing the accepted chain
`node_repl → codex → node`. Do not ad-hoc sign `Resources/codex`, the bundled Node,
or `node_repl`, and do not replace this with a bypass in the authorization module.

Be accurate about what this does and does not preserve. The check the module
enforces is "these three processes carry an OpenAI signing identity". After this
change the middle process is an OpenAI-signed **general-purpose Node interpreter
running `Resources/codex-cli-launcher.cjs`**, a plain file inside the clone that
the local user can edit — replacing its body and re-sealing the bundle with a
credential-free `codesign --force --sign -` is enough to run arbitrary JS under
that trusted identity. The outer seal detects tampering, and same-user local code
execution is already a precondition, so the practical exposure is small. But this
is a launch-path correction that *relaxes* the property from "only OpenAI-signed
code" to "OpenAI-signed Node running a local script" — not a no-op. Call it a
deliberate trade-off of running an ad-hoc-signed clone, not "not a bypass".

Both signature assertions in `a_preflight` are warnings, not hard failures: the
identifiers and Team ID are pinned to what OpenAI ships today, and a rotation
should not block building a clone that would otherwise work.

Two launch-path details that are easy to undo by accident:

- `tools/codex-cli-launcher` must keep `#!/bin/zsh -f`. A non-interactive zsh
  still sources `~/.zshenv`, and this process's stdout **is** the app-server's
  JSON-RPC channel — one `echo` in a dotfile breaks the handshake, which presents
  as exactly the symptom above.
- `codex-cli-launcher.cjs` must not gate signal forwarding on `child.killed`.
  That flag records only that `kill()` was once called, so it makes every signal
  after the first a no-op while Node's own default disposition stays suppressed —
  leaving the launcher and a stuck `codex` killable only by `SIGKILL`.

## 11. CLI launchers belong to the unified profile

Do not add a second management script or a second profiles directory. The engine
owns both targets through `P_TARGET=all|app|cli` in `profiles/<Name>.conf`; the
small files under `~/.local/bin` are generated launchers, not another source of
configuration.

Launchers must contain no credentials. Codex selects a per-profile `CODEX_HOME`
and forces file storage for account and MCP OAuth credentials. Claude selects a
per-profile `CLAUDE_CONFIG_DIR`. Keep literal `$HOME` values single-quoted in the
profile, as described in section 8.

Four properties of a generated launcher are load-bearing. Each replaced something
that failed:

1. **`#!/bin/zsh -f`.** A non-interactive zsh sources `~/.zshenv`, which can print
   into piped output and can define a function that shadows the vendor command.
2. **An absolute path in the `exec` line**, resolved once with `whence -p`.
   `command -v` returns a same-named shell function, and the `-n` check still
   passes.
3. **`unset -m` over whole vendor namespaces, before any `export`.** A list of
   individual credential variables fails open on every vendor release; see
   "Why a namespace, not a list" in adapters/README.md. Reversing the order lets
   the launcher clear the very variable that selects the profile.
4. **The `# clone-agent-profile: <Name>` marker on line 2.** The engine refuses to
   overwrite a launcher path whose line 2 does not match. Without it, a
   `--cli-name` collision silently destroys a vendor CLI, an unrelated tool in the
   same directory, or another profile's launcher — and still prints `Done.` The
   `.app` path has had an equivalent provenance guard from the beginning; this is
   that guard, for the other half of the profile. Do not reword the marker into
   prose: it is parsed.

Profile names must also be unique **case-insensitively**. macOS filesystems are
case-insensitive by default, and the bundle ID and default CLI command both
lowercase the name — so `Work` and `WORK` would share one profile file, one
launcher and one data directory.

---

## Adding an adapter for a new app

The interface contract — variables, function signatures, call order — is in
**[adapters/README.md](adapters/README.md)**. Model your adapter on `claude.sh`
(standard Electron layout) or `codex.sh` (Chromium-style layout plus an extra
environment-variable isolation layer).

**Do the whole thing by hand once before writing the adapter.** Claude's and
Codex's pitfalls barely overlap — commit to an abstraction before you have hit
them and it will almost certainly be the wrong one.

---

## Verification checklist

Run these after changing the script. **A clean run is not evidence; you have to
actually launch the app.**

```bash
NAME=MyCodex

# 1. Version matches the original
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/ChatGPT.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/$NAME.app/Contents/Info.plist"

# 2. Signature is valid
codesign --verify --deep --strict "/Applications/$NAME.app" && echo OK

# 3. Launch it, then check process health by type
open "/Applications/$NAME.app"
sleep 25
ps aux | grep "/Applications/$NAME.app" | grep -v grep |
  sed -E "s/.*--type=([a-z-]+).*/type=\1/; s|.*/Contents/MacOS/$NAME .*|MAIN|; s|.*crashpad.*|crashpad|" |
  sort | uniq -c
# Expect: 1 MAIN, several type=renderer, 1 type=gpu-process

# 4. Data isolation (Codex has two layers)
ls -d ~/Library/Application\ Support/$NAME
ls -d ~/.codex-$NAME                       # Codex only

# 5. Bundle ID differs from the original
defaults read "/Applications/$NAME.app/Contents/Info" CFBundleIdentifier

# 6. For Claude clones, confirm keychain isolation (expect two entries)
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | grep '"svce"' | grep -i claude

# 7. Codex only: the Browser Use chain. codex must hang off the bundled node, not
#    off the clone's ad-hoc-signed main binary, and all three must be OpenAI-signed.
#    Then actually invoke Browser Use — nothing below proves the socket accepts it.
ps -Ao pid=,ppid=,command= | grep "/Applications/$NAME.app" |
  grep -E 'Resources/codex|cua_node/bin/node'
codesign -dv "/Applications/$NAME.app/Contents/Resources/codex" 2>&1 | grep TeamIdentifier
# Expect: TeamIdentifier=2DC432GLL2 (NOT "not set" — that means it was ad-hoc re-signed)
```

For a CLI target, the launcher is the thing that has to be checked — a generated
file that looks right can still resolve to the wrong account:

```bash
NAME=MyCodex; CMD=codex-myscodex          # or whatever --list reports

# 1. Shape: -f shebang, marker on line 2, every unset BEFORE the first export
sed -n '1,8p' "$(whence -p $CMD)"

# 2. It really is this profile's, and really is private
head -2 "$(whence -p $CMD)" | tail -1     # Expect: # clone-agent-profile: <NAME>
stat -f '%Sp' "$(whence -p $CMD)"         # Expect: -rwx------

# 3. The scrub holds against a hostile environment, and ambient settings survive
env ANTHROPIC_PROFILE=x ANTHROPIC_BASE_URL=http://evil OPENAI_API_KEY=sk-x \
    HTTPS_PROXY=http://p:1 SSH_AUTH_SOCK=/tmp/a $CMD --version
# Expect: runs normally. Then confirm inside the CLI that it is the intended
# account — the launcher cannot prove that for you.

# 4. A dotfile cannot break it
printf 'echo BANNER\n' >> ~/.zshenv && $CMD --version | head -1 && \
  sed -i '' '$d' ~/.zshenv           # Expect: no BANNER in the output
```

Do not count processes with something like `grep -oE 'Helper|...' | uniq -c` —
the clone name appears more than once on the same `ps` line (executable path plus
`--user-data-dir` path), which inflates the count. Classify by `--type=` instead.

When a launch fails, **don't guess — read the error**:

```bash
"/Applications/MyCodex.app/Contents/MacOS/MyCodex" \
  --user-data-dir="$HOME/Library/Application Support/MyCodex"
```

Electron's FATAL message says directly whether a helper is missing or the
integrity check failed.

Use `--dry-run` while iterating. It runs every read-only check — argument
parsing, profile resolution, adapter preflight — and stops before the first write,
so you can validate a change without installing anything.

---

## When preflight fails

Each adapter checks the structural assumptions it depends on before any writes
happen (Claude verifies its 4 helpers exist; Codex verifies the framework version
layout and `CODEX_HOME` support). If upstream changes its layout, the script
aborts and names what is missing.

This is deliberate: better a clear abort than silently producing an app that
installs and doesn't work. Fix the assumption in the relevant adapter and re-run.
