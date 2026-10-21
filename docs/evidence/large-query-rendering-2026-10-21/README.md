# Large-query rendering investigation, October 21

Source base: `9f5dbd47e`. Owner: [#1272](https://github.com/cozyGarage/BookiE/issues/1272). This follows the [grid ownership investigation](../grid-lifetime-2026-10-21/README.md); it does not replace its pinned heap profiles.

## Reproduced cause and change

Initial streamed-result rendering and live page appending constructed a full grid for each retained page, even while hidden behind the pager. A GTK regression fails on the original implementation because a hidden page already contains a ColumnView. The changed path creates only a lightweight page holder until that page is first displayed. The existing grid builder then runs once. Switching away and back preserves grid identity and local state. The builder consumes captured inputs and never captures its owning widget.

Fetching, policy checks, cancellation, result values, page retention and export behavior are unchanged. Pages that have already been displayed can retain their grids until eviction or close. Selecting a page still performs grid construction on the GTK thread. Eviction can select and build a surviving page. This is reduced unnecessary work, not a CPU ceiling or aggregate byte budget.

## External source review

The dbx review is pinned to `d030f4276f7922fbc2b0b844a20875991347ac79`. Its [canvas renderer](https://github.com/t8y2/dbx/blob/d030f4276f7922fbc2b0b844a20875991347ac79/apps/desktop/src/lib/dataGrid/canvasDataGridRenderer.ts) computes visible rows and columns and bounds the fitted-text cache at 10,000 entries. Its [result lifecycle](https://github.com/t8y2/dbx/blob/d030f4276f7922fbc2b0b844a20875991347ac79/apps/desktop/src/composables/useDataGridResultLifecycle.ts) invalidates operations when results change and on disposal. The applicable principles are display work proportional to visible content, bounded caches and explicit lifetime checks. This change reuses GTK list virtualization and the existing grid builder; no renderer, dependency or upstream code is copied.

The [TablePro performance guidance](https://github.com/TableProApp/TablePro/blob/8085bff2dd87d80ab1ca29a550e347e749fa2985/CLAUDE.md) identifies eager layout and repeated full-string traversal as historical hazards. That pinned guidance is research input only, not proof of a BookiE defect. The separate local editor trace confirms whole-buffer copies before the band limit and full-script completion planning on cursor movement; its fix and verification will be recorded separately.

## Verification and limits

The failing-before GTK log and passing-after runs are retained in the owning worktree under `.analysis/large-query/`. The new case covers a realized selected page, an unbuilt hidden page, first selection and grid reuse on remap. Existing grid-release and composed-stream ownership cases remain registered. Fresh preflight and all 95 isolated GTK cases passed, including the terminal-status lazy-loading case and existing ownership checks. App all-target Clippy and documentation/inventory checks passed.

No comparable end-to-end throughput or CPU percentage is claimed. Native Wayland, broad large-file responsiveness and the aggregate page byte budget remain separate acceptance. CPU and memory evidence must distinguish stored rows, built grid/model objects, native caches and active database work.
