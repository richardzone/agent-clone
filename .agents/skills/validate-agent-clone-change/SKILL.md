---
name: validate-agent-clone-change
description: Validate agent-clone engine, adapter, launcher, tool or developer-workflow changes before delivery, using diff-specific evidence and safe fixtures. Does not install or rebuild clones merely to validate documentation.
---

# Validate an agent-clone change

Read `AGENTS.md`, `CONTRIBUTING.md`, and the affected adapter contract in
`adapters/README.md`. Work from the repository root. Record base/head SHAs and
uncommitted changes; inspect new files as well as the tracked diff. Read sections
15–16 before engine invocations: use their revision-bound archive procedure,
not a copied/shared checkout; profile writes occur even on CLI targets.

Map acceptance criteria to evidence before running checks:

| Criterion | Changed behavior / target | Input and proof | Status | Evidence / gap |
|---|---|---|---|---|

Use PASS, FAIL, BLOCKED, UNVALIDATED or NOT APPLICABLE (with a reason).
Do not claim overall validation while an applicable criterion is not PASS.
An exit code needs an expected outcome: correct refusal can PASS; successful
syntax or preflight does not prove runtime behavior. An LLM opinion alone is
not an assertion. Cover distinct allowed and refused paths affected by a change.

## Select proof by surface

| Surface | Proof to choose |
|---|---|
| Argument/profile handling | In the section-15 sandbox, targeted `--dry-run` for the affected target; invalid/missing values, case-insensitive collisions and provenance refusal where affected. Inspect profile text before invoking the engine: profiles and adapters are sourced shell code. |
| CLI generation/isolation | In a revision-bound archive per section 15 with synthetic profiles and fake vendor executables, inspect generated launcher permissions, line-2 provenance, absolute exec, argument forwarding, namespace wipe before exports and preserved unrelated environment. Never redirect real HOME or CODEX_HOME for a test against live data. |
| ASAR patching | Use a synthetic or disposable archive. Verify unchanged offsets/size and correct entry/block/header integrity; insufficient space must refuse cleanly. Never repack the source bundle or mutate it for a test. |
| Adapter/helper/signing | Verify the affected app's helper layout and inside-out signing. Preserve Codex's vendor-signed binaries. With an authorized throwaway clone, verify signatures and actual launch; source version and running process identity must match the tested artifact. |
| Wrapper/Browser Use | Confirm `zsh -f`, clean protocol stdout, signal forwarding and the actual process ancestry. Signatures or sockets alone do not prove Browser Use works; record real interaction as unvalidated until exercised within task scope. |
| Auto-update/policy | Temporary policy fixtures must preserve unrelated keys and show idempotence/error propagation. For live proof, inspect actual updater behavior; plist values alone are insufficient. Never alter MDM or the original app. |
| Icons | Generate into a temporary directory from a test image; visually inspect padding and confirm the affected icon fields. |
| Docs/developer skills | Check links, frontmatter and command contracts; walk a realistic scenario through the instructions. No app launch, account login or rebuild required. |

Run CONTRIBUTING's static checks. Check unstaged changes with `git diff --check`,
staged changes with `git diff --cached --check`, and the committed patch with
`git diff --check "$BASE_SHA" HEAD` using the recorded review-base SHA.
An empty worktree diff does not validate staged or committed content.
Run commands separately
and retain each exit code. There is no `make test`, coverage floor or npm test
suite in this repository; do not invent one. For new/changed executable helpers,
exercise meaningful behavior as well as parsing. After fixes, rerun affected
proof and follow the bounded review loop in CONTRIBUTING.

## Bound side effects

The engine's `--dry-run` stops before writes to clone artifacts, but sources
profiles/adapters and runs Codex CLI preflight first. That preflight creates a
temporary directory and executes the vendor binary. Dry-run is not a sandbox.
Use the revision-bound archive and containment rules in AGENTS.md section 15;
`--all` does not forward containment flags, and `--init` rejects them. Neither
is a default smoke test. App/all builds also affect Launch Services and the Dock,
even with temporary bundle paths. A temporary destination alone is insufficient.

A real build can quit an app, replace its bundle, write a profile, install a CLI
launcher and create data/policy directories. Identify every destination before
running one and keep it within the user's explicitly authorized task and the
section-15 rules. App previews remain previews without that authorization. Inspect existing
clones with `inspect-agent-clone` first. Do not use `--force`, kill sessions,
change login state or rewrite shell dotfiles just to make validation pass.
A missing app, Node or vendor CLI is a blocker, not permission to install it.

Keep synthetic validation isolated from personal profiles and credentials.
Redact logs and selected process fields; never print full environments, tokens,
Keychain contents or auth/session files. Clean only temporary resources created
for this proof; do not stop unrelated processes.

## Delivery

Report revision, criteria/evidence, static versus fixture versus live results,
review rounds/findings and remaining gaps. A generated launcher does not prove
which account it uses; a valid signature does not prove launch or Browser Use.
Follow CONTRIBUTING for local delivery or a requested PR. Neither implies merge.
