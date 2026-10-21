# Initial SQL editor focus, October 21

Owner: UX, [#1280](https://github.com/cozyGarage/BookiE/issues/1280). Base: `a6a0daa79`. Arch Linux, GTK under private X11/Xvfb, Cairo; no database is required.

## Reproduction and fix

The regression maps a window with a sidebar search entry, gives it focus, then installs and appends the production split editor. The original setup leaves the root focus on the search entry's GtkText child instead of the query view. The assertion fails on the original implementation.

The primary view now requests focus on its first map. A per-view flag prevents later remapping from stealing focus. The same test focuses the sidebar again, hides and shows the existing query view, and verifies that the sidebar keeps focus. Both assertions pass with the fix.

The shared setup is used by SQL editor construction; no application message, driver, SQL, saved state or policy contract changes. No owner reference is captured by the new callback. The change follows ADR 0003's GTK component boundary.

## Validation

`ui::editor::split_view::tests::opening_an_editor_moves_focus_out_of_sidebar_search` failed before the fix and passed after it. The case is registered in the isolated GTK tier. All 83 isolated GTK cases passed. App all-target Clippy passed. Initial full preflight attempts used a stale SQLite executable in the shared target directory. That executable lacked the new DROP-guard diagnostic; rebuilding the unchanged driver restored all four workspace-selected refusal tests. The earlier SQLite source-defect hypothesis is withdrawn. [#1281](https://github.com/cozyGarage/BookiE/issues/1281) records the build-cache investigation. Full final integration results belong to the PR and gate. Review is self-review, not independent. Native Wayland keyboard interaction and Forgejo acceptance remain pending.
