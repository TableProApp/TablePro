# Catalog membership scaling

Related: [#580](https://github.com/cozyGarage/BookiE/issues/580) and the metadata-request fix [#1556](https://github.com/cozyGarage/BookiE/pull/1556).

The [probe](probe.rs) builds synthetic catalogs containing 1,000, 10,000 and 50,000 qualified table names. It calls the exact app-services catalog membership check five times for an unknown name. Each lookup asserts that no columns should be requested. Catalog construction is outside the timed interval.

The optimized library was built from source d4de668ad with cargo build --release --locked -p tablepro-app-services. The standalone release probe was compiled with rustc -O, linking that library and its matching dependency directory. The debug probe linked the matching development library. [Raw samples and the optimized library hash](measurement.json) identify this local result.

## Observations

| Tables | Development build | Optimized build |
| --- | --- | --- |
| 1,000 | 1.55–1.58 ms | 0.259–0.265 ms |
| 10,000 | 14.8–16.0 ms | 2.53–2.64 ms |
| 50,000 | 74.4–75.7 ms | 12.0–12.6 ms |

The implementation parses the requested name and then parses each catalog name until a match is found. Unknown names require the full scan. The metadata refresh currently runs on the GTK context after its debounce, so multiple uncached references can repeat this work.

A candidate correction is to construct canonical membership keys when the catalog changes and reuse them for lookups. Any such change must preserve quoted case, schema identity, unqualified resolution, connection invalidation and candidate ordering. These measurements do not establish an end-to-end UI defect or justify changing identifier semantics.

## Limits

This is a synthetic CPU measurement without GTK or a database. There is no contention, no real multi-tenant database and no restricted-role catalog fixture. It measures neither catalog loading nor the completion ranking/model path. It does not satisfy the broader performance, query scoping or MCP acceptance in #580.


## Indexed follow-up

The [indexed probe](indexed-probe.rs) runs the same lookup against canonical keys computed by the catalog setter. [Samples and code identity](indexed-measurement.json) record the optimized comparison. At 50,000 tables, the first lookup took 1.8 microseconds and the following samples took about 0.6 microseconds. The original optimized samples took 12.0–12.6 milliseconds. These are membership lookup timings, not a whole-application speedup.

The [construction probe](setup-probe.rs) measures indexing separately in a fresh process for each size:

| Tables | Index construction | Process RSS increase |
| --- | --- | --- |
| 1,000 | 0.465 ms | 292 KiB |
| 10,000 | 4.298 ms | 1,652 KiB |
| 50,000 | 24.494 ms | 7,180 KiB |

Construction excludes allocating the original table-name vector. RSS includes allocator and process effects and is not an exact cache heap measurement. The implementation trades additional keys for eliminating repeated scans. It drops the key collection on metadata clear and connection replacement. Construction still runs during catalog refresh; this change does not move all catalog work off the GTK context.

The table list is now private and updates pass through the setter. A grammar change before the next catalog update uses the existing parsing path to preserve identifier semantics. Tests pin catalog replacement, quoted case, grammar changes and clearing; existing completion activation tests cover exact insertion and lazy proposal behavior. The new lifecycle test pins existing behavior while the probes establish the performance difference. Full preflight passed (2,075 unit tests, 2,088 sandbox tests and the separate Redis check). Strict application Clippy and all 158 isolated GTK tests passed. Native Wayland and remote Forgejo acceptance remain pending. The baseline probe requires its recorded pre-index source; the indexed probe uses the setter API.
