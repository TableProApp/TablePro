# 0010: Data masking

- **Status**: Accepted
- **Date**: 2026-11-13

## Context

On 2026-11-13 the maintainer decided that the Windows app masks a connection's values as the macOS app does: rules per connection, masked grids with Reveal, and every export and share masked. The core holds the engine, the rules, the detectors and every masked path out ([core 0026](../../../core/docs/decisions/0026-data-masking.md)). Reveal asks the device's owner first: Windows Hello where it is set up, a confirmation where it is not.

## Decision

Each part works as the macOS app's does, in Windows sentence case and with three dots for an ellipsis (0009). The rules of the form, the tabs and the sheet are in `src/TablePro.App.Model`, tested with fakes; the views lay out.

- **Rules.** The connection form's Options hold a Data masking card: one row per rule with Column or Type, the pattern (placeholder `*.email` or `uuid`), the style (Full, Last 4 characters, Email, Stable hash, NULL) and Remove rule, then Add rule. `ConnectionDraft.MaskingRules` drops a blank pattern and trims the rest. A saved change reaches the open sessions before the save returns, so the workspace calls `ResultSet.Remask` on every set it holds, and the grid reads its cells and headers again in place (`DataGridView.CellsChanged`). A rule change does not reconnect.
- **Grid.** `ResultColumn.Masked` marks a column. The header shows the Hide glyph, the tooltip "Masked by a masking rule" and "Masked" in its UIA item status. A masked cell of a saved row refuses an edit and says why; a new row takes what is typed. A masked key locks the page (`EditLock.MaskedKey`). Copy reads the set's text, which the core already masked.
- **Reveal.** A masked column's header menu offers Reveal masked values..., and so does the cell menu when the focused cell's column is masked, since the keyboard reaches no header. `MaskReveal` checks `UserConsentVerifier.CheckAvailabilityAsync` and asks through `UserConsentVerifierInterop.RequestVerificationForWindowAsync` with the tab's window, as a desktop app must; when Hello is not available, a `ContentDialog` asks instead. The tab keeps the reveal until it closes. A table tab asks about pending edits, then reads its page again with `revealMasked`; it never moves to another table, so its reveal never carries over. A query tab runs its statement again only when `DatabaseSession.ReadsOnly` says it only reads; otherwise the next run shows the values.
- **Share sheet.** Below the preview, a Columns list: Keep, Mask with a style, or Remove per column, from `ResultSet.GetShareMaskingAsync`. A rule's column starts masked with the rule's style and offers only a style that hides as much; a detected column starts masked with the suggested style. The preview is `ResultSet.GetSharePreviewAsync`, so a Stable Hash shows as the core computes it. Under the list: "{n} columns masked, {m} removed." and, after a detection, a note to check the columns. Personal data in the SQL shows an InfoBar with a Hide SQL button. Share stays off until the columns are read, so a detected column never leaves unmasked.

## Consequences

- Reveal never unmasks an export or a share: the core masks them by the connection's rules whatever the tab shows.
- The header and Reveal flows run on Windows only; their logic is covered by `tests/TablePro.App.Model.Tests` and the core's masking by `tests/TablePro.Interop.Tests/MaskingTests.cs`.

## Alternatives considered

- **Mask in the app.** The Stable Hash key is the core's, per process, so the app could not preview or match it.
- **Windows Hello only.** A machine without Hello set up could then never reveal.
