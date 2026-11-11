# Toolkit workarounds

The places the app steps around a GTK, libadwaita, GtkSourceView, IBus or gtk-rs defect. Each entry says what the defect is, where the code is, the versions it was seen in, the test that holds the workaround, and when it can go. Workarounds for a database client library are in [decisions/0005-supply-chain-policy.md](decisions/0005-supply-chain-policy.md) and the [driver pages](drivers/); the platform floor is in [decisions/0015-gnome-50-platform-floor.md](decisions/0015-gnome-50-platform-floor.md).

## A tab dropped outside every window

- **What libadwaita does.** A tab dropped outside every tab bar emits `AdwTabView::create-window`, whose handler "is expected to create a new window, position it as needed and return its `AdwTabView`" (`src/adw-tab-view.c`). The signal stops at the first handler that returns a view; a handler that returns NULL leaves it to the next one. When none returns a view, `adw_tab_view_create_window` logs a critical and the tab bar puts the tab back where it was (`detach_into_new_window` in `src/adw-tab-box.c` and `src/adw-tab-grid.c`). There is no way to decline the new window and no tab groups yet (`is_view_in_the_same_group` is a TODO). This is the documented contract, not a defect.
- **Seen in.** libadwaita 1.9.0 and main on 2026-11-05.
- **Workaround.** A tab belongs to its session's window ([state-management.md](state-management.md#tabs)), so the handler returns the tab's own view, which libadwaita attaches the tab to at position 0, and the shell moves it back to where the drag took it from (`crates/app/src/ui/workspace/workspace_shell.rs`, `SessionWindowInput::ReturnTab`).
- **Test.** `a_tab_dropped_outside_every_window_stays_where_it_was` in `crates/app/src/ui/session_window/tests/sessions.rs`.
- **Remove when** the floor's libadwaita offers a way to decline a detach, or tab groups: use it, and drop the position restore for this case.

## A sidebar the user can widen

- **What libadwaita does.** `AdwOverlaySplitView` sizes its sidebar as a fraction of its own width between `min-sidebar-width` and `max-sidebar-width`, and has no divider to drag. `GtkPaned` has one, but has no collapsed overlay, no breakpoints and no header bar integration. This is the documented design, not a defect.
- **Seen in.** libadwaita 1.9 (the floor) and 1.10.
- **Workaround.** A focusable handle with the separator role lies over the sidebar's trailing edge (`data/resources/ui/workspace-shell.ui`, `crates/app/src/ui/workspace/sidebar_width.rs`). A drag or the arrow keys set `max-sidebar-width` through the `sidebar-width` setting, which every window follows; `sidebar-width-fraction` of 0.5 keeps half the window for the content, and the handle hides while the sidebar is collapsed. The handle covers the edge of the tree's scrollbar.
- **Test.** `the_sidebar_takes_the_width_kept_in_settings_and_has_a_handle_to_set_it` in `crates/app/src/ui/workspace/tests/shell.rs`, `the_sidebar_width_stays_between_its_floor_and_its_cap` in `crates/platform/tests/settings.rs`.
- **Remove when** the floor's libadwaita offers a resizable split view: use it.

## IBus keeps every text view

- **Defect.** From GTK 4.24 a `GtkTextView` or `GtkText` makes itself its input method's client widget at construction and clears it only in its own dispose (GTK commit 3df992599b). ibus-gtk4 holds the client with a strong reference (`ibus_im_context_set_client_widget`), so the view is never disposed, nor anything it holds. [ibus/ibus#2968](https://github.com/ibus/ibus/issues/2968), open.
- **Seen in.** GTK 4.24.1 with ibus-gtk4 1.5.34 (Ubuntu 26.10) and 1.5.35-beta1 (the GNOME 51 runtime). Not on GTK 4.22, the floor, which sets the client on realize and clears it on unrealize. Measured on 2026-11-05 with the issue's C reproducer extended to GtkSourceView: on GTK 4.24.1 with IBus every text view, shown or not, stays alive, and each one is freed when its `im-module` is set to `gtk-im-context-none` first; with `gtk-im-context-simple` every one is freed.
- **Workaround.** `crate::ui::text_view_teardown::release` sets `gtk-im-context-none` on the views that hold the user's text when they close: the SQL editor, the source dialog (definitions and row JSON), the structure tab's SQL, the change review, the row detail value and the assistant's composer. The text in an entry (`GtkText`) leaks the same way; entries have no workaround here.
- **Test.** `text_view_teardown` tests, `a_closed_dialog_lets_go_of_its_text_and_input_method` in `crates/app/src/ui/source_dialog.rs`.
- **Remove when** an ibus-gtk4 release holds the client widget weakly and the distributions and runtimes TablePro ships for carry it.

## GtkSourceView keeps a view that drew line numbers

- **Defect.** The gutter's lines object holds its view strongly, so a view that showed line numbers is never disposed. Fixed by [GNOME/gtksourceview!438](https://gitlab.gnome.org/GNOME/gtksourceview/-/merge_requests/438) (9cb5802f "gutterlines: use a weak reference to the view", with ea1eff56 and b17426c2).
- **Seen in.** GtkSourceView 5.18.0 (Ubuntu 26.04, the floor), with or without IBus. Fixed in 5.21.0 and 5.22.0.
- **Workaround.** The same `release` gives the view an empty buffer, so the text and the language state are freed even while the view is kept.
- **Test.** As above: the buffer is empty after each close path.
- **Remove when** the floor reaches GtkSourceView 5.22, together with the IBus entry or after it.

## AdwAlertDialog.choose

- **Defect.** Two, both in libadwaita (`src/adw-alert-dialog.c`, `src/adw-dialog-host.c`). Upstream report pending, filed by the maintainer.
  - A window destroyed with an alert open takes the alert down with neither `response` nor `closed`: `adw_dialog_host_dispose` unparents its dialogs after clearing their callbacks. `choose` then never finishes, and `choose_future` never resolves.
  - A cancelled `choose` finishes with NULL, though `adw_alert_dialog_choose_finish` promises the close response: the task keeps GTask's check-cancellable, so `g_task_propagate_int` returns -1 and `g_quark_to_string` gives NULL. libadwaita-rs follows the non-nullable annotation and reads it with `from_glib_none` inside an `extern "C"` callback, where the panic aborts the process. `choose_future` cancels when its future is dropped.
- **Seen in.** libadwaita 1.9.0, and 1.10.0, whose dialog code matches main 295aa0e8.
- **Workaround.** `crate::workspace::respond` (`crates/app/src/workspace/dialog_response.rs`) answers from `response`, from `closed` with the close response once a click's `response` has had its turn ([state-management.md](state-management.md#alert-dialogs)), and from the window's `unrealize` with the close response. `gtk_window_destroy` unrealizes the window at once, while its `destroy` signal waits for the last reference, which the caller awaiting the answer holds.
- **Test.** `a_clicked_response_answers_and_closes_the_alert`, `an_alert_forced_shut_answers_with_its_close_response` and `an_alert_whose_window_is_destroyed_answers_with_its_close_response` in `dialog_response.rs`.
- **Remove when** the floor's libadwaita finishes `choose` with the close response on cancel and when the window goes: use `choose_future` with a cancellable.

## ColumnViewCell.set_focusable in gtk-rs

- **Defect.** gtk4-rs generates `ColumnViewCell::set_focusable` only under `cfg(not(feature = "v4_12"))` (`src/auto/column_view_cell.rs`). With v4_12 on, `cell.set_focusable` resolves to `ListItemExt::set_focusable`, which sets GtkListItem's own `focusable`, and GtkColumnViewCell reads its own property of that name. [gtk-rs/gtk4-rs#2393](https://github.com/gtk-rs/gtk4-rs/issues/2393), with the generator fix in [gtk-rs/gir#1759](https://github.com/gtk-rs/gir/pull/1759), both open.
- **Seen in.** gtk4-rs 0.11.4 and main on 2026-11-05.
- **Workaround.** `cell.set_property("focusable", true)` in `crates/app/src/ui/data_grid/columns.rs`, and `false` for the row number cells in `row_number_column.rs`.
- **Test.** The grid's keyboard tests in `crates/app/src/ui/data_grid/tests/gutter.rs` read `is_focusable` on the cells.
- **Remove when** a gtk4-rs release generates `ColumnViewCell::set_focusable` under v4_12: call it.
