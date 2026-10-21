# PostgreSQL gate repair, October 21

## Source and scope

Forgejo run 850 tested `96503323d`. Its PostgreSQL driver and PostgreSQL release jobs failed. The repair starts from Linux `abf3a2205`, which includes the merged test-file split and release changelog. Neither failure establishes an infrastructure fault.

## Pooled connection reset

[Issue #1288](https://github.com/cozyGarage/BookiE/issues/1288) tracks an invalid backend-affinity assumption. A four-connection pool may select another backend while its asynchronous release hook runs. Separate public operations therefore cannot establish that cleanup happened on the mutated backend.

The production pool configuration moves unchanged into a shared source module. The integration regression uses that same configuration with one test-owned connection. Each of eight cycles verifies changed `search_path` and an existing temporary table before release. Reacquisition must return the same PostgreSQL backend PID, the original search path and no temporary table.

Five consecutive focused runs passed against PostgreSQL 16. Replacing `DISCARD ALL` temporarily with `SELECT 1` made the regression fail on the leaked `pg_catalog` search path. The production hook was restored. Driver all-target Clippy passed. Independent source review found no blocking issue.

This checks the actual shared release-hook configuration. It does not establish backend affinity for ordinary public driver operations.

## Retired editor session

[Issue #1294](https://github.com/cozyGarage/BookiE/issues/1294) tracks an installed acceptance test that expects an execution error after SSH recovery. Session lexical-settings acquisition now refuses a retired session before SQL dispatch. The application reports that refusal without producing the completion label the test awaits.

The acceptance must observe a fresh refusal, independently confirm that PostgreSQL received no persisted writes and verify that reopening Session permits a new query. A result panel left over from the interrupted query is insufficient proof of a fresh refusal.

The original installed scenario failed locally after 32.325 seconds waiting for the completion label. The repaired scenario passed in 29.736 seconds, including its independent zero-row and reopened-session checks. The fixture script also passed 64 Rust SSH, mTLS and release tests. Its containers were removed after completion. Python syntax and the GTK runner and workflow harness tests passed.

## PgBouncer expectation found during full validation

The first full local PostgreSQL run passed 286 cases and failed the no-prepared-statement-tracking PgBouncer case. Its create, twenty parameterized inserts, count and transaction all succeeded, but the test required failure. An isolated repeat reproduced that expectation failure. [Issue #1295](https://github.com/cozyGarage/BookiE/issues/1295) records it.

The regression now accepts the existing verified successful workload or an actionable prepared-statement conflict. Each error must carry the pooler configuration hint; successful stage results must retain their expected values. The fixture stops immediately after a failed create or insert, so a partial insert sequence is not compared with the complete twenty-row count. Other errors and incorrect successful outcomes remain failures. The known limitation describes possible conflicts rather than promising a failure on every workload. This does not qualify transaction pooling for session-dependent editor features.

## Final local verification and remaining acceptance

The final full local PostgreSQL integration run passed all 287 cases in 124.13 seconds. All three PgBouncer scenarios passed in five consecutive repetitions. Final local preflight and driver all-target Clippy passed. Documentation links, issue-ledger checks and ignored-test registration checks passed. Independent review covered both the reset regression and the installed acceptance change; the PgBouncer fallback was tightened in response to review.

Commands:

```bash
bash scripts/preflight.sh
cargo clippy --locked -p tablepro-driver-postgres --all-targets -- -D warnings
cargo test --locked -p tablepro-driver-postgres --test integration -- --include-ignored --test-threads=1
TABLEPRO_GTK_SCENARIO=postgres_ssh_tunnel_loss_retires_session_and_reconnects bash scripts/test-postgres-release.sh
```

The complete Forgejo gate remains pending. This document does not qualify the merged Linux baseline as green. Gate and merge outcomes belong to the repair pull request.
