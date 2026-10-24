# Test quality and performance contracts

Part of [testing](testing.md), which holds the test tiers, runner and fixtures.

## Measuring how good the tests are

The [September CI audit](archive/ci-audit-2026-09-27.md) distinguishes executed tests, intentional exclusions and packaging-only green runs. Mutation and coverage run on a schedule. The unit-tier line-coverage score has its own ratcheted floor in `baselines/coverage-floor.txt` (59%; 59.41% measured on 2026-10-11). The nightly workflow separately measures Docker suites for PostgreSQL, MySQL, SQLite, MongoDB, Redis and ClickHouse against `baselines/coverage-floors-crates.txt`. Installed GTK is outside both coverage reports. These floors do not measure every crate or prove assertion quality; the current manual measurements and unmeasured areas are recorded in [#782](https://github.com/cozyGarage/BookiE/issues/782). Mutation survivors need investigation. Dated first-run mutation notes are in [testing history](archive/testing-history.md#mutation-first-run-notes-2026-08-22).

### Mutation testing

```bash
cargo install cargo-mutants --locked
cargo mutants --package tablepro-core --test-tool cargo -- --lib
cargo mutants --package tablepro-core --file crates/core/src/sql_lex.rs --test-tool cargo -- --lib
```

Prefer `core` and `policy`. GitHub's Linux test quality workflow mutates `core`, `policy`, `ssh`, Redis and selected PostgreSQL decoders. The Forgejo nightly also mutates `agentd`, `transport` and `app-services`; agentd mutations run against its library, binaries and integration tests, including saved-connection lookup. Forgejo compares missed mutants with per-package baselines and fails on unaccepted survivors; GitHub reports survivors for review. The PostgreSQL mutation job covers numeric, array, temporal and binary-text decoders with unit tests; Docker-backed value regressions stay in the driver layers. Follow [ADR 0007](decisions/0007-type-and-value-preservation.md) and the [B3 board](type-contract-strategy.md). Equivalent mutants and timeout findings are discussed in the archived first-run notes above.

### Coverage

```bash
cargo install cargo-llvm-cov --locked
rustup component add llvm-tools-preview
cargo llvm-cov --workspace --exclude tablepro-driver-duckdb --exclude tablepro-app \
  --lib --bins --tests --summary-only
```

Exclude app and fixture tiers so the map does not depend on Docker or a display. Coverage shows execution, not assertion quality.

## Performance regression contracts

Resource regressions belong in the existing unit and gtk-widgets tiers. Prefer retained-byte/page limits, ownership release, shared payloads, lazy materialization and operation counts over fixed millisecond or process-RSS assertions. Resource budgets are contracts: increasing a constant must not silently relax its test.

| Risk | Regression coverage |
| --- | --- |
| A stream accumulates every received page | A 20,000-page sequence of small pages remains navigable within the byte budget and releases pages after the final owner drops them; 1,000 empty pages do not accumulate payloads. |
| The retained-byte budget drifts | The exact 64 MiB boundary retains two half-budget pages; one additional row evicts an old page. Existing coverage keeps an oversized newest page explicitly. |
| Snapshots duplicate payloads or retain retired data | Snapshot payload identity, external-owner release, terminal-state ownership and rejected-page release tests. |
| Catalog checks return to a full scan | Four lookups against 10,000 names perform at most 16 identifier normalizations, counted only in test builds. Prefix eligibility and cached columns remain covered. |
| Completion caches retain objects after closing | A discarded model releases cached proposals across 1,000, 10,000 and 50,000 candidates; a held proposal lives only until its final owner drops. |
| Closed editors continue delayed metadata work | A discarded refresh cancels its callback and releases captured state after a 128-trigger burst. The existing debounce test requires one callback for a typing burst. |
| Replacing grids accumulates cells, menus or selections | Repeated alternation between editable and read-only rendered grids requires every retired widget and result to be released. |
| Wide cells restore expensive GTK layout | A 32-case text/JSON matrix pins the 512-character visible limit across ASCII, UTF-8, emoji and NUL boundaries while preserving the stored sample. Existing rendered-height tests cover multiline cells. |

The [2026-10-24 evidence](evidence/performance-regressions-2026-10-24/README.md) records source tests and controlled regression injection. These tests pin existing behavior; they do not introduce new product limits.

The [performance and acceptance scenario matrix](performance-acceptance-scenarios.md) maps those deterministic guards to host profiling, PostgreSQL workloads and installed GTK checks. It records which cases have a maintained command and which remain manual or unautomated; it does not add a CI tier.

Run the non-display application checks locally with:

    cargo test --locked -p tablepro-app --lib stream_pages::performance_tests -- --test-threads=1
    cargo test --locked -p tablepro-app --lib preview_matrix
    cargo test --locked -p tablepro-app-services --lib completion

Run display-dependent contracts with bash scripts/test-gtk-widgets.sh. Fast preflight excludes application library tests; a preflight pass alone is not evidence that these application contracts passed. Forgejo's existing unit job includes application library tests, and widgets runs registered display tests. No new CI job or nightly-only dependency is needed.

These structural guards do not bound total process RSS, allocator caches, driver buffers, GPU resources or arbitrarily long sessions. Measure those separately on the changed workload and display backend. A watchdog around an asynchronous lifecycle test is not a throughput target.

## Browse performance

See [the September measurements](archive/performance-2026-09.md) and the `browse_benchmark` example in the release-test crate. One warm-up plus five measured samples cover first, filtered, deep, wide and capped result sets. Run each case in a separate process against a disposable fixture, with builds complete before measuring. Report memory improvements and latency regressions separately.

The [bug and consistency audit](archive/bug-consistency-2026-09.md) records the newer targeted mutation findings. cargo-mutants creates its report beneath `<output>/mutants.out/`; CI summaries distinguish missing reports from zero findings and retain the measurement step outcome.
