# Proposal: send the vendored patches upstream

Reviewed 2026-10-14. Four upstream issues are filed and remain open:
[sqlx SCRAM](https://github.com/transact-rs/sqlx/issues/4451),
[sqlx quoted `NULL`](https://github.com/transact-rs/sqlx/issues/4452),
[sqlx `ENUM`/`SET`](https://github.com/transact-rs/sqlx/issues/4453) and
[MongoDB SCRAM](https://github.com/mongodb/mongo-rust-driver/issues/1819).
The TLS hostname option, PostgreSQL multirange codes and type-resolution depth
changes are not filed.

BookiE carries four patched crates in `vendor/`. Their patch files live in
`vendor/patches/` and are checked by `scripts/vendor-patches.py check`. When an
upstream release includes the last patch for a crate, remove that vendored copy
and its `[patch.crates-io]` entry.

| Patch | Crate | Upstream status | Why it matters to BookiE |
|---|---|---|---|
| SCRAM iteration cap and nonce checks | `sqlx-postgres`, `mongodb` | sqlx [#4451](https://github.com/transact-rs/sqlx/issues/4451), MongoDB [#1819](https://github.com/mongodb/mongo-rust-driver/issues/1819), both open; see [RUSTSEC-2026-0179](https://rustsec.org/advisories/RUSTSEC-2026-0179.html) | Limits hostile-server CPU use and rejects invalid server nonces |
| TLS hostname separate from dial address | `mongodb`, `redis` | Not filed | Certificate checks use the database hostname through a tunnel or proxy |
| Quoted `NULL` in text arrays | `sqlx-postgres` | [#4452](https://github.com/transact-rs/sqlx/issues/4452), open | Preserves the string `NULL` instead of decoding it as SQL NULL (ADR 0007) |
| Multirange type codes | `sqlx-postgres` | Not filed | Preserves known PostgreSQL multirange values |
| Type resolution depth 64 to 1,024 | `sqlx-postgres` | Not filed | Supports deeper domain and enum chains |
| `ENUM` and `SET` stay text under a binary collation | `sqlx-mysql` | [#4453](https://github.com/transact-rs/sqlx/issues/4453), open | Preserves native MySQL values (ADR 0007) |

Keep the vendored patches until upstream releases include the changes and the
replacement dependencies pass BookiE's contract tests.
