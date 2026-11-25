# 0051: A setup guide shows on an empty library

- **Status**: Accepted; amends 0008
- **Date**: 2026-11-24

## Context

On first run the macOS app showed a sheet with no action, the iOS app a welcome page, the Linux app nothing and the Windows app a page of cards. Importing from another app, finding its data and opening the sample database all existed, but only behind menus. An import's result held counts only, so no app could open what it had just written. Each app decided on its own when its first screen showed. The maintainer fixed the shape on 2026-11-24: one guide in all four apps, shown while the library is empty, that ends with a connection open.

## Decision

Each app shows a setup guide when its library is read and holds no connection, under one gate, one step order, one source list rule and one handoff, and an import reports the ids of the connections it wrote. The flow and its state live in each app; the core gives the source list and the ids.

### The gate

| # | Opened by | Library | Connections | Seen | Other input | Shows | Seen written |
|---|---|---|---|---|---|---|---|
| G1 | launch | read | 0 | no | - | yes | when the guide ends |
| G2 | launch | read | 0 | yes | - | no | - |
| G3 | launch | read | 1 or more (the sample counts) | no | - | no | iOS: yes, at once. Others: no |
| G4 | launch | loading or unreadable | any | no | - | no | no |
| G5 | launch | read | 0, groups present | no | - | yes (groups ignored) | when the guide ends |
| G6 | menu: macOS Help > Setup Guide, iOS More > Setup Guide, Linux menu item or empty-page Set Up…, Windows Help > Setup Guide | any | any | any | - | yes | when the guide ends |
| G7 | launch, macOS | read | 0 | no | `AppActivationPolicyController.shared.origin != .user` | no | no |
| G8 | launch, macOS and Windows | read | 0 | no | macOS: a pending `WelcomeRouter` request, import or share, or a launch intent. Windows: a file the launch opened, waiting for a connection | no | no |
| G9 | launch, macOS | read | 0 | no | UI-test sandbox, `TABLEPRO_UI_TEST_SHOW_SETUP_GUIDE` unset | no | no |
| G10 | launch, macOS | read | 0 | no | UI-test sandbox, variable set | yes | when the guide ends |
| G11 | launch, Linux | read | 0 | no | not the first picker window of this launch | no | no |

The guide ends:

- macOS: Finish, Skip, or closing its window.
- Linux and Windows: Finish, Skip, or leaving the page by any route in the app. Closing the window quits the app, so nothing ends and nothing is written.
- iOS: the first-run sheet closes with the origin page among its pages, by any route.

The seen flag is stored on the device and never synced. Each app tests its rows of the table.

### Steps

- `origin`, `import`, `firstConnection`, `options`. iOS has `origin` only, before its iCloud and usage pages.
- The guide opens on `import` when a launch probe finds an app with data, else on `origin`. The probe reads no count and no path the system guards; `origin` shows until it answers, and an answer after its time limit is ignored. The source list the probe opens reads no guarded path either: such a source is counted when the user selects it, so a system prompt follows the user's action.
- Back works from the second step shown. Skip ends the guide from any step.
- `import` takes the ticked sources one at a time, in list order: read, review, apply. Each read checks the library the previous apply left.
- `firstConnection` records a new connection or the sample; nothing runs until the guide ends.
- On Finish and on Skip, the first match wins: a recorded new connection opens the new-connection flow, a recorded sample opens the sample; else the ids every import of the guide wrote decide: exactly one opens it, more show the library with them selected, none stays.
- An import from a menu ends by the same id rule on its own outcome.
- An import from a connections file or a link, wherever it came from, selects what it wrote and never opens it, one connection included: the file may come from someone else, and opening it would connect to a host they chose without the user's consent. An import from another app on the device or from the user's cloud account keeps the id rule.
- Passwords start off for a source whose passwords sit in the macOS Keychain and on elsewhere when offered. Saved queries start on when offered and the source counted some.

### The source list

- `tablepro_foreign_import::sources_blocking(dirs, host, depth)` lists `ForeignApp::ALL` in order, filtered by `runs_on`. Each `ForeignSource` has a `SourceAvailability` (`Available`, `NotFound`, or `Unreadable` with the error's code and text), its `Inventory`, a `PasswordOffer` and whether saved queries are offered. `ScanDepth::Presence` reads no count.
- A source starts ticked when it is available, is not imported from a picked file and has a connection.
- `preselect` picks, for a dialog that takes one app, the available source with the most connections, the earlier on a tie, so the earliest available one when every count is zero, and none when nothing is available.
- `ForeignImporter::inventory_blocking` returns the error a read would give when data is there and cannot be read or parsed. Missing data is an empty inventory.
- A host that says an app is not installed no longer hides its data: availability falls back to the data for every app.
- The `dbeaver` importer reads and counts every project of the workspace it picks, not the first.
- The macOS app keeps its Swift scanner with the same rule. `core/crates/foreign-import/tests/fixtures/source_list.json` runs through both.

### The ids

- `ForeignImportOutcome.connection_ids` on the FFI, and `connectionIds` on the Swift `ImportOutcome`, list the saved connections an import wrote, added or replaced, in the review's order. Keep Existing writes none. The Linux app reads them from `AppliedImport`. The Swift `ImportOutcome.handoff(from:)` takes the import's `ImportOrigin`, `fileOrLink` or `ownMachineOrAccount`.
- A TablePro connections file reports its own: `tablepro_storage::ImportReport.connection_ids`, and `ImportSummary.connection_ids` on the FFI, list each connection it added or updated once, in file order.
- `Core::foreign_sources(dirs, depth)` gives each source's availability, password offer, whether it starts ticked and whether it is preselected.

## Rationale

- **The gate reads the library, not the launch count.** A user with no connection needs the guide whether or not an older build showed its sheet, and one with connections does not. A library that has not loaded or failed to load says nothing about the user.
- **The seen flag stays on the device.** Each device has its own empty library at first.
- **One rule set, tested in each app.** The guide is UI state, so it lives in each app; a gate table and a shared fixture keep the four apps alike without a module the macOS app cannot link yet (0010).
- **A count never hides unreadable data.** A list ranked by count drops an app whose file it could not read, and the user never sees why.
- **Ids in the outcome.** Without them no app can open what it imported.

## Consequences

- The Windows app's Get started cards go: this replaces the first-run part of [Windows 0004](../../../windows/docs/decisions/0004-app-shell.md).
- [0008](0008-importers-from-other-apps.md) gains availability from data on every platform, an inventory that can fail and every project of the workspace for the `dbeaver` importer.
- The FFI changes: `ForeignSourceInfo.available` becomes `availability`, and `ForeignImportOutcome` and `ImportSummary` carry a list, so they are no longer `Copy`. The C# bindings are generated again.
- A Linux Flatpak build has to see the folders other Flatpak apps keep under `~/.var/app`.
- The probe's time limit is set by each app.

## Alternatives considered

- **A Rust onboarding module with a Swift copy.** The steps are UI state, and the macOS app does not link the core yet.
- **Show on first launch only.** Users who saw the old sheet and still have no connection would never see the guide.
- **Sync the seen flag.** A second device with an empty library would skip the guide.
