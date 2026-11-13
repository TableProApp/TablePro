# 0046: Share links from the editor, its results and favorites, and the tablepro scheme

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

On 2026-11-13 the maintainer decided that every app shares a query or a result as a public link on the TablePro account, the same way on macOS, Linux and Windows: Free with 5 live links, 1,000 rows and an expiry of 1, 7 or 30 days, Pro without those limits. The calls, the snapshot of a result's rows, the secret scan and the deep link's parser are the core's ([core ADR 0026](../../../core/docs/decisions/0026-share-links.md)). A link's viewer page opens the app with `tablepro://share?token=<token>`. The Linux app had no share feature and no handler for that scheme, and [ADR 0042](0042-account-page-lists-this-platforms-features.md) kept every paid feature off its account page.

## Decision

The SQL editor offers Share Query… and Share Result…, an editor result grid and a table tab's grid offer Share Result… after Export…, a favorite offers Share…, and the main menu offers Manage Shared Links…, which opens the account portal's list. Each one opens one share sheet, an `AdwDialog`. The desktop entry claims `x-scheme-handler/tablepro`, GIO's VFS keeps the link's text as it does a connection link's ([ADR 0045](0045-command-line-and-connection-urls.md)), and `open_files` hands a share link to its own route before any file or connection link.

## How it works

- **The sheet** (`crates/app/src/ui/share_dialog/`) reads `share_limits` when it opens and shows one page: signed out with Sign In…, the wait for the browser, an account that could not start, a failed read with Try Again, an unverified email with Open Account, sharing turned off, the live links at the limit with Revoke, the form, or the created link. `sheet_view.rs` derives each page and its wording as plain data, as `account_view.rs` does for Preferences > Account.
- **Share As.** An account with a seat in a team picks Personal or one of its teams; a team that turned public links off is listed but cannot be picked, and says so. A team link counts against the team's limit, so the footer and the list at the limit follow the team chosen, read with `list_shares` for that team.
- **The form.** Title starts from the tab, the favorite or the result's statement; Note; Expires as an `AdwToggleGroup` of the plan's expiries, where Free sees Never off with a Pro tag; Hide SQL for a result; Password and Allow viewers to download, which Free sees off with a Pro tag. The tag opens the pricing page in the browser and asks nothing.
- **What a result shares** is what an export of the shown rows writes: the grid's rows under the columns on screen in the user's order, pending edits included. The first 5 show in a plain `GtkColumnView` with the grid's display text, which amends [ADR 0027](0027-one-data-grid.md): a sample with no selection, menu or editing is not a grid. A note says when the plan's rows cut the result, and another when it has more columns than the server keeps (`max_columns`, 100 on every plan); the preview shows only those, the core cuts the snapshot to them, and the page after Create says so again when `columns_truncated` comes back. The rows are cut to the plan's `max_rows` and built into the snapshot on the runtime before upload.
- **A table tab** shares its view: once the limits are in, the sheet reads from the first row up to the plan's rows, with the tab's filter and sort, on a connection of the read's own as an export does, and keeps the columns on screen in their order. The SQL is `build_view_sql` for every column, so the filter and the sort find theirs; a view the engine cannot write as SQL is shared without it, and the sheet says why. The whole is the tab's exact count, else its estimate.
- **Titles.** A query's title starts from its tab's title, without the connection a shared tab bar adds. A result's starts from its line in the results list, such as Result 1 (3), never from its statement, since Hide SQL keeps the statement from viewers.
- **Warnings.** The core's secret scan of the SQL and the column names shows inline and never blocks. Hide SQL takes the SQL's warnings away, since no viewer reads it then.
- **Create** runs once at a time; a second press while it runs does nothing, and the sheet cannot close until the answer is in, so a link is never made unseen. The link goes to the clipboard and shows with Copy, which takes the focus, and Open in Browser; when the clipboard refuses it, the page says the link was created rather than copied. A refusal shows its sentence from `error_text/account.rs` over the form. `share_limit_reached`, `email_unverified` and `sharing_disabled` read the limits again, which shows the page for what changed, and the form comes back as the user typed it once a revoke frees a slot.
- **Suspended links**, which a team or staff turned off, say Suspended in the list at the limit; they still count until revoked.
- **The deep link** waits for the account to start, since a link can launch the app, then reads the share with `fetch_shared`, which needs no sign-in. A word about a link that did not open goes to a window already open, and a picker opens only when there is none. A password-protected link asks in an `AdwAlertDialog` and asks again after a wrong one. The SQL takes the way a SQL file handed to the app takes: a new editor tab in the relational session in front, never run, or a wait behind the picker's banner until a connection joins the window. The link carries no connection. A result whose owner hid its SQL, or that was shared with blank SQL, says there is nothing to open.
- **Preferences > Account** lists `shared_links` as Pro Options for Shared Links, included or not by the entitlement, since every account shares and the plan lifts the Free limits. This amends [ADR 0042](0042-account-page-lists-this-platforms-features.md), under which no flag was on and the Features group never showed.

## Consequences

- An editor result is shared with the rows the run kept. When the run's row limit cut it, the count the viewer shows is the rows kept, since the true total is unknown.
- Team links are made from the sheet; editing and revoking links other than at the limit is the portal's.
- The public read goes through the core's `Account`, which needs this computer's machine ID. Where it cannot be read, a share link says why accounts are unavailable instead of opening, though the read itself needs no account. A core read of a share that takes no `Account` would lift this.
- The Features group of Preferences > Account now shows on Linux, with one row.
- A new scheme in the desktop entry is also registered with the VFS, and the desktop entry's test checks both lists.

## Alternatives considered

- **The DataGrid for the preview.** Its menu would offer hiding a column and exporting the sample, and neither would change what the link carries.
- **Sign In… opening Preferences > Account.** Two steps for one action; the sheet runs `Account::sign_in` itself and follows the account's status.
- **An `AdwComboRow` for Expires.** A combo row cannot show Never as present but unavailable, which the share plan asks of Free.
- **Opening the shared SQL in the active window's front session whatever its engine.** A key-value or document session runs no SQL; the script route already asks for a connection in that case.
