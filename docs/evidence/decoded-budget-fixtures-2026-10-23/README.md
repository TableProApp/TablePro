# Decoded budget fixtures, October 23, 2026

Issue: [#1469](https://github.com/cozyGarage/BookiE/issues/1469). Base: `662ed2f76`. The issue records the UX handoff for these test files; production drivers and shared limits remain unchanged.

## Failure and cause

The accepted JSON representation change in [#1452](https://github.com/cozyGarage/BookiE/pull/1452) reduces the inline value size. The row budget includes inline cell storage, a row-vector header and heap payload. A million one-integer rows therefore fit below the unchanged 64 MiB byte budget, reaching the million-row cap first.

The existing ClickHouse and DuckDB tests require scalar results to stop before that cap and fail in the baseline Forgejo gate. MySQL's scalar transactional query has the same incorrect assumption. The gate logs prove the failing assertions; they do not establish a product budget failure. A separate MySQL container startup timeout is outside this repair.

## Repair

ClickHouse and DuckDB byte-budget cases now generate 100,000 rows with a 1,024-byte text payload, deliberately exceeding the byte limit before the row cap. They assert nonempty truncation and validate every retained row's numeric sequence and exact payload. Separate scalar cases verify exactly the row cap, first/last values and truncation. MySQL's scalar transaction test now verifies the row cap; its existing 4 MiB payload case separately verifies byte truncation and continued transaction usability.

The shared byte/cell/row limits and all production paths are unchanged. The new tests pin existing intended behavior; this change does not weaken a product contract or raise a limit.

## Validation

- ClickHouse wide-payload byte-budget case passed against an isolated real server.
- ClickHouse scalar row-cap case passed against an isolated real server.
- MySQL scalar transactional row-cap case passed against an isolated real server.
- MySQL existing wide-payload transactional byte-budget case passed and retained transaction usability.
- All 41 DuckDB integration tests passed after the support-module split.
- All 38 Docker-selected ClickHouse cases passed before the support-module split; both moved budget cases then passed again under their final module-qualified names. The remaining non-ignored connection-refusal case is covered by preflight.
- Full preflight and strict affected-driver Clippy passed. The first preflight exposed file-size violations; splitting into existing support-module structure corrected them without raising baselines. Exact-head Forgejo acceptance was pending when this local evidence was recorded.
- Function/comment guards, ignored-test inventory and ledger format passed.

The baseline gate was red at this evidence checkpoint. Do not infer merge acceptance from these focused passes.

## Subsequent status

GitHub PR [#1473](https://github.com/cozyGarage/BookiE/pull/1473) merged at head `21e02cff6b30b9c60531514875e87be8edcf02b0` on 2026-10-23, and GitHub closed issue [#1469](https://github.com/cozyGarage/BookiE/issues/1469). The merged source is an ancestor of the current Linux tree. This packet does not identify the exact-head Forgejo run, so the local results and GitHub merge do not independently establish Forgejo acceptance.

The current ClickHouse, DuckDB and MySQL tests retain separate wide-payload byte-budget cases and narrow row-cap cases. Their source is present in the current tree; this audit did not rerun the Docker-backed driver tier.
