# B3 type and consumer work board

The shared technical standard is [ADR 0007](decisions/0007-type-and-value-preservation.md). Open B3 work lives on [Bookie Project #3](https://github.com/users/cozyGarage/projects/3) with **Lane = B3** (label `lane:b3`). The [sprint](bookie-0.2-sprint.md) owns order and acceptance. Case proof lookup is [value-contracts.md](value-contracts.md).

This page keeps the accepted-refusal list and the bounded case record. Task status and retest signals are on the project. The pre-migration board (retest table, engine remaining-scope matrix and long evidence narrative) is in [archive/type-contract-strategy-pre-project-migration-2026-10-12.md](archive/type-contract-strategy-pre-project-migration-2026-10-12.md). Earlier narrative is in [archive/type-contract-history.md](archive/type-contract-history.md).

## Where to work

| Need | Go to |
| --- | --- |
| Open B3 issues and status | [Project #3](https://github.com/users/cozyGarage/projects/3) filtered by Lane B3 |
| Ledger ID to issue map | [known-issues.md](known-issues.md) |
| Case evidence index | [value-contracts.md](value-contracts.md) |
| Engine remaining-scope matrix (dated) | [Archived board](archive/type-contract-strategy-pre-project-migration-2026-10-12.md#current-evidence-and-next-targets) |

## 0.2.0 accepted explicit refusals

The maintainer accepted these named, tested refusals out of scope for 0.2.0. They remain safety requirements, not exact-support claims. Every other in-scope row, including untested combinations, requires exact support before B3 closes.

| ID | Accepted gap | Evidence |
| --- | --- | --- |
| B3-OOS-PG-1 | Built-in ranges/multiranges other than `int4range` and `int8range`, geometric values other than `point`, named composites and native `money` (`int4range`, `int8range` and `point` read as server text since #694) | [Ranges](archive/value-contract-history.md#postgresql-built-in-range-family-refusal), [geometry](archive/value-contract-history.md#postgresql-geometric-types-exact-server-oracle-and-visible-refusal), [composites](archive/value-contract-history.md#postgresql-composite-explicit-refusal), [money](archive/value-contract-history.md#postgresql-money-safe-refusal) |
| B3-OOS-PG-2 | Closed by #694: `json[]`/`jsonb[]` read as the server text and are written through text. The refusal history is kept | [JSON array contracts](archive/value-contract-history.md#postgresql-array-checkpoint) |
| B3-OOS-DUCK-1 | Named nested collection shapes containing unsigned values outside decoder support | [Nested unsigned values](archive/value-contract-history.md#duckdb-nested-uhugeint-refusal-boundaries-2026-09-30) |
| B3-OOS-DUCK-2 | Sub-microsecond edits to lower-precision temporal columns | [Edit precision refusal](archive/value-contract-history.md#duckdb-timestamptz-grid-edit-precision-boundary) |
| B3-OOS-MYSQL-1 | Spatial and too-wide `BIT(64)` values as editable grid cells | [Spatial](archive/value-contract-history.md#mysql-spatial-bytes-in-the-gtk-grid), [BIT](archive/value-contract-history.md#mysql-signed-and-unsigned-integer-grid-parser-2026-09-30) |
| B3-OOS-MYSQL-2 | MySQL `TIMESTAMP` instant decoding in a non-UTC dedicated session | [Session contract](archive/value-contract-history.md#mysql-native-time-zero-date-and-year-checkpoint) |
| B3-OOS-MSSQL-1 | `money`/`smallmoney` and exact per-cell `sql_variant` base-type preservation | [Variant](archive/value-contract-history.md#sql-server-sql_variant-metadata-refusal), [money](archive/value-contract-history.md#sql-server-money-float-decoding-refusal) |
| B3-OOS-CH-1 | Tested ambiguous/out-of-range `DateTime64` values and nested shapes refused by type-less consumers | [Nested consumers](archive/value-contract-history.md#clickhouse-nested-value-consumer-boundary-2026-09-30), [DateTime64 bounds](archive/value-contract-history.md#clickhouse-datetime649-server-boundary-behavior-2026-09-29) |
| B3-OOS-MONGO-1 | BSON DateTime grid edits finer than one millisecond | [DateTime precision](archive/value-contract-history.md#mongodb-bson-datetime-grid-edit-precision) |
| B3-OOS-REDIS-1 | Pub/Sub, `MONITOR` and `CLIENT TRACKING` through the one-shot query interface | [Redis refusals](archive/value-contract-history.md#redis-pubsub-and-monitor-stream-refusal-2026-09-29) |

## Bounded case record

Use one record per selected case in the case evidence or owning GitHub issue:

```text
ID / owning sprint packet:
Engine + version; native type + declared metadata:
Consumer + session/configuration; boundary input:
Outcome: exact typed | exact text fallback | explicit refusal | untested
Existing evidence: SHA/fingerprint + selector + report/artifact (or absent)
Independent native value/type oracle and mutation/refusal postconditions:
Smallest remaining gap / next action; affected files and layer ownership:
Status: open | reproduced | fixed with named proof | blocked/unrun acceptance
```

Use [value contracts](value-contracts.md) and the B3 board for current candidate boundaries. The [archived scenario survey](archive/b3-test-scenario-survey.md) records reusable test patterns and their source provenance. Follow the [validation playbook](validation-playbook.md#turn-every-finding-into-a-regression) for execution. A defect needs initial failure, narrow correction and valid/invalid neighbors. Native tests assert stored kind/value and unchanged siblings. Register selectors/fixture ownership and preserve sanitized evidence. Keep unavailable reports and mutation uncertainty explicit.

Oracle/new engines are later driver projects. They must follow ADR 0007 with their own native semantics; another engine's fixtures are not their proof.
