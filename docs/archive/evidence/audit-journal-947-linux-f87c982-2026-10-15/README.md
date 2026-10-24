# Audit journal lockout and scaling probe

Source: `f87c982cb0bf55a08ff689a39ee4b31601acac19` (`fork/linux`). Environment: Rust/Cargo 1.98.1, Linux 7.2.5-3-omarchy, AMD Ryzen 7 7730U. The measurements used a temporary local journal and are single-run observations, not a benchmark suite.

## Recovery reproduction

A disposable storage integration probe wrote a durable `Mutation` intent for connection A, dropped the journal, reopened it, and attempted a durable `Mutation` intent for connection B. Recovery retained the unresolved operation, and the second connection's write intent returned an error. The probe passed on current Linux.

The source confirms the application-wide effect: `AuditRuntime::from_journal` initializes `AuditState::with_governed_writes_disabled()` when any unresolved write exists, and `agentd` refuses startup when `has_unresolved_writes()` is true. The persisted intent becomes an `Unknown` outcome and remains unresolved on later opens. No resolution action was found in the GUI, storage API, or agentd.

This scope needs a decision before implementation. ADR 0008 says an unknown write blocks that connection and that unresolved durable obligations remain fail-closed. ADR 0010 separately requires unmatched process-wide bundle operations to remain unresolved for review. The current journal rejection and startup checks apply the lockout globally. A recovery flow must preserve the original `Unknown` record and must distinguish a connection-scoped write from a process-wide administrative action.

## Append and history measurements

The disposable probe appended simple non-durable `Read` outcome records. Each append still ran the full chain verifier. `recent(10)` ran after the journal reached the listed size.

| Records | Append total | Average per append | `recent(10)` |
| ---: | ---: | ---: | ---: |
| 100 | 294 ms | 2.943 ms | 7 ms |
| 500 | 6.229 s | 12.459 ms | 34 ms |
| 1,500 | 53.714 s | 35.809 ms | 101 ms |

The 100-to-500 append run grew about 21 times for five times the records; the 500-to-1,500 run grew about 8.6 times for three times the records. This supports the expected quadratic total work from a full journal verification on each append. The probe used non-durable read outcomes, so it excludes the additional sync cost of durable write intents. The timings are specific to this host and filesystem.

Code inspection matches the measurement: each append calls `verify_locked`, which reads and hashes the full journal under the exclusive file lock. `recent(limit)` verifies the chain, reads the journal a second time, deserializes every record into a vector, then keeps the last `limit` events. There is no journal rotation or checkpoint in this path.

No production code changed. See [issue #947](https://github.com/cozyGarage/BookiE/issues/947) for the decision and measurement follow-up. This is local source evidence only, not Forgejo or installed acceptance.
