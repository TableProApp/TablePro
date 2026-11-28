# 0029: TablePro Sync in Settings

- **Status**: Accepted
- **Date**: 2026-11-28

## Context

The core's sync engine runs TablePro Sync and iCloud over the core's stores ([core 0054](../../../core/docs/decisions/0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md)), with end-to-end keys per account and device ([core 0056](../../../core/docs/decisions/0056-end-to-end-keys-per-account-and-device.md)). The FFI gives it to an app as `SyncService`, which binds itself to the sign-in it opens under and to the provider it opens with. Windows has no iCloud, so its choices are Off and TablePro Sync. On Windows the core keeps the device's keys and the state file's anchor in Credential Manager itself, so the app passes no device store. The macOS app's Sync pane is the reference for behaviour.

## Decision

- **Interop.** `TableProCore.OpenSyncAsync(SyncConfiguration, TableProAccount?)` gives a `TableProSync`: its status, the server's scopes, the key state, the categories, the history window, the provider choice, the upload's plan and the prompt for another account. `ReadChangesAsync` wakes once for a burst of the core's signals and says whether the status or the keys changed. A refused call's `CoreError.Sync` carries the step-up challenge, the retry delay, the server's code for a refused change or the lock's cause.
- **One host.** `SyncHost` in `TablePro.App.Model` holds the app's one service. It opens at launch on a PC on TablePro Sync, once the account has read what this PC holds, and on first use otherwise. It follows the sign-in session (`AccountStatus.SessionId`): a sign-in, a sign-out or another account closes it, and one that was open or wanted opens again. A provider change opens it again with the new provider, as the core asks; turning Off while an open runs drops that open, and a switch changed during an open reaches the service once it lands.
- **Settings.** `AppSettings.Sync` holds the provider, the switches and the sign-in whose state file the core used last, which goes back to the core at the next open so another account waits for Move my data or Start empty. The provider changes only once the core side of a choice returned.
- **The first upload.** Choosing TablePro Sync asks the plan gate for `service_sync` (0023), then a ContentDialog reads the core's plan: the items that go up, the passwords sealed for it and what stays here. Upload is bound to the sign-in the dialog opened under, waits until this PC holds the account's keys, and is refused while the server keeps no personal data. An upload a restart cut short goes on as the service opens, and the app keeps TablePro Sync once the core says everything arrived.
- **Off.** Turning off is kept at once; the core stops personal sync and the team scopes and key objects go on.
- **Another account.** The host reads whether another account's data waits for Move my data or Start empty on each status change, whatever the provider, since the team scopes wait for it too; the section asks, and the upload waits for the answer.
- **The section.** Settings has a Sync section under Account: a ComboBox with Off and TablePro Sync, an InfoBar for another account or for uploads paused past the license's grace, an InfoBar for the plan gate, one per server switch, a status card with the last pass and Sync now, and the switches. `SyncPane` in `TablePro.App.Model` decides what shows, as the macOS app's `SyncPaneLayout` does for TablePro Sync.
- **Status.** Starting, up to date, syncing, waiting to retry, downloading only, waiting for approval, recovery key needed, locked with its cause, and unavailable with its reason. A key store that has not answered yet is a wait.
- **Switches.** Connections, passwords, groups and tags, saved queries, table favorites and database favorites. This app shows no SSH or credential profiles and no table folders, so they go with the connections and the table favorites they serve. Windows registers no settings category in the core yet, so settings do not sync.
- **Passes.** The core's scheduler polls. The app adds a pass when it comes to the front and when the network comes back.
- **Words.** Every `sync.*`, `keys.*` and `account.*` code the core can return on Windows is worded as `Error_<code>`, which `LocalizationTests` reads from the core's sources. A failure nobody asked about goes to the log by its code alone, since its detail can name what the user holds.

## Rationale

- **The core decides.** The engine already holds the rules for providers, moves, approvals and keys. The app opens it, asks it and words its answers.
- **A host in the model.** The open, reopen and upload rules are the ones most likely to break, so they run against a fake engine in `TablePro.App.Model.Tests`.
- **InfoBars and a ContentDialog.** The Windows guidance keeps dialogs for what the user must read before going on: the upload is one, a server's switch is not.

## Consequences

- Until the keys pages land, the upload dialog says what the account's keys need and offers Check again.
- History syncs only through TablePro Sync, with the history this PC keeps as its window.
- Changes waiting for approval (core #4668) show as "N changes need approval" with no action, apart from this PC's own approval in the key state. The review of those changes is a follow-up.
- `OpenSync` passes no `HostSyncedSecrets` yet, so the core sends each connection's secrets as envelopes (core #4665). A Windows `HostSyncedSecrets` for profile secrets is a follow-up.
- The UI tests run signed out: the section shows Off, and choosing TablePro Sync shows the plan gate.
