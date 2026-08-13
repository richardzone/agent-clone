# agent-clone

Run **multiple isolated copies of AI agent desktop apps** on macOS, each signed
into a different account.

Supports **Claude** (Anthropic) and **Codex** (OpenAI). Every clone gets its own
login, sessions, history, config, icon and Dock entry. The original app is never
modified.

**macOS only**, and desktop apps only. The whole approach is built on macOS
specifics — `.app` bundles, `codesign`, `PlistBuddy`, Launch Services — with no
equivalent on other platforms. Isolating the CLIs instead takes a single
environment variable, see [Isolating the CLIs](#isolating-the-clis).

---

## Quick start

The interactive path detects which apps you have installed and prompts for the
rest:

```bash
./clone-app.sh --init
```

Or do it directly, substituting your own clone names and icons:

```bash
./clone-app.sh MyClaude --app claude --icon ~/Pictures/my-claude.png
./clone-app.sh MyCodex  --app codex  --icon ~/Pictures/my-codex.png

open /Applications/MyClaude.app
```

**After each upstream release**, let the original app update itself first, then
rebuild every clone:

```bash
./clone-app.sh --all
```

That last command is the only one worth memorising. The arguments from the first
run are stored in `profiles/<Name>.conf`, and `--all` rebuilds from them without
further input. The order matters: `--all` re-copies from the *original* app, so
rebuilding before the original has updated just reproduces the old version.

Add `--dry-run` to any of the above to see exactly what would happen without
touching a single file.

Icons given as `.png` are converted to `.icns` automatically (background cropped,
centered, macOS corner radius applied); `.icns` is accepted directly. The two
sample icons in `icons/` are there if you just want to try the flow first.

## Commands

| Command | Purpose |
|---|---|
| `./clone-app.sh --init` | Interactive setup — start here |
| `./clone-app.sh <Name> --app <kind> --icon <path>` | Create a clone, or change its icon |
| `./clone-app.sh <Name>` | Rebuild from the stored profile |
| `./clone-app.sh --all` | Rebuild every clone (**use this after upgrades**) |
| `./clone-app.sh --list` | List configured clones and their types |
| `./clone-app.sh ... --dry-run` | Preview only — append to any invocation above |
| `./clone-app.sh --help` | Full argument reference |

Other options: `--bundle-id`, `--data-dir`, `--source`, `--dest-dir`.
`--app` is case-insensitive.

A clone's name is simultaneously its `.app` filename, display name, process name
and data directory — pick something you can tell apart at a glance, and don't reuse
the name of an app you already have. Every run deletes and rebuilds `<Name>.app` in
the destination directory; the script refuses to delete a bundle it didn't create,
so a collision is reported rather than acted on, but it still costs you a retry.

### Where a clone's data lives

Outside the app bundle — which is why rebuilding never loses logins or history:

- `~/Library/Application Support/<Name>` — Electron data, for every clone
- `~/.codex-<Name>` — Codex only: login (`auth.json`), sessions, `config.toml`, MCP config

Removing a clone for good means deleting its `.app`, its `profiles/<Name>.conf`, and
those directories.

Note that each clone gets its own bundle ID, and macOS grants permissions
(notifications, microphone, screen recording, …) per bundle ID — so a clone asks for
them again on first use, independently of the original.

---

## Notes

This repo **ships no vendor binaries**. It operates in place on the app you
already have installed: copy the bundle, change its identity, re-sign it. Your
original app is left untouched throughout.

That said, a few consequences are worth knowing:

- **Clones lose Apple's signature and notarization.** Modifying a bundle
  invalidates its signature, so the script re-signs ad-hoc (`codesign --sign -`).
  A clone is therefore no longer covered by full Gatekeeper validation.
- **Clones receive no security updates.** Built-in auto-update has to be disabled
  (it would overwrite the clone with the official package, wiping every change and
  usually breaking it outright), so you rebuild by hand after each upstream
  release — see below.
- **Whether multi-account use fits each service's terms is yours to check.** This
  repo solves the technical isolation problem only; it grants no permission to use
  any service.

Not affiliated with Anthropic or OpenAI. Use at your own risk.

---

## Upstream updates require a manual rebuild

**Clones do not auto-update, and must not be allowed to.**

A clone's built-in updater (Squirrel for Claude, Sparkle for Codex) would
download the official package and overwrite itself, discarding every
customisation — and since the new package's signature and bundle name no longer
match, it usually just crashes. The Codex adapter disables Sparkle's automatic
checks explicitly; for Claude, **ignore any update prompt you see**.

The correct sequence is: let the original app update normally, then run
`./clone-app.sh --all`. The script is idempotent and safe to re-run at any time.
User data lives outside the bundle, so rebuilding preserves logins and history.

---

## How the two apps differ

The same pipeline works for both — rewrite identity, patch the asar in place,
sync the integrity hash, inject a wrapper, sign inside-out, rebuild from profile.
The substantive differences are isolated in `adapters/`:

| | Claude | Codex |
|---|---|---|
| Source app | `Claude.app` | `ChatGPT.app` (bundle id is `com.openai.codex`) |
| Main executable | `Claude` | `ChatGPT` |
| Helper location | `Contents/Frameworks/*.app`, path derived from `CFBundleName` | `Codex Framework.framework/Versions/<chromium>/Helpers/` |
| Helpers need renaming | **Yes** — otherwise `Unable to find helper app` | No, paths anchor to the framework name |
| Data isolation | `--user-data-dir` only | `--user-data-dir` **plus** `CODEX_HOME` |
| Keychain isolation | ✅ possible (via asar `productName`) | ❌ not possible (names compiled into native code) |
| Auto-update | in-house Squirrel, no plist switch | Sparkle, disabled via `SUEnableAutomaticChecks` |

### Codex keychain limitation

Codex's keychain service names — `Codex Safe Storage`, `Codex Storage Key`,
`Codex MCP Credentials` — come from a compile-time product-name constant in
`Codex Framework` for the first two, and are hard-coded in the Rust binary at
`Contents/Resources/codex` for the third (`rmcp-client/src/oauth.rs`). **None are
affected by `productName`**, so clones share these entries with the original.

In practice this barely matters, because **Codex stores its login in
`$CODEX_HOME/auth.json` (a file, mode 600) rather than the keychain**:

- **Logins are fully isolated** — each clone keeps its own `auth.json`. Measured:
  login works normally, with no keychain prompts.
- Sessions, history, `config.toml` and MCP configuration also live under
  `CODEX_HOME`, independently per clone.
- The one thing genuinely shared is **OAuth tokens for MCP servers**
  (`Codex MCP Credentials`): identically-named servers will overwrite each
  other's tokens. This only comes up if you authorise an MCP server via OAuth.

Likewise, the original's `keychain-access-groups` entitlement cannot be carried
over by an ad-hoc signature (that needs OpenAI's developer certificate), but since
login does not depend on the keychain, this has no measured effect on day-to-day
use.

---

## Repository layout

```
clone-app.sh                        the generic engine
AGENTS.md                           maintainer notes — read before changing anything
adapters/README.md                  adapter interface contract
adapters/claude.sh                  Claude support
adapters/codex.sh                   Codex support
tools/patch-asar-productname.js     in-place productName rewrite inside app.asar
tools/make-icon.sh                  png -> icns (crop, center, round, all sizes)
icons/                              icon sources and generated .icns
profiles/example.conf.sample        profile field reference
profiles/*.conf                     per-clone parameters, generated (not tracked)
```

`profiles/*.conf` is **not** in version control: it is written by the engine on
first creation, and everyone's clone names, icons and paths differ — it is local
state. Field documentation lives in `profiles/example.conf.sample`, whose suffix
is deliberately not `.conf`, or `--list` and `--all` would treat it as a real
clone and try to rebuild it.

## Requirements

- macOS, zsh, Node.js
- Python 3 with Pillow (optional, only for png→icns; without it the tool falls
  back to plain `sips` scaling — no cropping, no rounded corners)

The icon tool searches `python3`, Homebrew and pyenv locations for an interpreter
that actually has Pillow, rather than trusting whichever one is first on `PATH`.

## Isolating the CLIs

CLIs need no cloning — changing the config directory changes the account:

```bash
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias codex-work='CODEX_HOME=~/.codex-work codex'
```

Log in on first run. Note that if `ANTHROPIC_API_KEY` is set, the Claude CLI
bills per token and ignores your subscription.

---

## Maintaining this repo

Design decisions, the failures behind them, and the verification checklist are in
**[AGENTS.md](AGENTS.md)**. The adapter interface is in
**[adapters/README.md](adapters/README.md)**.
