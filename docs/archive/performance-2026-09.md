# PostgreSQL browse measurements — September 2026

Base: `7d8288132`. Candidate: `751a458293eca384e8747d7661db1fe9f713401b` (source hashes match the measured stabilization tree). PostgreSQL 18.6 on an isolated localhost TLS connection, same machine and Rust 1.93.1 development build for both binaries. This is a driver benchmark, not a GTK responsiveness or release-build benchmark.

The baseline binary was rebuilt with the PostgreSQL driver source from `7d8288132`; the candidate uses streaming decoding and caches type names once per result. Both use the same committed benchmark example. No release-profile or server SQL rewrite was introduced.

## Method

`crates/release-tests/examples/browse_benchmark.rs` creates a uniquely named million-row table in an explicitly enabled disposable fixture and drops it afterward. Each scenario runs in its own process, with one warm-up and five measured samples. First/filtered/deep pages return 100 rows; deep uses the existing keyset path at id 900000; wide returns 200 columns. At the time of these measurements, capped queries requested 1.1 million rows and asserted exactly `MAX_QUERY_ROWS` (one million), a truncation flag and preserved data. The later decoded-result memory budget can truncate before that row limit.

A separate connection samples server activity every 5 ms and continues until the tagged statement is inactive. `sampled_active_ms` is an approximate observed span including transfer/backpressure, not the engine's reported execution time; null means the query was not sampled. VmHWM is process high-water RSS, including fixture setup and the warm-up. It does not reset between attempts; compare the scenario peak, not per-attempt memory deltas.

Final comparison ran after builds finished. Normal desktop background processes remained. Absolute sub-millisecond differences are not meaningful. Raw samples: [before](../evidence/2026-09-stabilization/postgres-before.jsonl), [after](../evidence/2026-09-stabilization/postgres-after.jsonl).

| Scenario | Before median ms | Before peak MiB | After median ms | After peak MiB |
|---|---:|---:|---:|---:|
| first | 1.37 | 12.99 | 1.35 | 12.64 |
| filtered | 2.11 | 12.75 | 2.22 | 12.68 |
| deep | 1.54 | 12.67 | 1.36 | 12.67 |
| wide | 14.02 | 17.07 | 14.06 | 15.23 |
| capped | 2748.22 | 449.53 | 3077.39 | 188.92 |

## Decision and limits

For the capped result, peak RSS falls by about 58%, from approximately 450 MiB to 189 MiB. The development-build median rises about 12%, from 2.75 s to 3.08 s. Retain this as a memory optimization for large results, not a latency improvement. Small-page results are broadly unchanged. Release-build CPU/throughput profiling remains an explicit follow-up before a latency claim or further optimization.

The old collector retained every PostgreSQL wire row and then allocated the complete decoded matrix. The new collector decodes while reading, drops each wire row, and computes type names once per result. Row-cap, truncation, column/value preservation, and connection-reuse regression tests cover the shared query path. Empty-result metadata behavior is unchanged.

## Reproduce

Start the disposable PostgreSQL release fixture, or a compatible isolated TLS server with its material/port environment overrides. Never point this example at a production database: it creates a million-row table for each scenario.

```bash
cd linux
cargo build --locked -p tablepro-release-tests --example browse_benchmark
export TABLEPRO_FIXTURE_POSTGRES_RELEASE=1
# If using the temporary local server instead of the Docker fixture:
# export TABLEPRO_FIXTURE_PROXY_PORT=55433
for scenario in first filtered deep wide capped; do
  ./target/debug/examples/browse_benchmark "$scenario"
done
```

Run baseline and candidate builds to completion before sampling either. Keep the same compiler, optimization profile, database, machine and observer settings. Evaluate a release-profile run separately; do not compare a release binary to these development numbers.
