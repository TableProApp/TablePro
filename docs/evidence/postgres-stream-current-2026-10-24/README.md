# Current Linux PostgreSQL large-result measurement

This measurement repeats the [2-million-row workload in issue 1272](https://github.com/cozyGarage/BookiE/issues/1272) on the current GitHub `linux` source, `16d9e9f55b66c90d7746ea7fc541614cb5910e0a`. It uses an optimized local build, PostgreSQL 16 in a disposable Docker container, and the exact ten-column `SELECT * FROM big` query. The application ran under private D-Bus, Xvfb, AT-SPI and Cairo. Toolkit versions were GTK 4.24.1, libadwaita 1.10.0 and GtkSourceView 5.22.0. Build and fixture identities are in [build.json](build.json).

## Completed query cycles

Eight consecutive cycles completed two million rows each. The [profile](original-table-stream.json) checked the visible retained range and navigated the four retained pages in both directions before closing the editor.

| Measurement | Result |
| --- | --- |
| Query time, min / median / max | 4.725 / 4.801 / 4.965 s |
| Application CPU sampled through terminal transition, min / median / max | 3.830 / 3.840 / 3.910 s |
| Peak RSS, min / median / max | 350.78 / 370.43 / 372.91 MiB |
| RSS after close, min / median / max | 352.35 / 370.12 / 372.60 MiB |
| Rows received per cycle | 2,000,000 |
| Rows retained per cycle | 1,980,001–2,000,000 |

No slow cycle appeared in this rerun. RSS after close rose about 20.2 MiB between the first and eighth cycles, mostly after cycle three, then varied by about 2.6 MiB across the remaining cycles. The original multi-gigabyte, row-proportional growth did not recur. RSS alone cannot distinguish live allocations from allocator and toolkit caches, and eight cycles do not establish long-session leak freedom.

## Cancellation

The [cancellation probe](probe-original-cancel.py) ran the same `SELECT * FROM big` query five times and checked PostgreSQL activity plus a fresh query after each interruption. Four trials reported confirmed cancellation; one returned an explicit unknown outcome. Every trial left zero active or idle-in-transaction client sessions, and each follow-up query succeeded. Cancellation UI latency was 0.313–0.375 seconds. The [raw results](original-table-cancel.json) preserve every outcome.

The unknown result is not counted as confirmed cancellation. It matches the conservative operation-outcome contract: the application does not claim a cancellation result unless the driver confirms it. This observation does not establish that every cancellation will be reported as confirmed.

## Limits and remaining acceptance

- These are local release-build measurements under Xvfb/Cairo, not native Wayland or the installed Arch package.
- The initial run contains one unexplained slow cycle. Five subsequent cycles were consistently near five seconds, but the outlier remains recorded.
- Elevated post-close RSS is not a leak diagnosis. A current-source heap profile was attempted, but the installed Heaptrack parser rejected the generated trace; no current-source allocation attribution is claimed.
- This does not establish a long-session RSS plateau or leak freedom for other result shapes.

The results show that the original workload no longer reproduced unbounded memory growth on this current source and local harness. Keep issue 1272 open for native package/Wayland acceptance, the slow-cycle investigation and current-source heap attribution.
