# Repeated wide-result resource comparison, October 22

The [manifest](manifest.json) pins the optimized baseline and corrected candidate binaries. The [comparison](comparison.json) records six query/replacement/tab-close cycles per binary, with 50,000 rows and 8,193-byte text payloads, followed by 15 seconds idle. Baseline ran first. Both scenarios exited 0 without a safety abort. All twelve queries received 50,000 rows and ten pages. The baseline retained rows 30001–50000; the byte-bounded candidate retained 45001–50000.

| Configuration | Peak sampled RSS | Peak sampled PSS | App CPU | Elapsed |
| --- | --- | --- | --- | --- |
| Baseline | 482.29 MiB | 444.50 MiB | 55.67 s | 112.009 s |
| Corrected candidate | 296.74 MiB | 258.95 MiB | 18.15 s | 80.290 s |

Sampled peak RSS was 38.47% lower and app CPU was 67.40% lower in this comparison. Neither app’s CPU counter advanced during the final idle interval. Perf exited -2; CPU totals use process accounting. The owned PostgreSQL fixture was stopped afterward.

No local Cargo build or test was active. An unrelated container was sampled at 11.38% CPU during the baseline and was absent late in the candidate. It was left untouched. This shared-host activity limits controlled crossover claims. The repeated result supports the earlier direction of improvement but does not prove statistical significance, native behavior, long-duration leak freedom or a process-memory ceiling. Pin/export/cancel lifetimes, keyless browsing, JSONB preview allocations and oversized editor lines remain open.

The candidate includes the inspector correction: grid cell previews are bounded, while the inspector keeps its 8 KiB stored sample. The fresh train changes only documentation and its pinned manifest relative to the locally validated candidate; runtime source, tests, scripts, Cargo inputs and workflows were compared unchanged. See [aggregate acceptance](../resource-acceptance-2026-10-22/README.md). This profile is evidence for the recorded binaries, not acceptance of a later head or a newly published release.
