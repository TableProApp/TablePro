# Performance regression contracts

This change adds twelve tests that pin the merged performance behavior. It builds on the existing grid-sharing, lazy-proposal, preview and byte-retention tests. The [testing guide](../../testing.md#performance-regression-contracts) owns the contract matrix and commands.

## Added coverage

- Six stream-cache tests cover sustained eviction, snapshot sharing and final-owner release, the exact byte boundary, rejected payloads, repeated empty pages, and terminal snapshots.
- Two headless completion tests cover constant membership lookup work and prefix/cache eligibility.
- One preview matrix covers 32 combinations of value kind, Unicode content and length boundary.
- Three isolated GTK tests cover large-model disposal, pending metadata callback cancellation, and repeated editable/read-only grid replacement.

The normalization counter is compiled only for tests. It measures work, not elapsed time, so the large-catalog guard is independent of runner speed. GTK registrations are recorded in the [generated inventory](ignored-test-inventory.txt).

## Controlled regressions

The [mutation results](mutation-results.json) record two local trials:

1. Disabling page-count eviction and replacing shared snapshots with deep copies failed the sustained-stream, shared-snapshot and terminal-ownership tests.
2. Bypassing indexed membership and restoring the full scan failed the normalization-work test: four lookups performed 40,008 normalizations against a bound of 16.

Both trials exited with test failures, not build failures. Their source files were restored before normal validation. The mutations are not part of the committed product code.

## Validation and limits

Full preflight passed: 2,077 unit tests, 2,090 sandbox tests and the separate Redis check. All six added application stream tests and the preview matrix passed after source restoration. Strict application Clippy and all 161 isolated GTK tests passed. Remote Forgejo acceptance is pending. These tests do not establish a process-wide memory ceiling or a general latency bound. Native Wayland, long-session RSS, driver buffers and the large SQL-file layout path require separate measurement. No product behavior or CI workflow is changed.
