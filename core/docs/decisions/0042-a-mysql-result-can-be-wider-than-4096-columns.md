# 0042: A MySQL result can be wider than 4,096 columns

- **Status**: Accepted
- **Date**: 2026-11-21

## Context

sqlx-mysql 0.9.1 refuses result-set metadata that claims more than 4,096 columns, with a protocol error, before it reads one ([sqlx#4458](https://github.com/launchbadge/sqlx/pull/4458)). The claimed count came from the server and sized a `HashMap::with_capacity` and a `Vec::reserve`, so a 10-byte packet claiming 2^40 columns aborted the client. The pull request took 4,096 as the server's hard limit, but that is the limit for a table. A SELECT can return more: MySQL 8.4 and MariaDB 11.4 both return a SELECT of 200,000 constant columns in full. Since the workspace moved to sqlx 0.9.1 (#4371), a SELECT of more than 4,096 columns fails in the Linux and Windows apps, in an editor run (the text protocol) and in a prepared read alike. The macOS app does not link the core's MySQL driver.

## Decision

The workspace takes sqlx-mysql and sqlx-core from `TableProApp/sqlx` (root `Cargo.toml`, `[patch.crates-io]`): the v0.9.1 tag plus one commit that drops the refusal and caps what the claimed count reserves at 4,096 entries, so a wider set grows as its column definitions arrive.

## Rationale

- The danger was the allocation, not the count. With the reservation capped, the column list grows with the definitions the server actually sends, one packet each, as a result's rows already grow with the rows it sends. A hostile server gets nothing it could not get by sending rows.
- No bound fits the server. The prepare reply of the binary protocol counts columns in 16 bits, but a text-protocol SELECT is bounded only by `max_allowed_packet`, up to 1 GiB of query text. A smaller bound refuses results the server returns, and a larger one bounds nothing an allocation needs.
- The fork differs from the tag in that one place, so moving it to a new tag or dropping it stays cheap.

## Consequences

- sqlx-core comes from the fork too, unchanged from 0.9.1: a sqlx-mysql taken from git takes sqlx-core from its own repository, and every sqlx crate must build on one sqlx-core. Cargo.lock changes only the two crates' sources. `allow-git` in `deny.toml` gains the fork, and the no-fork rule of [Linux ADR 0016](../../../linux/docs/decisions/0016-driver-contract-v2.md) no longer holds for sqlx.
- The pin goes once a sqlx release reads a result wider than 4,096 columns. The integration test `wide_result::a_select_of_4097_columns_reads_every_column` in `tablepro-driver-mysql` reads one through both protocols on MySQL and MariaDB, and fails if the pin goes earlier.
- A sqlx bump leaves the patch unused, which Cargo only warns about. The bump moves the fork to the new tag, or drops it when that release has the fix; the test fails on a bump that does neither.

## Alternatives considered

- **A larger bound**, such as 65,535: no number is the server's limit, as above.
- **Drop the refusal and keep reserving the claimed count**: brings back the abort the refusal was added for.
- **Go back to sqlx 0.9.0**: brings back the SQLite of RUSTSEC-2026-0459 that #4371 left, and gives up the rest of sqlx#4458, which turns panics on malformed packets from a hostile server into errors.
- **Wait for a sqlx release**: every such SELECT fails until then.
