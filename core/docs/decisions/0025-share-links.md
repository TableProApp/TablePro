# 0025: Share links go through the account, with the snapshot and the secret scan in the core

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

On 2026-11-13 the maintainer decided that every app shares a query or a result as a public link on tablepro-cloud, from a signed-in account with a verified email: Free with 5 live links, 1,000 rows and an expiry of 1, 7 or 30 days, Pro with 1,000 links, 10,000 rows, no expiry, a password, viewer downloads off and team links. A link opens in a browser viewer, and its deep link `tablepro://share?token=<token>` opens its SQL in the app. The macOS, Linux and Windows apps show the same sheet, so what they share and how they read the answers must not drift. tablepro-cloud's `docs/design/api.md` is the contract.

## Decision

- **Calls.** `tablepro-account` adds `share_limits`, `create_share`, `list_shares`, `revoke_share`, `extend_share` and `fetch_shared` to `Account`, through the generated `/v2` client. The owner calls take the session, the bearer and the 429 hold every other call takes. A create, rate limited apart on the server, holds only further creates. It holds the session only to take its token, and has five minutes of its own (`Bearer::lasting`) for a body of up to 8 MiB on a slow link; the client's 30 seconds stay for every other call. A sign-in or sign-out during the upload owns the session afterwards, so the answer does not touch it. `fetch_shared` is public: the same HTTP client, no bearer, no session, and the password in `X-Share-Password`. `share_limits` lists the teams the account holds a seat in, each with its own live count and limit, and `list_shares` takes a team for a team's links.
- **Problem codes.** A refusal stays `AccountError::Refused` with the server's code, and `code()` names the ones an app words: `account.email_unverified`, `account.pro_required`, `account.sharing_disabled`, `account.team_sharing_disabled`, `account.seat_required`, `account.not_found`, `account.share_limit_reached`, `account.share_revoked`, `account.share_removed`, `account.validation_failed`, `account.snapshot_too_large`, `account.share_password_required` and `account.share_password_wrong`. A 413, whose body is the framework's, reads as `snapshot_too_large`. No new variant, so a match on the variants keeps compiling.
- **Snapshot.** `tablepro_core::export::build_snapshot` writes each cell by the JSON export's lossless rules: integers and decimals as the digits the server sent, a JSON column as its document, arrays element by element, timestamps in ISO form, an unreadable value as null; bytes as `"(binary, N bytes)"`. Each cell is a raw JSON token, since the workspace's `serde_json::Value` would round big numbers and reorder a document's keys. It takes at most the plan's `max_rows` and keeps the result's true row count; the server derives `truncated` itself. The server takes 100 columns and names of 256 characters, so a result shares its first 100 columns (`MAX_SHARE_COLUMNS`, which `ShareLimits` also carries) and `CreatedShare::columns_truncated` says so; a name or type is cut to 256.
- **Secret scan.** `tablepro_core::secret_scan` finds AWS access keys, private key PEM headers, JWTs, GitHub, Slack, Stripe and Google keys, URLs with credentials and a quoted literal assigned to a password, secret, token or API key, each kind once per line; and columns named for passwords, secrets, tokens, API keys, social security or card numbers. It warns; it never blocks a share.
- **Deep link.** `share_token_from_link` takes only `tablepro://share?token=` with one token of 43 base62 characters, the format the server mints. The app opens the SQL in a new tab, never runs it and carries no connection.
- **FFI.** `AccountService` gives the calls to the Windows app. `create_share` builds the snapshot from a finished `ResultSet` in Rust, from its visible columns, so no row crosses the FFI to come back. The result store keeps an array as the JSON of its elements' text, so each element is read back by the element's kind, and Windows sends the same cells as Linux, which holds the values.
- **A table tab's query.** A table page has no SQL the user wrote, so `TablePageRead::view_sql` gives the query its view stands for: `browse::build_view_sql`, the export's statement with no row window, each filter value written as the dialect's literal (`StatementBuilder::inlining`; a shell literal on MongoDB). The page's own statement would carry bound parameters, the hidden row-address columns and one page's window. `create_share` takes the view's count from `table_row_count` as `total_rows`, since the set holds one page.

## Consequences

- Linux and Windows build the same snapshot and scan the same way. The Mac shares through its own Swift service until its account moves onto the core ([0010](0010-macos-on-the-core.md)).
- `openapi/v2.openapi-3.0.json` carries the share endpoints; `linux/build-aux/update-cloud-api.sh` copies it in as before.
- A pattern added to the secret scan changes the warnings in Linux and Windows together, and the Mac's list follows by hand.

## Alternatives considered

- **New `AccountError` variants for the share problems.** Every exhaustive match in the apps would break for codes they word as strings anyway.
- **A snapshot of `serde_json::Value` with serde_json's `arbitrary_precision` and `preserve_order`.** Both features change `Value` for every crate in the workspace.
- **The app sends its grid's text.** Text loses which cells are numbers, so a viewer could not align them or export them as numbers.
