# 0010: Masking a shared result

- **Status**: Accepted
- **Date**: 2026-11-14

## Context

On 2026-11-14 the maintainer decided that masking in this work is only for sharing: a share link hides sensitive columns before it leaves the machine, and nothing else in the Windows app masks (share-v2 PLAN-MASKING 8.0). The core computes the styles, detects what looks sensitive, previews and sums up the rows a share sends, and builds the masked snapshot ([core 0028](../../../core/docs/decisions/0028-data-masking.md)).

## Decision

The share sheet's result section works as the macOS app's does, in Windows sentence case (0009). Its rules are in `src/TablePro.App.Model` (`ShareColumns`, `ShareRounds`, `SharePlan`), tested with no core; `ShareSheet` lays out.

- **Columns.** Below the preview, one row per column with Keep, Mask with a style (Full, Last 4 characters, Email, Stable hash, NULL) or Remove, from `ResultSet.GetShareMaskingAsync`. A column the detectors flag starts masked with the suggested style and says what it looks like; the user may keep it. Every row lays its controls on the same fixed columns.
- **Preview and summary.** Each choice starts a round: `ResultSet.GetShareSummaryAsync` and then `GetSharePreviewAsync` are read off the UI thread, and one from an older round is dropped. The preview is the core's own, so a Stable Hash shows as sent. As the macOS preview, its columns stop at 200 px with an ellipsis, a cell's tooltip shows the whole value, and a masked column's header carries the eye with a slash, named "Masked: {style}". The row note, the 100-column note and why a result too large cannot go come from the summary. Share, the dialog's accent button, stays off until this round's summary and preview have landed, while a value is too large, and when every column is removed. It sends only with the form's plan (`ShareRounds.Plan`): any other section clears it, so an owner picked at its cap never creates a link with the plan of the one picked before.
- **Notices.** "{n} columns masked, {m} removed." with a singular form, a note to check the columns after a detection, and an InfoBar with a Hide SQL button when the SQL holds what looks like personal data.

## Consequences

- The grid, copies and exports show stored values; only a share's snapshot is masked, and the server never receives the originals.
- The sheet runs on Windows only; its logic is covered by `tests/TablePro.App.Model.Tests` and the core's calls by `tests/TablePro.Interop.Tests/MaskingTests.cs`.

## Alternatives considered

- **Mask in the app.** The Stable Hash key is the core's, per process, so the app could not preview it.
