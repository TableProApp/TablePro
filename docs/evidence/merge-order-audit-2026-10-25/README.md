# GitHub merge-order screening, October 25, 2026

Issue: [#1543](https://github.com/cozyGarage/BookiE/issues/1543).

## Scope and method

The read-only scan covered 190 pull requests merged from October 22 through October 25, 2026. It fetched the changed paths and check runs for each pull request's recorded head commit. It excluded a pull request only when all changed paths were Markdown files or under `docs/`. For the other pull requests, it inspected these GitHub contexts:

- `Preflight and sandbox tier (no GTK app)`
- `Fast checks (GTK)`
- `Linux regression gate`
- `flatpak-builder (default)`

For each context with a recorded run, the scan compared the run start and completion timestamps to the PR merge timestamp. If the last run that had started by merge was incomplete, it was recorded as `pending_at_merge`; if no run had started by merge but a later run existed, it was recorded as `not_started_at_merge`; if the run had completed with a failure, it was recorded as `failed_at_merge`.

The script classified `skipped` as complete for this screening calculation. That is not a passing result under BookiE's policy. A skipped, absent or inapplicable context requires path and workflow review before drawing a conclusion. The data records only contexts that the scan could observe; it does not establish which checks were required for each PR or whether the Forgejo acceptance gate passed.

## Result

The scan returned 163 PRs with at least one changed path outside the docs-only exclusion and 27 docs-only PRs. It found no GitHub API errors. Of the 163 code or mixed PRs, 115 had at least one recorded context pending at merge, failed before merge, or first starting after merge. All 115 candidates have at least one changed path outside the docs-only exclusion in the second path fetch; that fetch had no API errors. The snapshot in [`screening-candidates.json`](screening-candidates.json) preserves each candidate's changed paths, PR number, title, head commit, merge time, and observed non-complete context timestamps.

The Git history has two edits to these workflow files in the scan window: [`5edcf3c3d`](https://github.com/cozyGarage/BookiE/commit/5edcf3c3d62af404fee825b24ba126fde48c7c72) raises the GTK/Flatpak toolkit floor and [`669635a06`](https://github.com/cozyGarage/BookiE/commit/669635a062adcbd33532ae86e6647f4ad932b236) hardens checkout credentials. Neither changes the `push` or `pull_request` path filters. Thus all 115 candidates match the recorded non-doc path filter for these workflows. This still does not establish whether a context was mandatory under the GitHub ruleset at each historical merge.

This is a screening list, not 115 individually verified policy violations. The scan did not establish required-check configuration at each historical merge, automation or maintainer intent, nor Forgejo outcomes. The 27 docs-only PRs were excluded from these four code-gate contexts; this does not audit the separate lightweight documentation checks.

Four cases have separate exact-head evidence in the issue comments: [#1338, #1340, #1443 and #1607](https://github.com/cozyGarage/BookiE/issues/1543#issuecomment-6394448599). For those cases, GitHub check timing shows merges occurred before all observed GitHub checks completed. The available evidence does not prove whether the corresponding Forgejo gates passed.

## Next work

1. Review the screening candidates against each PR's changed paths and the workflow conditions in effect at that merge.
2. Recover Forgejo run IDs and results for confirmed cases where the historical records still exist.
3. Decide and implement a merge control that requires applicable GitHub checks and trustworthy Forgejo acceptance before merging. The October 25 ruleset inspection found no required-status-check or deployment rule; no repository settings were changed during this audit.
4. Close #1543 only after the historical review and the chosen control's behavior are evidenced.

The JSON is a dated API snapshot, not a live issue list. Recheck current repository rules, workflows, PR records and issue state before acting on it.
