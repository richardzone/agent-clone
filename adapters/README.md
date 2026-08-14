# Adapter interface contract

`clone-app.sh` is a generic engine. It only knows the main line: copy the bundle →
rewrite identity → patch the asar → install a wrapper → sign inside-out → adapter
post-install.
**Everything app-specific lives in an adapter.**

Supporting a new app means writing `<kind>.sh` in this directory and referring to
it with `--app <kind>`. The filename *is* the kind; there is nothing to register
in the engine.

Two implementations to copy from:

- `claude.sh` — standard Electron layout (helpers under `Contents/Frameworks/`,
  paths derived from `CFBundleName`), plus the only `a_post_install` in the repo
- `codex.sh` — Chromium-style layout (helpers inside the framework) plus an extra
  environment-variable isolation layer (`CODEX_HOME`)

Both disable auto-update, from `a_wrapper_env` or `a_post_install` — never from
`a_extra_plist`.

---

## How adapters are loaded

The engine loads an adapter with `source`, so both run in the **same shell**.
Consequently:

- Variables and functions an adapter defines are directly visible to the engine;
  nothing needs exporting.
- Conversely, an adapter can see the engine's variables (`NAME`, `APP`, `SRC`,
  `plist`, …). **Always declare temporaries `local`** inside functions, or you may
  clobber engine state.
- The engine runs under `set -e`, which affects error handling — see
  `a_preflight` below.

---

## Variables

### Read by the engine (required)

| Variable | Purpose |
|---|---|
| `A_LABEL` | Display name. Used in logs (`Type : codex (Codex)`), in the `--init` menu, and as the default clone name `My<A_LABEL>` — so keep it to letters and digits, or that default fails the clone-name validator |
| `A_SOURCE_DEFAULT` | Default path to the source app; overridable with `--source` |
| `A_EXEC_NAME` | Original executable name under `Contents/MacOS/`. The engine renames it to the clone name and writes the wrapper in its place — that way `CFBundleExecutable` never changes while the process name shows the clone |
| `A_BUNDLE_ID_BASE` | Bundle ID prefix. The engine forms `<base>.<lowercased clone name>`; overridable with `--bundle-id` |

Get `A_EXEC_NAME` wrong and the engine fails at step 8 with "Main executable not
found".

### Adapter-private (optional)

The engine does not read these. They are internal conventions that also serve as
documentation:

| Variable | Purpose |
|---|---|
| `A_KEYCHAIN_ISOLATED` | `0`/`1`, whether this app's keychain entries can be isolated. **Not consumed by the engine** — it records the conclusion next to the code |
| `A_FRAMEWORK`, etc. | Entirely up to you; `codex.sh` uses it to locate the framework |

---

## Functions

**All seven must be defined** — the engine calls them unconditionally. Write a
no-op for the ones you don't need:

```zsh
a_notes() { :; }
```

The engine verifies all seven exist right after sourcing the adapter, before
anything is written, and names the missing one. `a_post_install` is the newest and
is what an adapter written against the earlier six-hook contract will be missing.

Call order (numbers refer to the engine's steps):

| When | Function | Arguments |
|---|---|---|
| Preflight, before any writes | `a_preflight` | source app path |
| 3/9 rewrite bundle identity | `a_extra_plist` | path to the clone's Info.plist |
| 5/9 handle helpers | `a_rename_helpers` | clone app path, clone name |
| 8/9 install wrapper | `a_wrapper_env` | clone name |
| 9/9 re-sign (**before** the engine's generic loops) | `a_sign_extra` | clone app path |
| Post-install, after the bundle is complete | `a_post_install` | clone name, **expanded** data dir |
| After everything succeeds | `a_notes` | clone name |

### `a_preflight <src>`

Verify the structural assumptions this adapter depends on. **A non-zero return
aborts the engine, at a point where nothing has been modified yet.**

This is the only thing standing between a layout change upstream and an app that
installs but doesn't work, so don't cut corners here. On failure, `print` exactly
what is missing — that is what tells the user which line of the adapter to fix.

⚠️ **You must `return 1` explicitly.** The engine calls it as
`a_preflight "$SRC" || die ...`, and being on the left of `||` disables `set -e`
*inside the function*. A failing command in there will **not** abort; execution
continues to the end and returns the status of the last command.

The other five functions are called directly, so `set -e` applies normally: any
non-zero return inside them terminates the whole script. Append `|| true` to
commands that are expected to fail sometimes.

### `a_rename_helpers <app> <name>`

If Electron derives helper paths from the main app's `CFBundleName`
(`Contents/Frameworks/<CFBundleName> Helper.app`), then changing `CFBundleName`
requires renaming them here, or launching fails with
`FATAL: Unable to find helper app`. Three things must change: the bundle directory
name, the inner executable name, and `CFBundleExecutable`.

Apps whose helpers anchor to a framework name (like Codex) need no renaming, but
**print a line saying so anyway** — otherwise the log looks like a skipped step.

### `a_extra_plist <plist>`

Write adapter-specific keys into the clone's `Info.plist`.

`CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, `CFBundleIconFile`
and `CFBundleIconName` are already handled by the engine; don't repeat them.

⚠️ **Do not reach for this to disable auto-update.** Both adapters are no-ops
here, and Codex is a no-op *because* the plist route was tried and measured not to
work: Sparkle reads `NSUserDefaults` first and `Info.plist` only as a fallback.
See AGENTS.md.

### `a_wrapper_env <name>`

Output is written **line by line into the wrapper script**, so every line must be
valid shell — usually an `export`. Note that `print` here goes into a file, not to
the user's console.

Use it for isolation layers beyond `--user-data-dir`. Codex, for instance, keeps
login state, sessions and MCP config under `CODEX_HOME`; without injecting it the
clone would share `~/.codex` with the original.

The wrapper exists because a Finder/Dock double-click passes no command-line
arguments, so the isolation settings have to be baked in.

### `a_sign_extra <app>`

Sign adapter-specific deep content. The engine then signs
`Frameworks/*.framework` → `Frameworks/*.app` → native modules outside the asar →
the real main binary → the outer bundle.

So handle only what those loops don't reach: helpers, `Libraries/` and `PlugIns/`
*inside* a framework, plus any standalone binaries the bundle ships (Codex's
`Contents/Resources/codex`).

Work **inside-out** here as well: deepest first, so the outer seals cover what is
already signed. **Never sign with `codesign --deep`** — Apple deprecated it for
signing and it mismatches nested helper signatures. `--deep` is for verification
only.

### `a_post_install <name> <data-dir>`

The one hook that writes **outside the .app**, into the clone's data directory.
Use it for state the app reads from disk rather than from its bundle — `claude.sh`
drops in the local-tier policy file that turns auto-updates off.

Two things follow from where that directory lives:

- **It survives rebuilds** (by design — that is what preserves logins and
  history), so this hook **must be idempotent**. Merge into what is already there;
  never write a file wholesale, or you will discard configuration the user set up
  through the app's own UI.
- **The path is passed expanded.** `DATA_DIR` carries a literal `$HOME` so it can
  go into the wrapper verbatim; the engine expands it before calling you.

### `a_notes <name>`

Printed to the user once everything succeeds. A good place for app-specific
caveats. No-op if there are none.

---

## Order of work for a new adapter

**Do the whole flow by hand once before writing any adapter code.**

Claude's and Codex's pitfalls barely overlap — whether helpers need renaming, what
drives keychain isolation, how many layers of data isolation exist, how to disable
auto-update: all four differ. Commit to an interface before hitting those and the
abstraction will almost certainly be wrong.

The minimum loop to validate by hand: copy the bundle → edit `Info.plist` → change
the asar's `productName` → sync the integrity hash → rename helpers (if needed) →
re-sign → **actually launch it and confirm the processes are healthy**. A run that
completes without errors proves nothing; the verification checklist in
[../AGENTS.md](../AGENTS.md) has ready-to-use commands.

Once it works by hand, slot each step into one of the seven functions above — that's
your adapter.
