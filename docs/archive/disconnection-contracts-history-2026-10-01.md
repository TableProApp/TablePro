# Disconnect and cancellation verification history: 2026-10-01

These are historical local test-layer results. They prove only the listed source snapshots and do not establish acceptance for the current branch. The reports were written under ignored `target/quality/` paths and may not exist in a fresh checkout.

| Source | Layer result | Report |
|---|---|---|
| `eef09bbd13cf92f21f91d5691ba665eb4ecda24a` | `drivers` passed in 969.9 seconds; 223 tests across PostgreSQL, MySQL, SQL Server, ClickHouse, MongoDB, Redis, MCP, socket and SSH suites; no failed or ignored tests among executed tests. | `20261001T025640026732Z-layers/report.json` |
| Working tree based on `ed07e553e9f7e5a6f48bcd3b2d822092987e5308` | `drivers` passed in 949.8 seconds; 225 tests across driver, MCP, socket and SSH suites; no failed or ignored tests among executed tests. The PostgreSQL session-loss case confirmed the lost session handle stayed retired while the shared pool recovered. `quick` and the test harness also passed after ignored-test inventory regeneration. | `20261001T042714823272Z-layers/report.json` |
| Working tree based on `31d4ed081b9daa263bfb7065e259db73c66012b4` | `drivers` passed in 998.4 seconds; 228 tests across the six drivers, MCP, socket and SSH suites; no failed or ignored tests among executed tests. | `20261001T051127401608Z-layers/report.json` |
| October 1 sandbox run | `sandbox` passed in 65.12 seconds, including the Redis cancellation target. | `20261001T005701182279Z-layers/report.json` |

The corresponding report paths, when retained locally, are under `target/quality/`. Use the current [disconnect and cancellation contracts](../disconnection-contracts.md) for test ownership and current behavior, then run the documented layer against the source being reviewed.
