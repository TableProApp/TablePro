# 0020: Aggregate pull requests are the Forgejo gate unit

- **Status**: Accepted
- **Date**: 2026-10-21

## Context

The lab serializes merge-tier workflows to avoid starving installed GTK and database fixtures. Repeating the full workflow for every ready pull request increases queue time. A combined preflight alone cannot certify the separate PR heads.

## Decision

The maintainer selected aggregate train PRs on October 21. A small explicit batch is composed as one GitHub PR against `linux`. GitHub checks remain required for every constituent PR and the aggregate PR. The exact aggregate head receives one full Forgejo merge-tier gate, replacing separate Forgejo gates for its constituents.

The committed `ci/forgejo-train.json` manifest records version 1, the exact GitHub `linux` base SHA and ordered constituent PR numbers/head SHAs. Each constituent is integrated by a separate two-parent merge in that order. Conflicts stop preparation; no input is silently omitted or updated. Train preparation uses the current clean checkout. No extra worktree is required.

Before gating and immediately before merging, `scripts/check-forgejo-train.py` verifies the manifest, merge history, open PR identities, required GitHub results and unchanged base. Requested changes block acceptance. Before merge it also verifies a successful Forgejo `ci.yml` run at the exact aggregate head. A changed input invalidates the train. The queue owner coordinates GitHub merges and avoids concurrent base pushes during acceptance.

The aggregate PR merges on GitHub with the existing squash method and `--match-head-commit`. Its resulting tree must match the gated aggregate tree. Constituent PRs close as included only after this comparison passes, with a link to the aggregate PR. Issues close only when their acceptance is satisfied; including a partial fix does not close a wider issue.

Individual PR gates remain available for isolated fixes and failure diagnosis. Full runs stay serialized. A failed train is not approval for any subset; split it and gate the resulting heads if necessary. Existing native desktop, package, security and maintainer acceptance obligations remain required.

## Rationale

One aggregate PR gives the batch one exact reviewed and tested head, followed by one merge. Squash changes commit identity, so the post-merge source-tree comparison records the link to tested content. Immutable pins prevent a green result from silently accepting later source changes.

## Consequences

Constituent PRs are closed as included rather than marked individually merged. A stale base or member requires rebuilding and retesting the train. A failing batch can cost additional diagnostic runs. A source-tree mismatch after merge is an incident and stops further acceptance while investigated. Tests or artifacts whose correctness depends on commit metadata require separate review.

## Alternatives considered

- Per-PR Forgejo gates remain correct but repeat the expensive workflow.
- Merging constituent PRs sequentially after testing only the final combination exposes intermediate trees that were not tested. The aggregate PR avoids that sequence.
- Overlapping lab workflows can starve fixtures and are not an accepted shortcut.
- Copying upstream's aggregate-check selector or nightly placement is rejected: it could remove required merge-tier coverage. The GitHub cheap tier and the serialized Forgejo gate stay; version selection and process isolation may be adopted inside those tiers ([upstream main analysis](../archive/upstream-main-analysis-2026-10-20.md)).
