# PostgreSQL completion routing (#901, #933)

## Source and reproduction

The original linux source merged `public.users` and `public."Users"` in its column cache and split legal quoted names incorrectly. New app regressions failed before the fix: the quoted relation overwrote the unquoted relation, and `public."with space"` became `public."with`.

PR [#922](https://github.com/cozyGarage/BookiE/pull/922) concurrently fixed the direct collision and quote splitter and closed #901. The remaining regression was run against that merged source, linux `d8cdc7a676c4044e71b0bd4b1be2531cf310881d`: the quoted-space case still failed with `public."with` instead of the complete reference. The direct users/Users collision regression passed. The confirmed remaining paths are tracked in [#933](https://github.com/cozyGarage/BookiE/issues/933).

## Completed boundary

Completion reuses the core script lexer to retain quote boundaries, exclude comments/literals and refuse invalid metadata references. PostgreSQL folds only unquoted components. Catalog publication uses the existing dialect quoting helper, and metadata fetches receive separate exact schema/table strings. Other engines retain their identifier delimiters and existing cache comparison while metadata keeps exact spelling.

Alias/qualifier parsing, bare-table suggestions, catalog refresh, browse-tab cache seeding and pending-request deduplication use the same identity rules. Existing connection generation checks remain in place. Ambiguous bare names still refuse a selection; search_path-aware session visibility remains separate work.

## Regression packet

- Unit cases cover users/Users, dots, doubled quotes, spaces, Unicode, reserved words, quoted aliases, whitespace around dots and invalid neighbors.
- Dialect quoting round trips cover PostgreSQL, MySQL, SQL Server, SQLite and ClickHouse.
- Native PostgreSQL fixture creates six exact names and compares controlled column fetches with native SELECT result metadata. This fixture pins existing driver behavior; the app parsing and publication changes fix the defect.
- Completion and dialect round-trip checks, metadata-reference unit cases and the native catalog fixture passed locally.
- Full local preflight, app-specific Clippy, 46 isolated GTK widget tests, documentation links, issue ledger and ignored-test inventory checks passed.
- Exact-head GitHub and Forgejo results are recorded on the PR before merge.

No search_path resolution, new dependency, core contract or policy rule is introduced.

## Remaining UI qualification

Exact proposal activation is separate from metadata identity. The current GtkSourceView word provider and its editor-buffer fallback do not establish complete dialect-quoted insertion. [#934](https://github.com/cozyGarage/BookiE/issues/934) records that source-backed gap and the required actual-provider regression. This change does not claim installed completion activation for arbitrary quoted identifiers.

## CI observation

The post-merge linux sync for #921 reached Forgejo run 485 at `73ac5c6cf7e286ae80b64b3f4371524a81132587`. Only the Ubuntu 24.04 floor job failed; Debian floor passed. The captured log did not expose a GTK scenario or assertion failure. A minimal shell probe confirmed the summary pipeline can exit before printing its fallback tail under `set -euo pipefail`. [#937](https://github.com/cozyGarage/BookiE/issues/937) tracks that diagnostic defect, and [#556](https://github.com/cozyGarage/BookiE/issues/556#issuecomment-6193746472) holds the run observation. The failure was not counted as a passing gate or attributed to PostgreSQL. This follow-up requires its own exact-head gate.

## Merged acceptance

[#938](https://github.com/cozyGarage/BookiE/pull/938) merged as `e528ae5ded453fd34a41513c664d19d397a118f7`, closing #933 and #923. Exact PR head `32752b03ab6756f83af21d50a8921f7ecf07bf6c` passed Forgejo run 493 (all 28 jobs, including both distro floors), GitHub checks, CodeQL and SonarCloud. #932 landed first and its identity regressions were retained/adapted.

The CI diagnostic probe used this control flow:

```bash
set -euo pipefail
false || {
  printf 'unexpected startup error\n' | grep '^FAILED' | tail -30
  printf 'FULL FAILURE TAIL\n'
  exit 1
}
```

Observed: exit 1, with no fallback tail emitted. The logging fix remains #937; it was kept out of the completion change.

Final merged-linux sync: Forgejo run 496 passed all 28 jobs for `e528ae5ded453fd34a41513c664d19d397a118f7`. Both completed fix branches were removed from GitHub, Forgejo and the local branch list.

Research catalogue case PG-26 is covered by the completion identity/reference tests and `completion_metadata_preserves_exact_postgresql_catalog_names`. Cases PG-19 and PG-27 (owning-session visibility and search_path resolution) remain separate candidates, and actual proposal activation remains #934.
