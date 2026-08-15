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
is the deliberate exception: keep its original Developer ID signature (section 13).

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

## 10. Disabling auto-update: one mechanism per app, and neither is `Info.plist`

**Symptom:** the clone keeps offering updates even though the adapter "disables"
them.

### Codex — Sparkle reads `NSUserDefaults` before `Info.plist`

The adapter used to write `SUEnableAutomaticChecks=false` and
`SUAutomaticallyUpdate=false` into the clone's `Info.plist`. **Measured: no
effect.** Those keys are only Sparkle's *fallback*; the live values sit in the
clone's own preference domain, and there they were `1`:

```bash
defaults read com.openai.codex.<clone> SUEnableAutomaticChecks   # 1, despite the plist saying false
defaults read com.openai.codex.<clone> SULastCheckTime           # and still ticking
```

`defaults write` is not the fix either — it gets put back. `sparkle.node` exports
`setAutomaticallyChecksForUpdates:`, and the JS side reaches it automatically ~30 s
after launch (`initialize()` arms a timer → `initializeUpdater()` →
`initializeMacSparkle()` → loads `sparkle.node`), with no user action involved.
That the selector is called from that path specifically is inferred from Sparkle's
standard wiring, not from disassembling the binary — but the observable fact stands:
the clone's domain held `1` while its `Info.plist` said false.

The working switch is Codex's own environment gate, injected by `a_wrapper_env`:

```js
The = e => e.CODEX_SPARKLE_ENABLED === 'false'
y5  = (e,t,n,r) => !The(r) && v5.includes(e) && t === n     // shouldIncludeSparkle
```

Note the strict string comparison: **only** the exact string `'false'` disables it.
`0`, `no` or an empty value all leave Sparkle enabled.

It feeds `sparkleManager`'s `enableUpdater`, and `initializeUpdater()` returns
early when false — the updater is never constructed, so nothing is fetched and the
header's update button cannot appear.

### Claude — the local policy tier, not the managed one

Claude has an official `disableAutoUpdates` policy key (since 1.2581.0), resolved
from two tiers. **Only one of them is usable here:**

| Tier | Path | Per-clone? |
|---|---|---|
| managed | `/Library/Managed Preferences/com.anthropic.claudefordesktop.plist` | ❌ bundle ID is **hard-coded** — shared with the original |
| local | `<userData>-3p/configLibrary/` | ✅ derived from `userData`, which `--user-data-dir` isolates |

Deploying to the managed tier would stop the *original* updating too, which
breaks the whole workflow (the original must update first — that is what `--all`
rebuilds from). So `a_post_install` writes the local tier instead.

The local tier is only consulted when the managed tier is absent or carries no
non-app-behaviour keys (`fNe()` in the asar). With no MDM plist on the machine —
the normal case — it is applied in full. If a machine *is* MDM-managed, that
deployment wins and this stops working; that is the documented upstream
precedence, not a bug to route around.

Three details that are easy to misread:

- The precedence is **replace, not merge**, and it cuts both ways. If the managed
  plist holds *only* app-behaviour keys, the whole managed dict is discarded in
  favour of the local tier. But as soon as it holds **one** key that is not
  app-behaviour-only — an egress allowlist, an MCP policy, anything — the local
  tier is dropped wholesale instead, taking `disableAutoUpdates` with it. So *any*
  MDM management of Claude re-enables updates in every clone on that machine, not
  just an update-specific policy, and it takes effect whenever IT next changes an
  unrelated setting. `a_post_install` warns when either managed path exists.
- **Nothing is logged when the local tier is dropped.** The
  `[updater] Auto-updates disabled by enterprise policy` line appears only when the
  policy *is* applied; when it stops applying, the updater simply resumes.
- That same log line appears **whichever tier supplied the value** (telemetry says
  `reason: enterprise_policy` either way). A clone reporting "enterprise policy" is
  not evidence of MDM; the local file produces exactly the same wording.

There is also a third override path, beyond managed-vs-local: `bootstrapUrl` (with
`bootstrapEnabled`, default true) makes the app fetch remote configuration at every
launch, and its own description says those values "override local settings and
become read-only". Nothing in this repo can prevent that — it is inherent to
configuring a bootstrap URL at all — but do not describe the local tier as the last
word without it.

## 11. Clones cannot actually be overwritten by an update — but they still download one

Worth knowing before treating auto-update as an emergency. Measured on a Claude
clone, hourly, for as long as it was left running:

```
[updater] Checking for updates
[updater] Found an update, downloading
[updater] Auto-update error: Could not locate update bundle for
          com.anthropic.claudefordesktop.<clone> within .../ShipIt/update.XXXX/
```

ShipIt looks for a bundle matching the clone's bundle ID inside the downloaded
package and finds only the official `com.anthropic.claudefordesktop`, so the swap
never happens and the clone is left intact. **The cost is bandwidth, not
breakage** — a full installer every hour, discarded every time.

Do not read this as "auto-update is harmless, leave it on". It is still noise in
the UI, it still wastes bandwidth, and it depends on a bundle-ID mismatch that
upstream has no obligation to preserve.

## 12. `~/.claude` is shared, deliberately — and splitting it is one-way

Claude Desktop ships its own Claude Code and runs it out of the **data
directory** — `<userData>/claude-code/<version>/claude.app` — so the binary is
already per-clone. Its **configuration root is not**: the app resolves it as
`CLAUDE_CONFIG_DIR ?? ~/.claude`, the same directory the original app and the
`claude` CLI use. Settings, sessions, history and plugins are therefore shared.

This is the one place where a version gap between clone and original has a real
data surface — everything else (Electron `userData`, `CODEX_HOME`,
`NSUserDefaults`, Claude's keychain entry) is isolated, so the two versions never
read each other's state.

**Leave it shared unless the user explicitly asks otherwise.** Sharing is normally
what people want: one set of skills, plugins and settings across both apps. An
earlier version of this adapter injected `CLAUDE_CONFIG_DIR=$HOME/.claude-<Name>`
in `a_wrapper_env` and it was reverted, because the split is **one-way in
practice**:

- The moment the clone restarts, its Claude Code starts writing to the new
  directory — `.claude.json`, `sessions/`, `projects/`, `tasks/`, `shell-snapshots/`.
  In one measured case that was 57 MB within an hour.
- Merging back is not a `cp`: `.claude.json` is a single global config that both
  sides have since edited independently, so there is no conflict-free union.
- Reverting the wrapper does **not** move that data back. The clone simply stops
  seeing it.

So this is a decision to confirm before acting on, not a default to apply. If it is
wanted, say plainly that the split starts at the next launch and is not reversible
by rebuilding.

## 13. Browser Use needs three consecutive OpenAI-signed processes

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

## 14. CLI launchers belong to the unified profile

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

# 7. Auto-update is actually off — check the behaviour, not the setting
#    Claude: expect "disabled by enterprise policy", and no "Checking for updates"
grep -aE '\[updater\]|CCD-autoupdate' ~/Library/Logs/$NAME/main.log | tail -5
#    Codex: SULastCheckTime must stop advancing. Note SUEnableAutomaticChecks stays
#    1 — the wrapper's CODEX_SPARKLE_ENABLED stops the updater being constructed at
#    all, so Sparkle never reads its own settings. Checking the setting proves nothing.
defaults read com.openai.codex.<clone> SULastCheckTime

# 8. The wrapper really carries the isolation variables into the process.
#    Expect per app: Codex → CODEX_HOME, CODEX_SPARKLE_ENABLED, CODEX_CLI_PATH.
#    Claude → nothing here but the --user-data-dir argument; its wrapper only
#    *unsets* CLAUDE_USER_DATA_DIR and deliberately never sets CLAUDE_CONFIG_DIR
#    (section 12). A Claude clone matching nothing is correct, not a failure —
#    check the argument instead.
ps eww -p "$(pgrep -xf "/Applications/$NAME.app/Contents/MacOS/$NAME.*" | head -1)" |
  tr ' ' '\n' | grep -E 'CODEX_HOME|CODEX_SPARKLE_ENABLED|CODEX_CLI_PATH|--user-data-dir'
#    And that CLAUDE_USER_DATA_DIR really is absent, since inheriting it would
#    silently re-enable Claude's auto-updates (section 10):
ps eww -p "$(pgrep -xf "/Applications/$NAME.app/Contents/MacOS/$NAME.*" | head -1)" |
  tr ' ' '\n' | grep -c 'CLAUDE_USER_DATA_DIR'      # Expect: 0

# 9. Codex only: the Browser Use chain. codex must hang off the bundled node, not
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
NAME=MyCodex; CMD=codex-mycodex          # or whatever --list reports

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

⚠️ **`open` will not restart a clone that is still running** — it just activates
the existing instance, and you will sit there wondering why a fresh setting had no
effect. Claude in particular refuses to quit while it has live Claude Code sessions
(`[updater-guard] restart deferred; N local session(s) still running`), so
`pkill -TERM` and even `osascript … quit` can both come back "successful" with the
process still up. Confirm it is gone before drawing conclusions:

```bash
ps aux | grep "[/]Applications/$NAME.app/Contents/MacOS/$NAME"
```

Since the engine's own `pkill` is subject to exactly the same refusal, a rebuild
can leave the old process running against a bundle that has already been replaced.
The bundle on disk is new; what is running is not. **Do not `kill -9` your way out
of this on someone else's machine** — those sessions are real work. Ask, or wait.

To verify a change without touching a running clone, launch a throwaway instance
against a scratch data directory. It logs to the same `~/Library/Logs/<Name>/main.log`,
so a run with and a run without the policy are directly comparable:

```bash
CLAUDE_DESKTOP_BACKGROUND_LAUNCH=hidden \
  "/Applications/$NAME.app/Contents/MacOS/$NAME" --user-data-dir=/tmp/scratch
```

⚠️ **Claude only, and it needs one setup step.** This runs the real binary, not the
wrapper, and two things follow:

- The policy root follows `--user-data-dir`, so you must place the policy file at
  `/tmp/scratch-3p/configLibrary/` yourself (`tools/write-config-library.js` does
  it) or the instance starts with no policy at all and you will "reproduce" a
  failure you do not have.
- **Never use this to check Codex.** Its switch is the wrapper's
  `CODEX_SPARKLE_ENABLED`; bypassing the wrapper means Sparkle runs, `SULastCheckTime`
  advances, and you conclude the fix failed when it did not. Verify Codex by
  launching the clone normally.

That difference is worth internalising: **Claude's protection is a file on disk and
survives any launch path that keeps `--user-data-dir`; Codex's is an environment
variable that exists only if the wrapper ran.**

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
