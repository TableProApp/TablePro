# 0046: Share links from the editor, its results and favorites, and the tablepro scheme

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

On 2026-11-13 the maintainer decided that every app shares a query or a result as a public link on the TablePro account, the same way on macOS, Linux and Windows: Free with 5 live links, 1,000 rows and an expiry of 1, 7 or 30 days, Pro without those limits. The calls, the snapshot of a result's rows, the secret scan and the deep link's parser are the core's ([core ADR 0026](../../../core/docs/decisions/0026-share-links.md)). A link's viewer page opens the app with `tablepro://share?token=<token>`. The Linux app had no share feature and no handler for that scheme, and [ADR 0042](0042-account-page-lists-this-platforms-features.md) kept every paid feature off its account page.

## Decision

The SQL editor offers Share Query… and Share Result…, an editor result grid offers Share Result… after Export…, a favorite offers Share…, and the main menu offers Manage Shared Links…, which opens the account portal's list. Each one opens one share sheet, an `AdwDialog`. The desktop entry claims `x-scheme-handler/tablepro`, GIO's VFS keeps the link's text as it does a connection link's ([ADR 0045](0045-command-line-and-connection-urls.md)), and `open_files` hands a share link to its own route before any file or connection link.

## How it works

- **The sheet** (`crates/app/src/ui/share_dialog/`) reads `share_limits` when it opens and shows one page: signed out with Sign In…, the wait for the browser, an account that could not start, a failed read with Try Again, an unverified email with Open Account, sharing turned off, the live links at the limit with Revoke, the form, or the created link. `sheet_view.rs` derives each page and its wording as plain data, as `account_view.rs` does for Preferences > Account.
- **The form.** Title starts from the tab, the favorite or the result's statement; Note; Expires as an `AdwToggleGroup` of the plan's expiries, where Free sees Never off with a Pro tag; Hide SQL for a result; Password and Allow viewers to download, which Free sees off with a Pro tag. The tag opens the pricing page in the browser and asks nothing.
- **What a result shares** is what an export of the shown rows writes: the grid's rows under the columns on screen in the user's order, pending edits included. The first 5 show in a plain `GtkColumnView` with the grid's display text, and a note says when the plan's rows cut the result. The rows are cut to the plan's `max_rows` and built into the snapshot on the runtime before upload.
- **Warnings.** The core's secret scan of the SQL and the column names shows inline and never blocks. Hide SQL takes the SQL's warnings away, since no viewer reads it then.
- **Create** runs once at a time; a second press while it runs does nothing. The link goes to the clipboard and shows with Copy and Open in Browser. A refusal shows its sentence from `error_text/account.rs` over the form, and `share_limit_reached` reads the limits again, which shows the list at the limit.
- **The deep link** waits for the account to start, since a link can launch the app, then reads the share with `fetch_shared`, which needs no sign-in. A password-protected link asks in an `AdwAlertDialog` and asks again after a wrong one. The SQL takes the way a SQL file handed to the app takes: a new editor tab in the relational session in front, never run, or a wait behind the picker's banner until a connection joins the window. The link carries no connection. A result whose owner hid its SQL says there is nothing to open.
- **Preferences > Account** lists `shared_links` as Pro Options for Shared Links, included or not by the entitlement, since every account shares and the plan lifts the Free limits.

## Consequences

- An editor result is shared with the rows the run kept. When the run's row limit cut it, the count the viewer shows is the rows kept, since the true total is unknown.
- A team link is not offered from the sheet; the portal manages links after they are made.
- The Features group of Preferences > Account now shows on Linux, with one row.
- A new scheme in the desktop entry is also registered with the VFS, and the desktop entry's test checks both lists.

## Alternatives considered

- **The DataGrid for the preview.** Its menu would offer hiding a column and exporting the sample, and neither would change what the link carries.
- **Sign In… opening Preferences > Account.** Two steps for one action; the sheet runs `Account::sign_in` itself and follows the account's status.
- **An `AdwComboRow` for Expires.** A combo row cannot show Never as present but unavailable, which the share plan asks of Free.
- **Opening the shared SQL in the active window's front session whatever its engine.** A key-value or document session runs no SQL; the script route already asks for a connection in that case.
