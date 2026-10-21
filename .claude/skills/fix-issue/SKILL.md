---
name: fix-issue
description: >-
  Take a BookiE problem from report to a gated pull request: read the GitHub issue, comment,
  review finding or plain description, find the real cause, write the failing test, fix it,
  run the repository checks and the Forgejo gate, and open the pull request against `linux`.
  Use for bugs, behaviour gaps and small features, whether phrased as "fix #1171", an issue URL,
  a ledger ID such as RV-3, or a pasted complaint (including Vietnamese, for example "sửa lỗi ...").
  Not for release publication, lane reassignment, or work that needs a new ADR first.
---

# Fix issue

One run ends in one gated pull request against `linux` that fixes the reported problem at its cause.

This skill is the order of steps. Every rule it relies on lives in [AGENTS.md](../../../AGENTS.md) and the documents it links. When this file and `AGENTS.md` disagree, `AGENTS.md` wins and this file is wrong.

## The standard decides

- **Root cause, full scope.** Fix every case the cause reaches, not only the reported one (`AGENTS.md`, Principles 2).
- **Failing test first.** The regression test and the fix land in one commit, and the test fails on the unfixed code (`AGENTS.md`, Workflow 1 and Tests).
- **Lane ownership.** Edit only your lane's files. Crossing into another lane needs the handoff recorded on the issue first (`AGENTS.md`, Lanes and ownership).
- **Accepted ADRs constrain the fix.** A fix that would contradict one stops and asks for a decision instead.
- **Explicit maintainer exceptions.** Apply an authorized exception only to its stated scope and record it in the handoff. Continue unaffected work and report any deferred gate as pending; an exception does not prove acceptance or amend an ADR.

Talk to the user in their language. Everything written to the repository is English and follows `AGENTS.md`, Writing style.

## Autonomy

Invoking the skill authorizes: investigate, branch, write the test and fix, run local checks, commit, push the branch to GitHub, run the Forgejo gate and open the pull request.

Ask only when the expected behaviour has two reasonable readings, an accepted contract or pinned test would have to change, or the fix needs another lane's files. Ask once, recommendation first, and keep working on what does not depend on the answer.

Never, even in an authorized run: force-push, rebase a shared branch, merge on Forgejo, push to Forgejo `linux`, start a second gate, change a guardrail test to pass, raise a size or comment baseline, stop a resource you did not start, or publish a release.

## Phase 0: Intake

1. **Read the report.** `gh issue view <n> -R cozyGarage/BookiE --comments`. Note its `lane:*` label and the ledger ID in [docs/known-issues.md](../../../docs/known-issues.md). A review-sourced issue (for example RV-*) is source reading only: the failing test decides whether it is real.
2. **Confirm the lane.** If your lane does not own the files, stop and record a handoff, or hand the issue back.
3. **Make a worktree** beside the main checkout, never inside another agent's. Inspect `git remote -v` and identify the remote whose fetch and push URLs name `cozyGarage/BookiE` on GitHub. Replace `<bookie-remote>` below with that remote name; do not assume `origin` points to BookiE. If no matching remote exists, add one with an unused name and the BookiE GitHub URL.
   ```bash
   git fetch <bookie-remote> linux
   git worktree add ../bookie-<lane>-<slug> -b <lane>/<topic> <bookie-remote>/linux
   ```
   From here on every command runs in that tree (`git -C <tree>`, `cd <tree> &&`).
4. **Write the problem statement** to `<tree>/.analysis/<slug>/problem.md` (ignored by git): what happens, what should happen, the smallest reproduction, engine and version. It survives a compaction or a usage limit.
5. **Choose the mode.** *Direct* when you can point at the line that causes it and the fix stays in one crate. *Full* otherwise, or when unsure: the investigation fans out to roles in [references/roles.md](references/roles.md).

## Phase 1: Investigate

Answer three questions. In Full mode give each to a role, as background agents in one message, each writing its report to `<tree>/.analysis/<slug>/roles/<role>.md` and returning a short digest.

- **Cause** (`trace`): the real code path, the mechanism, and the blast radius across engines, consumers (grid, export, MCP, agentd) and sibling paths.
- **Correct behaviour** (`research`): the governing ADR and spec, the engine's documentation, and the dependency source at the shipped version. Upstream TablePro and dbx are research input, never code to copy without provenance.
- **Related defects** (`hunt`): the same cause elsewhere. Only findings with a concrete failure scenario count. A `verify` role tries to refute each one before it enters scope.

A related defect outside your lane is filed as its own issue with that lane's label, not fixed in this run.

## Phase 2: Plan

Write `<tree>/.analysis/<slug>/plan.md`, under 80 lines:

- the root cause as a mechanism, and refactor or patch with the reason;
- the governing ADR (every type or value change follows ADR 0007) and the [decision checklist](../../../docs/decisions/checklist.md) row;
- files in order, each inside your lane;
- the failing test, its tier from `AGENTS.md`, Tests, and the [validation playbook](../../../docs/validation-playbook.md) layers to run;
- the changelog line if the change is user-facing, and the docs the change makes stale.

In Full mode a `critic` role attacks the plan before you implement.

## Phase 3: Implement

1. Write the test. Run it and keep the failing output.
2. Fix the cause. Keep the change focused; no unrelated cleanup.
3. Run the test again and keep the passing output.
4. A new ignored GTK or keyring test goes into `scripts/isolated-tests.json` and the ignored-test inventory.

## Phase 4: Verify

Run unpiped, narrow first, from the tree (`AGENTS.md`, Validation):

```bash
bash scripts/preflight.sh
bash scripts/test-gtk-widgets.sh                                        # GTK code changed
python3 scripts/check-known-issues.py && python3 scripts/check-doc-links.py   # docs changed
cargo deny check                                                        # dependencies changed
```

`python3 scripts/run-test-layer.py --list` names the layer for drivers, TLS, SSH and release fixtures. A missing prerequisite is reported as not run, never as passed.

## Phase 5: Review

Use an available, authorized independent reviewer for the full diff. Check that the Codex companion or `code-review` skill exists before selecting it. If neither is available, perform a separate self-review pass, report that it was not independent, and leave any required independent review pending while continuing authorized preparation. Never report an unavailable review as completed. Add a security pass when the change touches `crates/policy`, `crates/mcp`, `crates/transport`, `crates/ssh`, `crates/storage`, SQL construction or secrets: injection, credential exposure, policy bypass, missing terminal audit state. Fix every real finding, re-verify, and review again until a round finds nothing real.

## Phase 6: Ship

1. Stage explicit paths only, never `git add -A` or `.`, and compare `git diff --cached --stat` with the plan.
2. Commit with a single-line Conventional Commit subject (`AGENTS.md`, Changelog and commits).
3. Merge the latest GitHub `linux` into the branch; never rebase. Regenerate `Cargo.lock` on conflict.
4. Push the branch to GitHub, then gate it: `bash scripts/forgejo-gate.sh <branch>`. One gate at a time; a GTK or driver failure seen while another gate ran is inconclusive until re-run alone.
5. Open the pull request against `linux` with `.github/pull_request_template.md`. State which lane gates and merges it.

## Phase 7: Report

At most eight lines, in the user's language: the pull request link, what it fixes, the root cause in one sentence, the failing-then-passing test, the gate result, and anything left for the maintainer or another lane.
