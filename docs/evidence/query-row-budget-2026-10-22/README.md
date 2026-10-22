# Query row decoding budget, October 22

Status: local candidate; not committed, published or accepted by Forgejo.
Owning issue: [#1382](https://github.com/cozyGarage/BookiE/issues/1382).

## Defect and change

The result budget formerly checked rows after converting every cell into an owned domain value. An oversized row could be discarded after creating a second large allocation. The candidate checks raw payload size and cell count before decoding, then checks decoded storage before retaining the row. PostgreSQL, SQLite, ClickHouse and MySQL use the shared helper. Exact decoding remains in the existing driver decoders.

The raw check cannot bound the database library's wire buffer or native engine allocations. Decoded values, including structured JSON, can expand beyond their raw representation. The final decoded-size check bounds retention but does not prevent that expansion during decoding. DuckDB, SQL Server, MongoDB and Redis are outside this candidate.

## Recorded measurements

These historical local measurements are transcribed from the owning issue's October 22 investigation comments. The tested baseline was `ad9bb1447163c848919616773ab0971c5a2d2135`; the candidate was an uncommitted patch. Raw profiler outputs are not included in this record, so the table is a recorded observation rather than a reproducible benchmark artifact.

| Scenario | Baseline peak RSS | Candidate peak RSS | Interpretation |
| --- | ---: | ---: | --- |
| PostgreSQL, one 64 MiB + 1 byte text cell | 226,564 KiB | 160,032 KiB | 66,532 KiB lower in the client test process |
| SQLite, equivalent oversized-cell test | 215,076 KiB | 214,996 KiB | No demonstrated reduction; native allocations dominate |
| GTK app, 100,000 ordinary SQLite rows | 248.5 MiB | 248.1 MiB | No demonstrated reduction |

PostgreSQL runs took approximately 1.6 seconds including container startup. RSS excludes the PostgreSQL container process. Ordinary SQLite application query completion was 409 ms baseline and 446 ms candidate, with only one run of each; this does not establish a timing regression or improvement.

A separate 1,000-step accessibility scroll stress test changed position every 5 ms. Approximately 45% of CPU samples were in repeated GTK widget allocation. This does not establish normal interactive scroll latency.

## Verification and acceptance

The candidate worktree was advanced to Linux `a070efdd235e5586185b43806f9ddbdb06e8c619`. Full preflight passed there: 2,055 unit tests, 2,058 sandbox tests and the Redis cancellation regression. Earlier focused PostgreSQL, SQLite, ClickHouse and MySQL checks passed. The PostgreSQL oversized-cell regression checks explicit truncation and a subsequent query on the same connection.

The shared unit regression additionally checks that a small raw row which expands beyond the remaining decoded budget is rejected, and that the rejected row does not consume the budget needed by a subsequent small row.

The earlier claim that MySQL preflight was reverted is superseded: borrowed SQLx byte decoding is present in the candidate, and its transaction byte-budget/reuse regression passed, including the subsequent `SELECT 42`.

Remaining acceptance: publish and review the patch; run GitHub checks and the exact committed candidate through Forgejo; verify results on the current Linux baseline. The wider CPU and memory work remains open under [#1272](https://github.com/cozyGarage/BookiE/issues/1272).

## Repeated comparison with preserved output

Three alternating baseline/candidate runs of the oversized PostgreSQL cell and connection-reuse regression passed. The baseline median peak RSS was 226,224 KiB; the candidate median was 158,704 KiB. See [measurements](measurements.json) and the accompanying `.time` and `.txt` files. These test-process measurements exclude database container memory.

An initial shared-target attempt reused the baseline executable for both variants. Those invalid observations are retained in [invalid-shared-target](invalid-shared-target/README.md). The corrected candidate was rebuilt after cleaning only the core and PostgreSQL package artifacts; distinct executable SHA-256 values were verified before measurement.
