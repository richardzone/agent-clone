---
name: inspect-agent-clone
description: Inspect a specific installed agent-clone app or generated CLI launcher for identity, isolation, signature and runtime discrepancies. Use for clone diagnosis or validation; does not rebuild, restart, re-sign or change accounts.
---

# Inspect an installed clone

Read `AGENTS.md` and `adapters/README.md`. Resolve the user's intended profile
name, kind (Claude/Codex), target (app/cli/all), source bundle, clone bundle,
launcher and data directories. Read the profile as text before any engine
invocation; `.conf` files are executable shell, not inert data. Do not print
secrets or source an unknown profile just to learn its fields.

Start with read-only checks for the affected surface, not a full live matrix.
Record repository revision, inspected paths, source/clone versions and observed
running process identity. Do not assume `/Applications/Codex.app` or a default
CLI command when the profile overrides it.

## App evidence

- Read selected identity/version fields with `/usr/libexec/PlistBuddy` for the
  source and clone; verify the clone bundle ID differs as intended.
- Run `codesign --verify --deep --strict "$CLONE_APP"` on the resolved clone.
  This is verification, never a command to re-sign. For Codex launch-chain
  changes inspect the vendor identities on the actual bundled codex/Node binaries.
- Inspect only the clone's wrapper and relevant process ancestry/arguments to
  establish data directory and launcher path. Do not dump full process environments.
- Distinguish a newly written bundle from an old process still running it.
  Activating with `open` does not restart an existing instance.
- For updater questions, use the relevant selected log lines/preferences and
  compare actual behavior. Codex's wrapper environment gate and Claude's local
  policy tier are different; a preference value alone is not proof.

## CLI evidence

Resolve the configured launcher by absolute path. Check the `zsh -f` shebang,
line-2 `clone-agent-profile` marker, private permissions, namespace clearing
before exports, profile-specific home and final argument forwarding. Confirm
Claude desktop intentionally shares its configuration while the generated Claude
CLI selects its own profile home; do not “repair” that distinction by splitting
live configuration. Codex's shared Keychain limitations still apply.

Static inspection cannot establish the logged-in account. If an authorized live
proof is needed, use the smallest account/status operation supported by the
installed version, record only non-secret identity evidence, and do not log in,
log out or read credential files to complete an inspection task.

## Stop and report at the right boundary

Do not rebuild, re-sign, replace launchers, edit preferences/MDM/Keychain, migrate
config, or kill sessions under this skill. Report the exact mismatch and a
proposed scoped remedy; carry out repairs only under the user's repair request.
Launch/Browser Use tests require an authorized target and must not interrupt
existing work. Missing runtime evidence stays UNVALIDATED or BLOCKED, never PASS.

Deliver expected versus observed behavior, proof (path, selected field, exit code
or redacted log line), and remaining checks. An installed version matching its
source, a signature passing, an app launching, correct account isolation and
Browser Use succeeding are separate claims.
