# Keyboard menu routing acceptance

[PR #1519](https://github.com/cozyGarage/BookiE/pull/1519) merged as `9950bcbd825450babe0ceaa6ddd781259faf2034`. Forgejo run 926 passed all 28 jobs for the exact head `9f749bb7c34d91458a9272a75127cde90bfee13e`. Required GitHub checks passed. Scheduled and Forgejo-owned jobs skipped on GitHub are not treated as test passes.

Post-merge verification compared the merged runtime, tests, scripts and CI against that head and found no difference. Base changes before the merge were documentation only. This uses the maintainer's explicit docs-only freshness exception; full-tree equality is not claimed. [Acceptance data](acceptance.json) records the checks and comparisons.

The separate [measurement](../grid-keyboard-menu-routing-2026-10-23/README.md) supports only its development-build SQLite fixture. Broad performance work in #1315 remains open.
