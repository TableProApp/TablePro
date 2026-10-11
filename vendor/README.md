Patched crates.io snapshots used through `[patch.crates-io]` in the workspace
`Cargo.toml`. Each directory is the pristine crate plus one patch file in
[`patches/`](patches/); nothing else may differ. `python3 scripts/vendor-patches.py
check` downloads each pristine crate, verifies it against the registry checksum,
applies the patch and fails on any difference, so an undocumented edit cannot
hide in a vendored tree.

Update a crate to a new release with
`python3 scripts/vendor-patches.py refresh <crate> <version>` (it re-applies the
patch and stops if a hunk no longer fits), then `cargo update -p <crate>`. After
changing a vendored file by hand, run `python3 scripts/vendor-patches.py generate
<crate>` and commit the new patch.

| Crate | Version | What the patch changes |
|---|---|---|
| `sqlx-postgres` | 0.9.0 | Reject SCRAM iteration counts above 100,000 and a server nonce that does not extend the client nonce (same cap as postgres-protocol 0.6.12, RUSTSEC-2026-0179). Keep quoted `NULL` text in arrays. Recognise multirange type codes so unsupported values reach BookiE's explicit refusal path. Resolve type metadata up to 1,024 levels so deep domain and enum chains load. Two build fixes for the trimmed feature set (a `Json` import path and a dead-code expectation). |
| `sqlx-mysql` | 0.9.0 | Report `ENUM` and `SET` columns as text even when a collation sets the binary flag, and name `SET` columns. Whitespace only elsewhere. |
| `mongodb` | 3.9.1 | Reject SCRAM iteration counts above 100,000 and check the server nonce by prefix. Let the TLS layer verify a hostname different from the one it dials. |
| `redis` | 1.7.0 | Let a TLS connection verify a hostname different from the one it dials, so a certificate check survives an SSH tunnel's loopback dial address. Benchmarks, examples, tests, the changelog and `release.toml` are not vendored; the licence file is. |

Upstreaming these patches would let the copies be dropped; see
[the dependency review](../docs/proposals/upstream-patches.md).
