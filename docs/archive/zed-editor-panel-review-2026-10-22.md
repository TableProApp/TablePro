# Zed editor and panel review, October 22, 2026

Status: research complete and archived. Implementation is proposed, not delivered. Open work belongs to the linked GitHub issues; this record is not a second task board.

## Evidence and scope

Reviewed the BookiE Linux editor layout, outcome rendering and error-location helper, current open PRs, Zed dock source and editor/terminal manifests, and official diagnostics and terminal documentation. No Zed build, benchmark or installed BookiE acceptance was run for this review. Zed source pin: `544780422affd11699fb531c49af5cc6e82a3fd7`.

- [Dock ownership, focus and sizing](https://github.com/zed-industries/zed/blob/544780422affd11699fb531c49af5cc6e82a3fd7/crates/workspace/src/dock.rs)
- [Editor dependencies and license](https://github.com/zed-industries/zed/blob/544780422affd11699fb531c49af5cc6e82a3fd7/crates/editor/Cargo.toml)
- [Terminal view dependencies](https://github.com/zed-industries/zed/blob/544780422affd11699fb531c49af5cc6e82a3fd7/crates/terminal_view/Cargo.toml)
- [Diagnostics interaction](https://zed.dev/docs/diagnostics), [terminal interaction](https://zed.dev/docs/terminal) and [GTK VTE candidate](https://gnome.pages.gitlab.gnome.org/vte/gtk4/)

The GPUI client review, including dbdelve, is [already archived](gpui-client-review-2026-10-22.md). Its research completion is separate from the open PostgreSQL regression proposal #1316.

## Existing work to retain

The editor already uses a vertical GtkPaned for SQL and outcomes. Outcomes retain statement/result identity and display errors with a Copy error action. PostgreSQL error positions are formatted by `ui/editor/error_location.rs`; a clickable structured-location action was not found in the inspected editor path. Existing query history, folding, split editors and lifecycle guards must be reused.

At review time, PR #1346 owns narrow sidebar behavior; #1363 builds on it with visible session controls, run choices, sidebar fields and export scopes. PR #1361 owns selection execution and #1352 owns themes. PRs #1345, #1350 and the #1351 resource train own related editor/result resource work. These are pending PRs, not merged capability claims. New changes must check their current state before choosing a base.

## Adoption and handoff

| Order | Work and owner | Required acceptance |
| --- | --- | --- |
| 1 | Bottom results/error panel, UX, under [#552](https://github.com/cozyGarage/BookiE/issues/552) | Extend the existing editor/result split. Visible toggle and keyboard action, resize and maximize/restore, remembered bounded size, and focus restoration. Hiding retains results; closing releases them. Preserve selected statement/result and existing execution guards. Test empty state, rerun, split editors, narrow/enlarged-text layout and close while busy. Check shortcut conflicts before assigning Ctrl+J. |
| 2 | Clickable error locations, UX, under #552 | Preserve structured positions through outcome presentation, using statement origin and buffer revision. Navigate Unicode and multi-statement positions correctly. An edited buffer or stale run cannot select an unrelated location. Keep copyable safe error text and a useful fallback without a position. Do not parse translated display strings to recover coordinates. |
| 3 | Server Messages, B3/B4 then UX, [#1033](https://github.com/cozyGarage/BookiE/issues/1033) and [#1034](https://github.com/cozyGarage/BookiE/issues/1034) | Backend contract lands first. Bound cumulative bytes/count and queued deliveries; preserve request ownership, cancellation and results. Hiding/reopening the panel cannot reset budgets. PostgreSQL first; SQL Server PRINT and timing remain under #550. |
| 4 | Panel backing, UX, [#1326](https://github.com/cozyGarage/BookiE/issues/1326) | Reproduce current Linux behavior. Verify failed connection, statement error and approval surfaces in light/dark with screenshots. Preserve intentional window transparency while ensuring readable overlapping surfaces. |
| 5 | Pending-edit cues, UX, [#1126](https://github.com/cozyGarage/BookiE/issues/1126) | Visible and accessible modified/inserted/deleted state, independent of hue. Recycled cells and reverted edits clear the old state. Retain installed visual and Orca acceptance. |
| 6 | Long-line memory, UX, [#1299](https://github.com/cozyGarage/BookiE/issues/1299) | Attribute allocations before changing the editor. Preserve exact content/save behavior; compare single-line and multiline files and repeated open/close cycles. No claim that adopting Zed fixes this measured symptom. |

## Architecture and reuse

Adopt explicit panel activation, focus destination, size and close transitions from Zed's design. Put testable state transitions in the existing headless app-services boundary under [ADR 0018](../decisions/0018-headless-app-services-crate.md); keep widgets and focus adapters in GTK under [ADR 0003](../decisions/0003-relm4-architecture.md). Avoid a generic docking framework before these concrete behaviors need one.

The Zed editor and terminal view depend on GPUI and many Zed crates. They are not drop-in GTK widgets. No source was copied and no dependency added. Source incorporation requires file-level license/provenance review against BookiE's license and deny policy.

A local shell terminal is a separate later product decision. GTK VTE is a candidate for evaluation, not an accepted dependency. Shell commands are outside PolicyGuard and must never appear to inherit database read-only guarantees or receive saved secrets automatically. An output/messages panel does not require a PTY or shell.

## Completion boundary

The review and candidate handoff are done. The next implementation should be one focused PR for the existing results/error panel, followed by structured error navigation. Keep independently useful fixes separate. Merge latest Linux into each branch, preserve existing tests, write failing-first regressions and update user documentation with behavior changes. GitHub cheap checks, maintainer Forgejo acceptance and native desktop evidence remain separate gates.
