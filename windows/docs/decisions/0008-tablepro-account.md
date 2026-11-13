# 0008: Signing in to the TablePro account

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

The Windows app had no TablePro account. On 2026-11-13 the maintainer decided that Windows gets account sign-in in the share-links round, since a share link needs a signed-in account with a verified email. The core builds the account from `tablepro-account` for Windows and gives it to the app through the FFI's `AccountService` ([core 0024](../../../core/docs/decisions/0024-the-windows-app-signs-in-through-the-ffi.md)); tablepro-cloud registers the public client `tablepro-windows` with a loopback redirect on any port.

## Decision

The app opens one account at launch and shows it on the Settings page, with the logic in `src/TablePro.App.Model` and the calls in `src/TablePro.Interop`.

### Interop

- `TableProCore.OpenAccountAsync(AccountConfiguration, IAccountBrowser)` returns a `TableProAccount`, which restores the last sign-in and keeps the entitlement fresh until it is disposed. Its calls run on the thread pool as every other call does, and throw `TableProException` with the core's `account.*` code.
- The core's status callback only signals. `AccountWake` holds one slot in a bounded channel, as `RunWake` does for a run, and `ReadStatusChangesAsync` reads `Status` again on the UI thread for every wake, so changes that come while the UI is busy are read as one.
- `IAccountBrowser.OpenAsync` opens the sign-in page. The core calls it on a thread it lets block; the app's `SystemBrowser` hands the URL to the UI thread's dispatcher and opens it with `Launcher.LaunchUriAsync`, which needs the thread its window lives on.
- The refresh token stays in the core's own store: `TablePro/account-refresh-token` in Credential Manager under `CreateWithSystemSecrets`, or `SecretItem.AccountRefreshToken` of a host's `ISecretStore`. The account's device and entitlement are in `account.json` in the data folder.
- The core reads `MachineGuid` itself. `AccountConfiguration.MachineGuid` is for a host off Windows, as the interop tests.

### App

- `Workbench.StartAccount` opens the account once, in `App.OnLaunched`, and keeps its status for every window. `AccountChanged` is raised on the UI thread after the status or a sign-in's progress changes. One sign-in runs at a time; the Settings page and the share sheet both start it, and Cancel ends the wait for the browser.
- Settings opens with an Account section: a card that names the account (its name, else its email), its email and plan, with one action, Sign in..., Cancel while the browser is open, or Sign out. Signed in, Plan has Refresh and, expanded, Manage account and Manage shared links, which open the portal in the browser; Devices lists the account's devices when it opens, this computer first, each with Remove where the server allows it.
- An InfoBar above the card says what needs doing: an error a press met, an entitlement that expired or could not refresh (with Refresh or Try again), the device limit (with Remove a device..., which opens a dialog of the devices holding the license and asks the account again once one is removed), or a sign-in Credential Manager did not keep.
- `AccountPanel` turns the status and the sign-in's progress into the stage, title, plan and notice the page shows. Pro is the entitlement's `shared_links` feature, as the server resolves it.
- Every `account.*` code, and the FFI's own account and share codes, has its sentence in `Strings/en-US/Resources.resw` as `Error_<code>`.
- A Debug build signs in to a local tablepro-cloud when `TABLEPRO_ACCOUNT_URL` and `TABLEPRO_API_URL` are set, with `TABLEPRO_ENTITLEMENT_KEYS` for its signing keys. A Release build always uses tablepro.app.

## Rationale

- The core already runs the account for Linux, and its Windows seams (Credential Manager, `MachineGuid`, the loopback listener) are in the FFI, so the app only lays it out and words it.
- Stock controls: the Toolkit's SettingsExpander and SettingsCard, as the rest of Settings, InfoBar and ContentDialog.

## Consequences

- No offline file import, billing or license key entry yet; the portal has them.
- The UI tests run signed out: a data folder with no `account.json` starts signed out and the core never opens Credential Manager, so nothing reaches tablepro.app.
- The refresh token's target is per Windows user, not per data folder: two data folders signed in at once write the same credential, and the last sign-in's token is the one kept.
