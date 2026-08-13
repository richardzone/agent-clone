# Adapter interface contract

`clone-agent.sh` is a generic engine. It manages a unified profile and dispatches
its `app`, `cli`, or `all` target. For apps, the main line is copy the bundle →
rewrite identity → patch the asar → install a wrapper → sign inside-out. For CLIs,
it generates a profile launcher that selects the isolated agent home.
**Everything app-specific lives in an adapter.**

Supporting a new app means writing `<kind>.sh` in this directory and referring to
it with `--app <kind>`. The filename *is* the kind; there is nothing to register
in the engine.

Two implementations to copy from:

- `claude.sh` — standard Electron layout (helpers under `Contents/Frameworks/`,
  paths derived from `CFBundleName`)
- `codex.sh` — Chromium-style layout (helpers inside the framework) plus an extra
  environment-variable isolation layer

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
| `A_CLI_COMMAND` | Vendor CLI command found through `PATH` and invoked by the generated profile launcher |
| `A_CLI_HOME_TEMPLATE` | Literal portable path containing `<NAME>`, such as `$HOME/.claude-<NAME>` |

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

**All nine must be defined** — the engine calls the target-relevant set. Write a no-op
for the ones you don't need:

```zsh
a_notes() { :; }
```

Call order (numbers refer to the engine's steps):

| When | Function | Arguments |
|---|---|---|
| Preflight, before any writes | `a_preflight` | source app path |
| 3/9 rewrite bundle identity | `a_extra_plist` | path to the clone's Info.plist |
| 5/9 handle helpers | `a_rename_helpers` | clone app path, clone name |
| 8/9 install wrapper | `a_wrapper_env` | clone name |
| 9/9 re-sign (**before** the engine's generic loops) | `a_sign_extra` | clone app path |
| After everything succeeds | `a_notes` | clone name |
| CLI launcher generation | `a_cli_wrapper_env` | clone name |
| CLI launcher generation | `a_cli_exec` | none |
| After CLI succeeds | `a_cli_notes` | clone name |

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

Write adapter-specific keys into the clone's `Info.plist`. The typical use is
disabling auto-update (`codex.sh` sets Sparkle's `SUEnableAutomaticChecks` and
`SUAutomaticallyUpdate` to false here).

`CFBundleName`, `CFBundleDisplayName`, `CFBundleIdentifier`, `CFBundleIconFile`
and `CFBundleIconName` are already handled by the engine; don't repeat them.

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
*inside* a framework, plus any standalone binaries the bundle ships. An adapter
may deliberately preserve an upstream signature instead: Codex must keep the
Developer ID signature on `Contents/Resources/codex` for Browser Use peer
authentication.

Work **inside-out** here as well: deepest first, so the outer seals cover what is
already signed. **Never sign with `codesign --deep`** — Apple deprecated it for
signing and it mismatches nested helper signatures. `--deep` is for verification
only.

### `a_notes <name>`

Printed to the user once everything succeeds. A good place for app-specific
caveats. No-op if there are none.

### CLI functions

`a_cli_wrapper_env <name>` prints portable `export`/`unset` statements into the
generated launcher. `a_cli_exec` prints its final `exec` command and must forward
`"$@"`. `a_cli_notes <name>` explains first-login or authentication behavior.
Launchers must never embed tokens. Codex forces file-based account and MCP OAuth
stores inside its profile-specific `CODEX_HOME`; Claude clears higher-precedence
ambient API/provider credentials so subscription login cannot be silently bypassed.

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

Once it works by hand, slot each step into one of the six functions above — that's
your adapter.
