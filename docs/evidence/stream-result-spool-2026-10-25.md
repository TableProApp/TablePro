# Stream result spool local evidence

- **Branch**: `ux/stream-result-spool`
- **Base**: `fa50f371c` (`fork/linux` was fetched; the branch contains the current Linux tip)
- **Implementation commits**: `14634cc`, `fc2ec18`, `a799f05`, plus the incremental-encoding follow-up on this branch
- **Environment**: Arch Linux / Omarchy, PostgreSQL 17.11 fixture, installed local GTK test harness
- **Acceptance**: #554, same-execution navigation through all fetched PostgreSQL result pages

## Checks

- `cargo test -p tablepro-app-services --lib stream_result_spool`: 9 passed. Coverage includes typed round trips, exact float bits and JSON precision, repeated-load idempotency, page order, tamper refusal, shared quota, cleanup, and stopping serialization when the quota is reached.
- `cargo clippy --locked -p tablepro-app --lib --tests -- -D warnings`: passed after addressing the first hosted fast-check findings with context types and clearer iterator/control-flow code.
- `bash scripts/ci-local.sh full`: passed after those changes. This ran 2,921 unit tests (220 skipped), 291 sandbox tests and one Redis sandbox integration. All validation guards passed.
- `bash scripts/preflight.sh`: passed on the spool implementation before the final Clippy cleanup, with 509 script-harness tests, 2,125 unit tests, 291 sandbox tests and one Redis sandbox integration. Its first run had one timing failure in `approval_wait::time_spent_in_approval_is_reported_inside_a_tracked_run`; the focused test passed, and the full preflight passed on rerun.
- After correcting the isolated-test selector and mapping the page in `a_loaded_page_replaces_only_its_matching_generation_placeholder`, `bash scripts/preflight.sh` passed again: 509 script-harness tests, 2,125 unit tests, 291 sandbox tests and one Redis sandbox integration. `bash scripts/test-gtk-widgets.sh` also passed all 166 registered GTK widget tests. The page test now exercises the existing lazy-grid contract by mapping the page before completion and waiting for the grid to appear; the stale-generation assertion remains.
- `bash scripts/ci-local.sh full` passed after those test harness changes: 2,921 unit tests (220 skipped), 291 sandbox tests and one Redis sandbox integration. Debian package validation was skipped because this host is Arch Linux and does not have `dpkg-deb`.
- `cargo build --profile ci --locked -p tablepro-app --bin tablepro-app`: passed after the incremental encoder change.
- `python3 scripts/check-known-issues.py`, `python3 scripts/check-doc-links.py`, `python3 scripts/inventory-ignored-tests.py --check`, `cargo fmt --all -- --check`, and `git diff --check`: passed.

The installed GTK scenario passed after rebuilding the final local source state (26.079 seconds):

```bash
PATH=/usr/bin:/bin:/home/trung/.cargo/bin \
TABLEPRO_GTK_BINARY=/home/trung/Projects/bookie-554-audit/target/ci/tablepro-app \
TABLEPRO_GTK_SCENARIO=postgres_large_stream_pages_round_trip_from_spool \
bash scripts/test-gtk-postgres.sh
```

It streamed 100,000 rows with 2 KiB text cells, navigated backward through every 5,000-row page, reloaded earlier pages from the spool, returned to the first page, and verified that the transaction marker stayed unchanged after visiting other pages.

The first GitHub fast-check run found an empty-page identity regression; it was fixed in `a799f05`. The next run on that commit failed Clippy in newly changed editor functions and a test helper. Those findings were fixed in the incremental-encoding follow-up, and `ci-local.sh full` passed locally afterward. GitHub must rerun checks on the new commit. Forgejo has not run; the maintainer handles that gate. PR #1621 and issue #554 remain open. This evidence does not approve ADR 0025 or close #554.

The encoder writes MessagePack directly into encrypted 64 KiB chunks and refuses further output once the shared spool quota is exhausted, avoiding a second full-page serialization buffer. Exact arbitrary-precision JSON round trips still require rendering one JSON cell to temporary text during encoding. The existing page itself remains live until the editor acknowledges the append.

`python-atspi` is installed from Arch's `python-atspi` package; the GTK scenario uses `/usr/bin/python3`. Debian package validation is skipped because this host is Arch Linux and does not have `dpkg-deb`.
