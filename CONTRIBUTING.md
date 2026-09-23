# Contributing

This repository builds macOS desktop clones and isolated CLI launchers. Read
[AGENTS.md](AGENTS.md) and [adapters/README.md](adapters/README.md) before changing
the engine, adapters or tools. Preserve the documented app-specific contracts.

## Scope and implementation

1. State observable acceptance criteria and assess the affected surface before
   editing. Documentation can change agent behavior even without executable code.
   Record criteria and risk in the task or PR; explain later scope changes.
2. Check existing issues/PRs by symptom or feature, and recent history of affected
   files. Refresh the base when network access permits; disclose an unavailable
   check. Reuse relevant existing work. An issue is optional, not a prerequisite
   for a requested PR; do not create a competing PR if an existing one solves it.
3. Use an isolated branch/worktree, normally `codex/<purpose>` for agent work.
   Preserve unrelated edits. Record base and head SHAs for review and validation.
4. Implement the smallest change that meets the criteria. Keep this repository's
   ASAR integrity, signature ordering, profile provenance and app/CLI isolation
   contracts. Changes to installed apps or user state need task-specific scope.

## Validation and review

Use [validate-agent-clone-change](.agents/skills/validate-agent-clone-change/SKILL.md)
for criterion-to-evidence validation and
[inspect-agent-clone](.agents/skills/inspect-agent-clone/SKILL.md) for an existing
installed clone or launcher. Developer skills live in `.agents/skills/`, with
`.claude/skills` pointing to the same files. They do not belong inside generated
apps, profiles or launchers.

Before making a scratch commit, run the static checks below and `git diff --check`.
A scratch commit is allowed before behavioral validation: AGENTS.md section 15
requires committed content to create the revision-bound test archive. Record that
commit's SHA and validate its archive, not an older revision or uncommitted tree.
Complete the affected behavioral checks before reporting delivery as validated
or merging; a scratch commit or draft PR does not claim validation is complete.
If a fix changes the tested content, commit it and validate the new revision.
For documentation-only changes, static, link and scenario checks suffice; no
engine invocation or installed-app test is required. Run each command separately
and stop on a nonzero exit; a later success must not hide an earlier failure.

```bash
zsh -f -n clone-agent.sh
zsh -f -n adapters/claude.sh
zsh -f -n adapters/codex.sh
zsh -f -n tools/make-icon.sh
zsh -f -n tools/codex-cli-launcher
zsh -f -n tools/check-doc-claims.sh
zsh -f tools/check-doc-claims.sh
node --check tools/patch-asar-productname.js
node --check tools/write-config-library.js
node --check tools/codex-cli-launcher.cjs
```

This repository has a documentation-claim checker, but no general behavioral
test runner or coverage threshold. Syntax and
`--dry-run` prove neither successful app launch nor account isolation. For runtime
changes, exercise the affected behavior in a task-scoped fixture or authorized
throwaway clone, following AGENTS.md sections 15–16. An app preview must not
be converted to a real build without the explicit permission described there.
Record blocked live checks honestly. Documentation-only changes
need links, command-contract and scenario review, not installation or login.
Add focused behavioral regression checks when code changes; do not test prose
wording. Attribute failures before changing assertions or claiming environment
faults. Update user documentation when observable behavior changes.

Review adversarially: try to find a reachable failure, not confirm the design.
An actionable finding needs a scenario, `file:line`, impact and evidence. Verify
it before changing code. Separate findings from suggestions and uncertainty.
Use P0 for critical breakage/data loss/security, P1 for correctness/regression,
and P2 for lower-impact defects. Check relevant correctness, domain rules,
error paths, compatibility, data schema, security, performance, configuration,
tests and downstream effects; record applicable unchecked areas as open risks.

### Independent adversarial review

For agent-authored PRs, use at least one reviewer in a clean subagent context.
Use 2–3 independent reviewers for large or high-risk changes, especially signing,
ASAR mutation, authentication/isolation, overwrite guards or user-state migration.
Give reviewers
the acceptance criteria, diff and necessary evidence, but not the author's expected
verdict or suspected findings. Prefer different perspectives without restricting
reviewers to a checklist. If two spawn attempts fail, stop retrying and review
manually; disclose the fallback, never claim independent or maintainer approval.

After combining findings, check coverage of correctness, business logic, error
handling, edge cases, API compatibility, data schema, performance, security,
tests, maintainability, configuration and downstream impact. Mark each covered,
unchecked or not applicable with a reason. An applicable unchecked area makes
review incomplete; silence is not a clean verdict. Automated GitHub reviews are
advisory and do not replace this review or human approval.

### Automatic two-round review and fix loop

A round is one review pass (regardless of reviewer count) plus its resulting
fixes. Record the round, reviewed revision, findings, verification/disposition,
checks and remaining gaps in the PR body, linked issue or local-only task. This record must
survive context compaction. Within the budget, verify findings, fix confirmed
in-scope defects and run the required checks without asking permission for each
fix. Existing merge, user-state-change and external-action approvals still apply.

- **Round 1:** if no actionable findings remain and no fixes were made, review
  is complete. If fixes were made, run the required syntax and affected behavioral checks, then
  automatically start round 2 using the reviewer count from the risk assessment.
  Review after round-1 fixes is round 2, never a “final confirmation”.
- **Round 2:** review the updated diff including round-1 fixes. Verify findings
  and fix confirmed defects except when the P0 stop rule below applies. If no
  fixes were needed and no actionable findings remain, review is complete.
  After round-2 fixes, run the required syntax and affected behavioral checks and one final confirmation.
- **Final confirmation:** only after round-2 fixes, perform one narrow independent
  pass over those fixes and their coverage (with the same disclosed fallback if
  spawning fails). It grants no further fix round. If it reports any actionable
  finding, verify and report it with a proposed remedy, then wait for the user's
  decision. Do not fix and repeat confirmation automatically.
- **No round 3:** if more review/fix work is needed, hand over the findings and
  remedy. A clean final confirmation completes review, not merge approval.

**If round 2 reports a P0, stop before further fixes.** Verify it independently
and report both the original severity and your conclusion. Do not downgrade it
to bypass the stop, even if you disagree. Explain whether the rounds exposed
repeated failure in one area, unrelated failures, or a regression from a fix;
recommend a redesign, split or smaller remedy and wait for a decision. Do not
present this as merge-ready evidence or ask to merge. P1 findings in both rounds
also belong explicitly in the handover, even when fixed.

Test retries do not consume review rounds. A later validation failure requiring
changed code uses the next available review round; once both are spent, report
and wait before further fixes. The budget belongs to the change, not the PR:
splitting, shrinking or replacing a PR does not reset it. Only an explicitly
user-approved remedy starts a fresh budget. An out-of-scope finding is a human
scope decision: keep it open in the handover, not silently discarded or counted
as resolved. It need not force unrelated automatic work, but prevents a claim
that all findings are closed and blocks merge pending that decision.

Examples: round 1 P1 → fix/check → round 2 clean → review complete;
round 1 P1 → fix/check → round 2 P2 → fix/check → one confirmation;
round 2 reported P0 → verify/report → stop. A clean round 1 needs no ritual
second round. Unresolved findings or missing required review block merge;
a draft PR may carry an explicit incomplete-review handover.

## PR delivery

Complete the PR template with criteria, evidence, review disposition and gaps.
Use `Closes #N` only for an issue this PR actually resolves; related work gets a
plain link. Do not paste credentials, profile contents, session data or unredacted process environments.

Push normally; never force-push. Re-check the remote head before updating an
existing PR. If history diverged, preserve the remote branch and use a new
branch/replacement PR linked to the original; do not delete or close the original
without authorization. Bind CI results to the submitted head SHA and report
pending, failed or inaccessible checks honestly.

A PR request authorizes preparing and submitting that PR. It does not authorize
merge, release, rebuilding installed clones, changing login/configuration state,
or messages to others. Maintainer approval is required before merge/release.
Local fixtures do not establish installed-app correctness. For a local-only task,
record review rounds and evidence in the task; no PR or push is implied.
