# Optimized PostgreSQL fixture profile, October 23, 2026

Related work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315), [#1032](https://github.com/cozyGarage/BookiE/issues/1032). [Results and exact binary hash](results.json).

## Method

The optimized `ci` executable was taken from Forgejo run 916, GTK shard 1, built from `5b00b4ca6`. Harness checkout: `662ed2f76`. The probe runs an isolated Xvfb/Cairo display, D-Bus session, temporary configuration and keyring, and an owned SSH tunnel to the synthetic read-only PostgreSQL fixture. It stops its application and tunnel afterward. No desktop unlock or fixture mutation was required.

The probe originally labels the harness checkout as the application commit. The committed results correct that provenance: `harness_commit` identifies the imported harness; `application_commit` identifies the exact CI artifact build. The local raw output and console log remain under `target/quality/postgres-optimized-probe-20261023.*`.

RSS and peak are process observations, not live-allocation measurements. CPU seconds are process user/system ticks. Scenarios share one application process in the recorded order, so later RSS includes allocator retention and previous grid work. A single sample is not a leak diagnosis or a matched before/after benchmark. No code improvement is claimed from comparison with development-build observations.

## Results

| Scenario | Elapsed seconds | CPU seconds | RSS MiB |
| --- | ---: | ---: | ---: |
| Count | 0.724 | 0.410 | 180.08 |
| Exact numeric | 0.671 | 0.390 | 180.59 |
| Extension values | 0.688 | 0.390 | 182.45 |
| 100 rows with 257 source columns plus marker | 4.834 | 4.020 | 585.23 |
| 100 wide rows | 4.627 | 3.390 | 594.92 |
| Wide query exceeding page budget | 7.586 | 3.480 | 660.71 |
| Recovery query after refusal | 0.671 | 0.370 | 603.32 |

Baseline RSS was 172.49 MiB. All seven checks completed; the over-budget case explicitly reported an incomplete result. Exact numeric and extension values matched the synthetic fixture. Recovery succeeded after the refusal.

## Next work

The many-column case adds roughly 413 MiB of RSS even in the optimized build. Attribute live allocations and retained widget owners separately before changing grid construction. Use independent fresh-process scenarios for allocation baselines and a repeated run/close sequence for owner lifetime. Keep exact copy/export values and keyboard/accessibility behavior intact. A byte-safe PostgreSQL cursor continuation repair requires driver ownership review; lowering a fixed page row count alone is not acceptance.

## Allocation capture

A second fresh-process run preloaded the installed heaptrack library into the owned application only. It ran count followed by the many-column query, then quit normally. The binary hash was unchanged. Profiler overhead raised the many-column elapsed time to 25.597 seconds, so this run is not a timing comparison.

Heaptrack interpretation reported 32,238,432 allocation calls, 3,731,850 temporary allocations and 439.10 MB peak tracked heap (tool-reported decimal units). Its peak RSS including profiler overhead was 717.09 MB. Dominant allocator groups include `g_malloc0` (202.55 MB at peak), `g_malloc` (101.91 MB) and `g_realloc` (80.64 MB). Group totals are allocator buckets, not independent root causes.

Large backtraces pass through GTK object creation, the read-only cell setup path and streamed grid construction. One object-creation substack attributed 13.00 MB to 51,602 allocation calls through read-only cell setup; this does not itself count widget instances. The result contains 25,800 cells. This evidence directs the next experiment toward widget construction and lifetime rather than database row payload alone.

Heaptrack reports 401.53 MB unfreed at process exit. That is not proof of unreachable memory: the run quit while the result remained open, and framework shutdown can retain reachable objects. Explicit result/tab closure and repeat-run ownership checks remain necessary.

Raw and interpreted captures, instrumentation copies and the textual summary remain in local `target/quality/postgres-heaptrack-many-columns/`. The raw capture is approximately 1.2 GB and is not committed. No real data or credentials were profiled.

## Explicit tab closure

A separate fresh-process heaptrack run executed count and the same many-column query, explicitly closed the editor tab, waited until Run disappeared, settled for two seconds, and quit normally. RSS changed from 654.53 MiB to 650.68 MiB after closing; baseline with profiler was 245.48 MiB.

The interpreted capture reported 407.22 MB peak tracked heap and 41.91 MB unfreed at exit, compared with 439.10 MB peak and 401.53 MB unfreed in the previous run that quit with the result open. Remaining allocation counts fell from approximately 5.29 million to 152,098. These are separate runs with measurement variability, not an exact allocation subtraction. They support release of most grid allocations on tab closure despite retained RSS. They do not exclude smaller leaks, framework caches or allocator retention.

Local evidence and the instrumented probe copy are in `target/quality/postgres-heaptrack-close/`. Three repeated open/close cycles without heaptrack completed; [raw measurements](repeat-close.json). After-close RSS was 581.30, 583.79 and 586.28 MiB. This does not show another roughly 400 MiB retained per cycle, but the approximately 2.5 MiB increase per cycle needs a longer run before claiming a plateau. No steady-state or leak-free conclusion is established.

## Ten-cycle follow-up

A fresh unprofiled process completed ten many-column open/close cycles, using the same binary and synthetic fixture. [Measurements](repeat-close-10.json). Baseline RSS was 182.80 MiB. After-close RSS was 582.12, 584.71, 585.07, 585.43, 587.94, 587.99, 588.82, 589.94, 592.84 and 591.54 MiB. The first-to-last increase was 9.42 MiB, with a drop on the final cycle. This does not establish a plateau or exclude smaller retained owners.

Query CPU time ranged from 4.03 to 11.11 seconds; elapsed time ranged from 4.795 to 12.724 seconds. Every query and close completed. These ten observations show substantial construction cost and modest additional RSS growth rather than another full grid retained per cycle. Attribution of the remaining growth and variable CPU cost remains open.

## Inclusive allocation attribution at process peak

Heaptrack exported peak-cost stacks totaling 439,099,144 bytes, matching its reported peak heap. Summing stacks containing the recorded Rust symbols gives the following inclusive subsets:

| Stack contains | Bytes at process peak |
| --- | ---: |
| Streamed grid widget construction | 303,465,109 |
| Read-only cell setup | 173,995,604 |
| Label builder | 132,932,993 |
| Cell context-menu gesture setup | 41,071,780 |
| Application shortcut parsing | 3,097,696 |

These subsets overlap and must not be added. They identify allocation call paths, not unreachable owners or exclusive ownership. The cell-menu path installs a gesture and shortcut controller per cell; any consolidation must preserve pointer targeting, keyboard menus, editing, selection and accessibility. Shortcut parsing alone is a small fraction of the peak, so caching it alone would not resolve the many-column cost.

The exported stacks and aggregation inputs remain in local `target/quality/postgres-heaptrack-many-columns/peak-stacks.txt`. This large diagnostic file is not committed.
