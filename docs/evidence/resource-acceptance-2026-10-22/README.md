# Resource acceptance train, October 22

The [pinned manifest](../../../ci/forgejo-train.json) combines the toolbar layout fix (#1303), deferred stream-grid construction (#1309), visible NUL preview fix (#1314), retained-byte budget (#1322) and bounded visible previews (#1323), in that order. All five two-parent merges applied without conflicts on Linux `c3b2a054e`. The manifest and first-parent merge order were verified with the aggregate verifier before publishing.

The byte budget and bounded previews are accepted as one candidate. Earlier profiling found lower RAM but higher CPU with the byte budget alone. The combined follow-up reduced both in the recorded wide-result workload; its [measurement limits](../bounded-preview-layout-2026-10-22/README.md) still apply. Full values, exact copy/export paths and policy checks are preserved. No allocator tuning or process-memory ceiling is introduced.

The constituent evidence records the failing regressions and individual checks. Combined preflight, GTK widget tests, GitHub checks, exact-head Forgejo acceptance and the post-merge tree comparison remain pending. The train must pass the aggregate verifier before gating and immediately before merging. No constituent is closed or accepted merely because it appears in this manifest.

Forgejo Linux sync 860 passed all 29 jobs at PostgreSQL fix commit `e7bd0e44cab881b71a25fc805f29ec3d6733e4c8`; its run identity, workflow and success were verified. This sync does not gate the resource train.

Remaining resource work includes longer pin/export/cancel lifetimes, keyless browse preview routing, parsed-JSON preview serialization and oversized editor lines. This train does not close the broader resource issues or establish long-duration leak freedom. Native visual checks remain separate.

## Inspector correction and rebuild

The first local candidate passed preflight and all 105 GTK widget tests, but app unit tests reported 717 passes and one failure: the row inspector’s stored sample was shortened through a shared formatter. It was not published or gated. The unchanged inspector regression now passes on the corrected preview constituent, along with all 716 app unit tests and app all-target Clippy. The original candidate remains on a local evidence branch. This train was rebuilt from the same Linux base with all five exact constituent heads and a corrected manifest. Combined checks must pass again before publication and gating.

The corrected preview constituent `c35f72bf3` subsequently passed refreshed preflight and all 103 isolated GTK widget tests, in addition to its 716 app unit tests and app all-target Clippy. Combined checks on the rebuilt train remain pending.

## Next PostgreSQL allocation comparison

Source tracing confirms that `crates/drivers/postgres/src/query.rs` decodes JSON as JsonText and JSONB as parsed Json. In `apps/linux/app/src/ui/row_object.rs`, parsed Json previews first check the size with a bounded writer, then allocate the entire serialized document before retaining its 8 KiB prefix. Text and JsonText previews slice their existing strings. This is a verified allocation path, not a measured JSONB regression or a reason to change the value contract.

After the optimized build and local checks finish, compare synthetic streamed results with `repeat('x', 8193)`, `json_build_object('payload', repeat('x', 8193))`, and `jsonb_build_object('payload', repeat('x', 8193))`, keeping the row count and lifecycle fixed. Include a small-row-count, larger-document case to expose temporary allocations. Record exact source/binary hashes, successful row counts, retained ranges, peak RSS/PSS, CPU and after-close ownership. Keep the fixture loopback-only and stop it afterward. Do not profile while Cargo or local test jobs are active. A bounded serialization fix must preserve the exact serialized byte count, UTF-8 boundaries, backing value, inspector sample and exact copy/export behavior.

## Corrected aggregate local validation

At runtime source `08cf1aa9c`, the rebuilt aggregate passed all 718 app unit tests, all 105 registered GTK widget tests and full preflight. Later changes through `f71c85a3d` affect documentation only; the runtime source, scripts, CI manifest and Cargo inputs compare unchanged. The optimized release build passed and its saved binary has SHA-256 `6c6976c3e0df28a503bf4f7ac0b99c5e781ac690c39607b44f0329bd563ea079`. This binary is reserved for the next headless comparison, not a newly published release. GitHub checks, exact-head Forgejo acceptance and merged-tree verification remain pending.

## Documentation-base refresh

The verifier rejected PR #1329 after Linux advanced to `3269f51e5` with manual-testing documentation. The train was rebuilt from that base with the same five exact constituent heads, without rewriting the published branch. Runtime source, tests, scripts, Cargo inputs and workflow files must compare unchanged against the locally validated candidate before reusing its results. The fresh manifest, current GitHub checks and exact-head Forgejo gate remain required.
