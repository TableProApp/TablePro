# 0031: Team Library saved queries and team keys

- **Status**: Accepted
- **Date**: 2026-11-28

## Context

Team Library shares saved queries, folders and connections with a team through the TablePro Sync service, and team keys share the team's passwords end-to-end ([core 0054](../../../core/docs/decisions/0054-one-sync-engine-in-the-core-for-tablepro-sync-and-icloud.md), [core 0056](../../../core/docs/decisions/0056-end-to-end-keys-per-account-and-device.md), [core 0064](../../../core/docs/decisions/0064-a-team-restart-waits-for-a-word-comparison-and-the-sync-lanes-readings-are-settled.md)). The core runs both on the service engine [0029](0029-tablepro-sync.md) opens, whatever the personal provider. The macOS app's Team Library and Team Keys page are the reference. Since core #4661 a team connection crosses the FFI as the core's connection record, and every Team Library call names the owner it is for.

## Decision

- **Interop.** `TableProSync` gains the team calls: the teams with their items, scope status, publish, remove, unsent edits, discard, delete after sign-out, conflicts with Keep mine or Keep theirs, and the team key calls. Each Team Library call takes a `TeamLibraryOwner` from `GetTeamLibraryOwner`, and another account's engine refuses it with `sync.team_library.other_owner`. A team connection maps to a `SavedConnection` from the core's record; no bundle JSON is read in C#. `SavedQueries.GetAllAsync` reads every connection's queries and folders, as a publish sends them.
- **Models.** `TeamLibraryModel` reads the teams, the edits not uploaded and the conflicts again after each sync or key change and clears them when the sign-in changes. A publish is bound to the sign-in and the owner the team was read under. A conflict's choice carries its digest, so one a pull replaced shows again with the newer version. `TeamKeysModel` ports the macOS app's status rules and reads again after each action. Both run over `ITeamCalls` and are tested against a fake.
- **Plan.** `team_library` is listed in Settings and gates the section, the publish and the Team keys card through `Workbench.Gate`.
- **Saved queries pane.** A Team Library section under the tree lists each team's queries, read only. Double-click or Enter opens one in a new query tab. Publish to team confirms the count and sends every saved query and folder on this computer. A bar shows the publish's outcome, the conflicts with Resolve, and the edits not uploaded with Discard.
- **Conflicts.** One ContentDialog per conflict shows each field on both sides and who changed the team's copy last, with Keep mine, Keep theirs and Decide later.
- **Team keys page.** Settings > Sync > Team keys opens a page in the window, as the end-to-end encryption page does: Show my words for every member, then a card per team with its key's status and action. Owners and admins also see the members with Confirm or Compare, and the stopped devices with Confirm again. Confirming a member, comparing a key change, accepting a held restart and starting the key over each compare words in a ContentDialog. Windows shows words only, no QR code.
- **Sign out.** `TeamSignOutFlow` leases the account's service first, and the owner read, the questions, the key erase and the delete after the sign-out all run on it, so a service a resumed upload reopens meanwhile never takes the erase. Edits not uploaded are listed with Upload and sign out, Discard and sign out or Cancel. When the service did not start, an account that has or had Team Library is asked about the edits it cannot list, and Upload starts the service again. The keys are erased next. Once signed out, the account's Team Library data is deleted for that owner, and only once the person was asked or no edit waits.

## Rationale

- **Saved queries first.** Showing and publishing team connections, with their passwords under the team key, is the next step over the core's records. Until then the section counts a team's connections and publishes none, so a team query opens in the connection the pane belongs to.
- **Every member reaches the page.** Owners and admins confirm members, but every member shows their words and compares a held restart, so the card shows for every team member.
- **Words, not codes.** Windows has no camera path to read a code from another screen, so words are the one comparison.

## Consequences

- Team connections and their passwords come next, over `PublishTeamConnections` and the items' records; the credentials a removed member could read are not listed yet.
- The change that first connects a team row (`TeamItem.Connection`) asks before that row signs in with this computer's own credentials, and lands its parts together:
  - The core's helper lists the row's local uses with the host each signs in to: the SSH agent, a key file or the default keys when the copy names none, a database file or a socket.
  - `LocalUseApprovals` keeps the approvals in `local-use-approvals.json` in the data folder, never synced, as connection id to destination to the sorted uses approved there, like the macOS app's `ConnectionApprovalStore` (`localCredentials`). A new use or another host asks again; deleting the row or its leaving the team revokes them; there is no trust on first use.
  - `LocalUseConsent` asks once per destination in a ContentDialog, "Sign in with credentials from this computer?", listing each use with its host, Connect or Cancel with Cancel the default.
  - Only a connect the person starts asks. A restore, a reconnect, MCP or the command line refuses an unapproved row with "Connect again to review the sign-in", as the macOS app's `needsPerson` does.
  - Tests cover the store (approve, a new use or host, revoke, a damaged file) and the consent (no uses, Connect, Cancel, a restore that never asks).
- Deleting another account's Team Library data after an involuntary sign-out (`DeleteOtherTeamLibraryData`) is not called yet.
- The UI tests run signed out, so the section and the page are reached only signed in; their rules are covered by the models' tests.
