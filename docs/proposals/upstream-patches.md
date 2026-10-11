# Proposal: send the vendored patches upstream

Status: first four issues filed on 2026-10-10 with the maintainer's approval:
[sqlx SCRAM](https://github.com/transact-rs/sqlx/issues/4451),
[sqlx quoted `NULL`](https://github.com/transact-rs/sqlx/issues/4452),
[sqlx `ENUM`/`SET`](https://github.com/transact-rs/sqlx/issues/4453) and
[mongodb SCRAM](https://github.com/mongodb/mongo-rust-driver/issues/1819).
The hostname option, multirange codes and the resolution depth are not filed yet.

BookiE carries four patched crates in `vendor/` (about 125,000 lines, more
than the application's own code). The patches themselves are about 540 lines of
diff, kept in `vendor/patches/` and checked by
`scripts/vendor-patches.py check`. Each accepted upstream change removes work
(a refresh per release) and, when the last patch of a crate lands, removes the
vendored copy.

| Patch | Crate | Size | Likely to be accepted | Why it matters to BookiE |
|---|---|---|---|---|
| SCRAM iteration cap and nonce checks | `sqlx-postgres`, `mongodb` | about 80 lines | Yes: a security hardening with a cited advisory (RUSTSEC-2026-0179); postgres-protocol already caps it | Stops a hostile server from making the client spend unbounded time deriving a key |
| TLS hostname different from the dialled address | `mongodb`, `redis` | about 90 lines | Plausible: a `verify_host` option is useful to anyone connecting through a tunnel or proxy | Certificate checks survive an SSH tunnel's loopback address |
| Quoted `NULL` in text arrays | `sqlx-postgres` | about 30 lines | Yes: a correctness bug; `{"NULL"}` is a string, not SQL NULL | Value preservation (ADR 0007) |
| Multirange type codes | `sqlx-postgres` | about 10 lines | Plausible | Unsupported values reach the explicit refusal path |
| Type resolution depth 64 to 1,024 | `sqlx-postgres` | 2 lines | Needs discussion: a larger bound | Deep domain and enum chains |
| `ENUM` and `SET` stay text under a binary collation | `sqlx-mysql` | about 5 lines | Yes: a correctness bug | Value preservation |

Order of work: SCRAM cap, quoted `NULL` and the `SET` fix first (security and
correctness, small, each with a test), then the hostname option. Keep a vendored
crate until all of its patches are released, then delete its directory and its
`[patch.crates-io]` line.
