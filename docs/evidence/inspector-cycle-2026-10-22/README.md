# Browse inspector callback lifetime

Tracker: [#1333](https://github.com/cozyGarage/BookiE/issues/1333).
The regression is `ui::grid::lifetime_tests::a_retired_grid_does_not_retain_its_inspector_through_selection_callback`.

## Reproduction and fix

A headless GTK test builds a `ColumnView` with its `MultiSelection`, wraps the
view in the same `RowInspector` split-view relationship used by the browse tab,
and captures the inspector from the selection signal. Dropping all external
references left the view alive. The test failed before the fix with
`retired grid remains alive`.

The selection callback now captures weak references to the inspector's list and
stack. It upgrades them for each refresh and returns when they have been
released. The same regression test passes and verifies that the view, selection,
inspector and result `Arc` are all released.

## Validation

The regression passed under GTK/Xvfb after failing on the unfixed code. The
first GitHub Fast check found that the strong helper was only used by tests;
it is now compiled only in test builds. Refreshed preflight passed all 2,054
tests (64 skipped), app all-target Clippy passed, and all 106 isolated GTK
widget tests passed. GitHub checks and Forgejo acceptance remain pending.
Repeated window RSS measurements have not been run. The test proves object
release; it does not quantify process RSS impact.
