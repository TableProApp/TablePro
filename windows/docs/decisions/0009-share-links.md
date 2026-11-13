# 0009: Share links

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

On 2026-11-13 the maintainer decided that every app shares a query or a result as a public link on tablepro-cloud, from a signed-in account with a verified email: Free with 5 live links, 1,000 rows and an expiry of 1, 7 or 30 days, Pro with 1,000 links, 10,000 rows, no expiry, a password and viewer downloads off. A link's deep link `tablepro://share?token=<token>` opens its SQL in the app. The core holds the calls, the snapshot, the secret scan and the deep link rule ([core 0025](../../../core/docs/decisions/0025-share-links.md)), and the account they go through ([0008](0008-tablepro-account.md)).

## Decision

The sheet and the menus work as the macOS and Linux apps' do, in Windows sentence case and with three dots for an ellipsis, as the rest of the app words its commands. The plan's rules are in `SharePlan` and `SharedLinkOpen` (`src/TablePro.App.Model`), tested with no core; `ShareSheet` and `SharedLinkDialogs` lay out.

### Entry points

- The query results grid gets its first context menu: Copy, then Share result.... A table tab's grid menu adds Share..., which shares the table's whole view and is off while edits are pending, since the snapshot holds the server's values.
- A table share reads the view again from its first row, whichever page shows, stopped if the sheet closes first, with the filter and sort the rows shown were read with and the plan's rows as its limit (`TableTab.ReadForShareAsync`), counts what the filter picks, and sends the page's `ViewSql`: the query the view stands for, with its filter values written in and no row window ([core 0025](../../../core/docs/decisions/0025-share-links.md)). So "first N of M" holds, Hide SQL is offered and the link opens in TablePro. Where the engine cannot write that query, the sheet says so and shares the rows without SQL.
- The SQL editor's own menu gets Share query..., with the selection, else the whole text. `SqlEditor.ContextMenuOpening` lets the host add its items each time the menu opens, since the editor builds a new menu for each window it moves to.
- The File menu has Share result..., Share query... and Manage shared links..., which opens `https://account.tablepro.app/shared-links`. The Windows app has no saved queries or favorite queries yet, so none of them offer Share....

### The sheet

- A `ContentDialog`, titled Share result or Share query, whose one section follows the account: signed out, Sign in..., which starts the account's sign-in and waits in the sheet; an account that could not start says why; signed in, the plan's limits are read (`GET /v2/share-limits`) with a spinner, and an offline or failed read offers Retry.
- An unverified email offers Open account; sharing turned off says so; at the cap, the live personal links, or the chosen team's, are listed oldest first, each with Revoke and a suspended one marked Suspended, with "Pro allows up to 1,000." on Free, and a freed slot shows the form again from limits read anew.
- Share as, shown when the account holds a seat in a team: Personal, then each team from the limits; a team that turned public links off is listed but not offered ("Public links are off for this team."). A team link sends its team, and the footer, the cap and the cap's list use the team's own count, limit and links.
- The form: Title, prefilled from the tab or the table; Note; Expires, every expiry listed with the ones the plan does not allow disabled, and Never on Free tagged Pro; Hide SQL for a result that has its SQL; Password and Allow viewers to download, disabled with a Pro tag on Free. A Pro tag is a `HyperlinkButton` to the plans page, with no dialog.
- A result shows its first 5 rows of the visible columns in the app's own grid, over the result set's cells, and "Shares the first 1,000 of 48,210 rows." when the plan cuts it. The core builds the snapshot from the same set and the visible column count, cut to the plan's rows, with a table view's count as its total, so no row crosses the FFI to come back.
- The server takes a result's first 100 columns (`MaxColumns` in the limits): the preview shows those and says "Shares the first 100 columns.", and the link's page says so again once the core reports it cut them.
- The core's secret scan warns inline about the SQL, while it would be shown, and about the result's column names; it never blocks a share.
- The footer reads "Free · 3 of 5 links · first 1,000 rows" or "Pro · 12 links".
- Share creates the link once: the button is off while it runs. Success copies the URL to the clipboard and shows it with Copy and Open in browser, and the dialog's close button reads Done. A refusal the limits explain (`share_limit_reached`, `email_unverified`, `sharing_disabled`, `signed_out`) reads them again; every other code has the sheet's sentence (`ShareErrors`), and anything else "The link couldn't be created. Try again."
- `SharePlan.Request` never sends an option the plan does not allow, so Free is never refused with `pro_required` for what the sheet offered.

### Deep links

- The package declares the `windows.protocol` extension for `tablepro`. The packaged app is activated with the link; the execution alias and an unpackaged build get it as an argument. A launch while the app runs on the same data folder hands its activation to the running app (`SingleInstance`), which reads the link from it.
- Links open one at a time, in the order they came, and one already waiting is not added twice (`PendingSharedLinks`). Their password prompt and messages wait until the window has loaded and no other dialog is open (`WindowDialogs.ShowWhenFreeAsync`), so a link that comes during another dialog or at a cold start is not dropped.
- `ShareLinks.TokenFromLink` takes only the core's format. The public share is read with no sign-in; `share_password_required` asks for the password, `share_password_wrong` asks again and says so, and `not_found` says the link is no longer available.
- The SQL opens in a new query tab of the connection in front, or the first connected one, and never runs; no connection detail is carried. With no connection open, a dialog shows the SQL with Copy SQL. A share that hides its SQL, or a result shared with none, says there is nothing to open.

## Rationale

- The core already builds the snapshot losslessly, scans for secrets and validates the token for Linux, so Windows lays out and words.
- Stock controls: ContentDialog, InfoBar, ComboBox, PasswordBox, CheckBox, HyperlinkButton, MenuFlyout, and the app's own data grid for the preview.

## Consequences

- A table share reads up to the plan's rows once more when the sheet opens, and counts the view, so a large table waits on both before the form shows.
- No editing of a link after it is made in the app: the portal has it.
- The UI tests show the sheet and the Settings section signed out; a signed-in sheet needs a test stack.
