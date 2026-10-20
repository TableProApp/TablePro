# Forgejo train gate proposal

## Problem

The Forgejo merge tier is serialized because the lab has limited capacity. Running it once per pull request makes a batch of otherwise-ready changes wait through repeated setup and queue time. `scripts/forgejo-train.sh` already combines branches for one run, but its result is currently only a preflight: the project requires a gate on every pull request head.

## Proposed acceptance model

Create one GitHub train pull request for a small, explicit batch and gate that pull request's exact head once. This changes the unit of merge from an individual PR to a reviewed batch, so it must be adopted before it replaces individual gates.

1. Select constituent PRs that have review approval and green required GitHub checks. Record their numbers, exact head SHAs and order. Exclude drafts and changes needing separate manual or installed acceptance.
2. Pin the current GitHub `linux` SHA as the train base. Compose a train branch from the exact selected heads in the recorded order. A conflict, moved head, or unmergeable PR fails train creation; never skip or silently replace an input.
3. Open one aggregate GitHub PR from that train branch to `linux`. Its PR checks and review must pass. Run the full Forgejo merge tier against this exact aggregate PR head and record the base SHA, constituent PR/head list, train head SHA and Forgejo run ID.
4. Before merge, confirm that GitHub `linux` still has the pinned base, the aggregate PR head is unchanged, and all constituent PR heads/checks/approvals are unchanged. Otherwise rebuild the train and gate its new head.
5. Merge the aggregate PR on GitHub with `--match-head-commit` and the required squash method. Confirm the resulting `linux` tree SHA equals the tested train head's tree SHA. Close constituent PRs with a link to the merged train PR; their changes are included in that single merge.

The aggregate PR is the exact gated head. Its squash commit has a different commit SHA but the same tree when the base and head have not moved. Keep the base freshness check and tree comparison as hard requirements. Tests that intentionally depend on commit metadata need separate review before this model is used.

## Safety and limits

- Keep GitHub's fast checks and reviews per PR. The train replaces only the serialized Forgejo merge-tier runs.
- Keep the current `forgejo-gate.sh` serialization and the shared `bookie-lab` workflow concurrency group. A train is one run in that queue, not a way to run overlapping workflows.
- Use a unique immutable remote ref for each train. The current mutable `refs/heads/train/gate` can be overwritten by another invocation before the gate lock is acquired; replace it before concurrent train preparation is allowed.
- Do not remove or add a constituent PR after the aggregate head passes. Any batch change requires a new head and a new run.
- A failed train does not identify which PR caused the failure. Split the batch and gate the smaller trains, or gate PRs individually to isolate it.
- This model does not provide strict queue ordering. Forgejo concurrency is best-effort, and old workflow runs created before the shared group was active must drain first.
- Runs that include changes requiring independent package, UX, security or maintainer acceptance still need those checks. A train cannot waive a tier just because the aggregate run is green.

## Required implementation before adoption

- Replace mutable train refs with collision-resistant refs and serialize train creation through result collection.
- Add a manifest of exact PR numbers, head SHAs, base SHA, order, train commit/tree SHA and Forgejo run ID.
- Add a dry-run assertion that each requested head is present exactly once, conflicts fail the train, and the synthesized tree is deterministic for the same inputs.
- Automate pre-merge freshness checks and post-merge tree comparison. A mismatch is an incident: preserve the run and merge evidence, then investigate before accepting further changes.
- Update `AGENTS.md`, the validation playbook and `docs/testing.md` together so they describe the new acceptance rule. Preserve individual gating as the fallback for failed, stale or non-batchable PRs.
- Trial the protocol on a small batch with low-risk changes before relying on it for routine merges.

## Decision needed

The maintainer must accept tree-based train evidence in place of an individual Forgejo run at each PR head. Until then, `forgejo-train.sh` remains a preflight only and every PR continues to need its own required gate.
