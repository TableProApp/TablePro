# PostgreSQL session outcomes, October 20, 2026

Implementation evidence for [#1186](https://github.com/cozyGarage/BookiE/issues/1186) and [#1187](https://github.com/cozyGarage/BookiE/issues/1187), delivered together in [PR #1190](https://github.com/cozyGarage/BookiE/pull/1190). Findings originated in the [upstream review](../../archive/upstream-next-slices-2026-10-20.md).

## Source and scope

- Audit regression before fix: `718fbd6ff276b37e3eb8517241d82f9dccb9183b`.
- UI regression before fix: `b27f59e8b`, with the savepoint audit fix already applied.
- Fixed code: `375253c0a`.
- Local Linux desktop. Driver tests used isolated PostgreSQL 16 containers; GTK tests used the existing PostgreSQL 17 fixture, private D-Bus and Xvfb.
- These runs establish local behavior. Forgejo acceptance and merge status remain on the PR.

## Failing before

The real guarded PostgreSQL test confirmed rows 2 and 3 persisted after savepoint recovery, then failed because the terminal audit outcome was `RolledBack` instead of `Committed`.

The GTK scenario was rerun against the old UI with the final scripted transaction setup. It failed expecting `Session rolled back`; the accessibility snapshot contained `Session committed`.

The new typed commit regression failed with `Unsupported` before the policy implementation.

## Passing after

| Check | Result |
| --- | --- |
| `bash scripts/preflight.sh` | Passed |
| `cargo test -p tablepro-policy --test session_postgres -- --ignored --test-threads=1` | 11 passed |
| `cargo test -p tablepro-app --lib` | 686 passed, 113 display or fixture tests ignored |
| `bash scripts/test-gtk-widgets.sh` | 76 passed |
| Full PostgreSQL GTK fixture, including transaction outcome scenario | 6 passed |
| Translation catalog, documentation links, ledger, ignored-test inventory, Python syntax and diff checks | Passed |

The focused GTK command was:

```bash
TABLEPRO_GTK_BINARY="$PWD/target/debug/tablepro-app" \
  TABLEPRO_GTK_SCENARIO=postgres_session_commit_distinguishes_aborted_rollback_from_recovered_commit \
  bash scripts/test-gtk-postgres.sh
```

The scenario checks both UI and persisted data. An aborted transaction reports rollback and leaves zero rows. A recovered transaction reports committed and leaves one row. Savepoint approval is answered explicitly. Transaction setup runs as one editor script so the test does not mistake a previous statement's completion label for a later statement's completion.

Policy regressions also cover failed savepoint recovery, savepoint text inside values, missing transactions, audit lockdown, retired sessions and active cursors. Existing unknown-outcome errors and commit retry behavior remain errors rather than successful commit outcomes.
