# Linux follow-up review, October 22, 2026

Status: review complete and archived. This is a source and GitHub-state review, not a new runtime acceptance run.

## Reviewed baseline

BookiE Linux `d38a0185608b7a6f4e42c2ac70456047cc676dab`. Reviewed the changes since `a070efdd235e5586185b43806f9ddbdb06e8c619`, the merged train #1394, open UX pull requests, and issue acceptance and comments. No upstream or competitor repository was rescanned in this pass.

## Findings

Two evidence pages still called the merged #1394 work unpublished local candidates. Their delivery status is corrected in the [row-budget record](../evidence/query-row-budget-2026-10-22/README.md) and [borrowed-key record](../evidence/row-key-borrowing-2026-10-22/README.md). Historical measurements and limits remain unchanged. The owning issues #1382 and #1387 are closed. Their closure records acceptance; no independent Forgejo verification is claimed here.

No new product defect was confirmed in the inspected delta. Raw-row preflight retains the decoded-size check and does not replace value decoding. Borrowed key comparison preserves column-order, missing-key and changed-key checks. This is source evidence only. The existing records explicitly exclude wire/native allocation bounds and whole-application performance claims.

The Ubuntu click calibration keeps an explicit environment override and has host-selection tests. Its fixed offset is a harness calibration, not a general desktop coordinate model. Do not apply the Ubuntu offset to native desktop evidence without checking the actual input backend and coordinate space.

## Next work without duplication

| Priority | Owner and next step | Boundary |
| --- | --- | --- |
| 1 | Finish the existing #1346 → #1363 → #1374 → #1390 UI stack | These remain open PRs at review time. Preserve the existing native evidence and rerun affected checks when their own code changes. Do not describe them as merged Linux capability. |
| 2 | [#1126](https://github.com/cozyGarage/BookiE/issues/1126): installed visual and Orca acceptance | Source already has borders/strike-through and accessible pending-state descriptions for text and Boolean cells. Recycle coverage exists. Start with the missing acceptance, not another styling implementation. |
| 3 | [#1326](https://github.com/cozyGarage/BookiE/issues/1326): Wayland/AppImage surface screenshots | Existing issue evidence found opaque dialogs under Xvfb. Native Wayland, packaged behavior and the failed-network case remain distinct checks. Do not add blanket opaque backgrounds without reproducing the reported overlap. |
| 4 | [#1388](https://github.com/cozyGarage/BookiE/issues/1388): isolate completion sizing | Reproduce the reported zero-width popup with fatal criticals; compare a minimal GtkSourceView provider before changing application proposal handling. The issue already reports nonempty proposals and an unsuccessful empty-result workaround. |
| 5 | [#1033](https://github.com/cozyGarage/BookiE/issues/1033), then [#1034](https://github.com/cozyGarage/BookiE/issues/1034): server messages | The bounded backend contract remains open. The GTK panel must not invent NOTICE/PRINT delivery or reset cumulative budgets when hidden. |

[#1359](https://github.com/cozyGarage/BookiE/issues/1359) already has source/test and native investigation showing shared-connection transaction control is refused and owned sessions expose transaction state. A new confirmation prompt is not justified by that report. Issue closure should use its recorded acceptance rather than add redundant product behavior.

The [Zed review](zed-editor-panel-review-2026-10-22.md) and [GPUI/dbdelve review](gpui-client-review-2026-10-22.md) remain completed research archives. Their open implementation and qualification issues own the remaining work.
