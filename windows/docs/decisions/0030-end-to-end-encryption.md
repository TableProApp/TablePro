# 0030: End-to-end encryption in Settings

- **Status**: Accepted
- **Date**: 2026-11-28

## Context

TablePro Sync seals passwords, other secrets and query history with the account's end-to-end keys, which each device holds once another device approves it or the person uses the recovery key ([core 0056](../../../core/docs/decisions/0056-end-to-end-keys-per-account-and-device.md)). The core runs every flow through `SyncService`; [0029](0029-tablepro-sync.md) opens it and shows its status. The macOS app's End-to-End Encryption page is the reference for behaviour.

## Decision

- **Interop.** `TableProSync` gains the key calls: set-up, replace and recover with the recovery key, approval on both sides, the devices and their removal, the reset, the notices and sign-out's erase. `CoreError.StepUp` carries RFC 9470's challenge, which `TableProAccount.StepUpAsync` answers in the browser.
- **Flows in the model.** `RecoveryKeyFlow`, `RecoverFlow`, `ApprovalFlow`, `RemovalFlow`, `ResetKeys`, `ResetProposal`, `AccountKeysPage`, `KeysSignOut` and `StepUpRetry` in `TablePro.App.Model`, each over `IKeyFlows`, ported from the macOS app's models with their rules: the recovery key lives in a flow only while its dialog is open and its draft is discarded in the core when it closes; two groups are typed back before anything goes up; an approval polls every 1.5 s and shows the five words once; a closed session is cancelled so the other side stops; a step-up runs once per call.
- **The page.** Settings > Sync > End-to-end encryption opens a page in the window, as the keyboard shortcuts page does: this computer's key state, the recovery key with Replace, the requests waiting for approval, the devices holding the keys with Remove, and the reset. A locked computer says why and offers only the ways back its lock leaves.
- **Dialogs.** Each flow is one ContentDialog whose content follows the flow's step. The recovery key shows its 14 groups numbered and copies to the clipboard kept out of the clipboard history and off other devices. A key typed in goes into a PasswordBox.
- **The upload.** The first upload's dialog closes for the key dialog it needs, set-up or approval, and opens again after it.
- **Sign out.** This computer's keys are erased before the sign-in is revoked. When they could not be, the person picks Try again, Sign out anyway or Cancel.

## Rationale

- **The macOS app's rules, tested here.** The flows carry the rules most likely to go wrong across awaits: a dialog closed mid-call, a sign-in that changed, a draft left in the core. They run against a fake in `TablePro.App.Model.Tests`.
- **A page, not a dialog.** The devices and the reset are lists that change while the page is open, which a dialog over Settings would hide.
- **No print.** Windows has no print path in the app yet; copying to a password manager is the way to keep the key.

## Consequences

- Team keys for owners and admins come with Team Library.
- The UI tests run signed out, so the page is reached only signed in; its flows are covered by the model's tests.
