# Fixed grid width regression, October 21

Issue: [#1266](https://github.com/cozyGarage/BookiE/issues/1266), UX. Base: `64ad4ebf0`. Source reference: TablePro [#3702](https://github.com/TableProApp/TablePro/pull/3702), commit `277b8a03c3f896acad0b6adaf20392a9dbdd725b`. The adaptation uses BookiE's existing ColumnWidthStore and grid builder; no upstream implementation file was copied.

## Reproduction

The isolated GTK test builds the production two-column grid, loads a saved 140-pixel first-column width and enlarges the window. On the unfixed code, the first value label grows from 230 to 380 pixels. The fixed-width value alone therefore does not enforce the user's chosen layout: expansion distributes spare width to that column too.

The fix disables expansion when restoring an override and on later fixed-width changes. Columns with only the default minimum retain expansion. The persistence callback uses its signal argument rather than retaining the column itself.

## Validation scope

Regression cases cover a saved browse width, a new browse resize and a result-grid resize without connection persistence. Each asserts allocated cell width after window growth and checks that the unsized neighbor expands. Persistent cases also check the saved width. The tests use temporary stores, an isolated Xvfb display, Cairo rendering and a private D-Bus session on Omarchy; no database is required. They do not establish native Wayland drag-event delivery.

Local preflight passed: 2,022 non-GTK unit tests, 2,023 sandbox tests and one Redis cancellation regression. The script harness and static checks passed. The saved-width regression failed before the fix and passed afterward. All 81 registered isolated GTK widget tests passed, including the three new width cases. App all-target Clippy passed. The serialized Forgejo gate remains pending until recorded in the pull request. No upstream PR has been submitted. The issue has the UX lane label and ledger entry; Project #3 insertion was refused because the GitHub token lacks read:project scope.
