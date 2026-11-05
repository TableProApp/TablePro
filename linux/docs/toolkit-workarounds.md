# Toolkit workarounds

The places the app steps around a GTK, libadwaita, GtkSourceView, IBus or gtk-rs defect. Each entry says what the defect is, where the code is, the versions it was seen in, the test that holds the workaround, and when it can go. Workarounds for a database client library are in [decisions/0005-supply-chain-policy.md](decisions/0005-supply-chain-policy.md) and the [driver pages](drivers/); the platform floor is in [decisions/0015-gnome-50-platform-floor.md](decisions/0015-gnome-50-platform-floor.md).

## A tab dropped outside every window

- **Defect.** libadwaita documents the return of `AdwTabView::create-window` as nullable, but `adw_tab_view_create_window` logs `g_critical ("AdwTabView::create-window handler must not return NULL")` for NULL (`src/adw-tab-view.c`). So a handler cannot decline a new window without a critical. libadwaita then attaches the page to whatever view the handler returns, at position 0 (`detach_into_new_window` in `src/adw-tab-box.c`). Tab groups, which would keep a tab in its window, are a TODO there (`is_view_in_the_same_group`). No upstream report yet.
- **Seen in.** libadwaita 1.9.0 and main on 2026-11-05.
- **Workaround.** A tab belongs to its session's window ([state-management.md](state-management.md#tabs)), so `create-window` returns the tab's own view and the shell moves the page back to where the drag took it from (`crates/app/src/ui/workspace/workspace_shell.rs`, `SessionWindowInput::ReturnTab`).
- **Test.** `a_tab_dropped_outside_every_window_stays_where_it_was` in `crates/app/src/ui/session_window/tests/sessions.rs`.
- **Remove when** the floor's libadwaita takes NULL from `create-window` as a decline without a critical, or has tab groups: return `None`, or put each window's view in its own group, and drop the position restore for this case.

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

## AdwAlertDialog.choose_future

- **Defect.** `adw_alert_dialog_choose_finish` returns `g_quark_to_string (g_task_propagate_int (...))`. Once the call's cancellable fires, the task's error makes `g_task_propagate_int` return -1 and the result is NULL (`src/adw-alert-dialog.c`), though its documentation promises the close response. libadwaita-rs reads that result with `from_glib_none` into a `GString` inside an `extern "C"` callback (`src/alert_dialog.rs`), where the panic aborts the process. `choose_future` cancels when its future is dropped, such as when the window that awaits it closes. A dialog that goes without emitting `response` leaves `choose` waiting for good. No upstream report yet.
- **Seen in.** libadwaita 1.9.0 (`choose` since 1.5) with libadwaita-rs 0.9.2.
- **Workaround.** `crate::workspace::respond` (`crates/app/src/workspace/dialog_response.rs`) answers from `response`, and from `closed` with the close response once a click's `response` has had its turn ([state-management.md](state-management.md#alert-dialogs)).
- **Test.** `a_clicked_response_answers_and_closes_the_alert` and `an_alert_forced_shut_answers_with_its_close_response` in `dialog_response.rs`.
- **Remove when** libadwaita returns the close response on cancel and on a forced close, and libadwaita-rs maps a NULL result without panicking.

## ColumnViewCell.set_focusable in gtk-rs

- **Defect.** gtk4-rs generates `ColumnViewCell::set_focusable` only under `cfg(not(feature = "v4_12"))` (`src/auto/column_view_cell.rs`). With v4_12 on, `cell.set_focusable` resolves to `ListItemExt::set_focusable`, which sets GtkListItem's own `focusable`, and GtkColumnViewCell reads its own property of that name. No upstream report yet.
- **Seen in.** gtk4-rs 0.11.4 and main on 2026-11-05.
- **Workaround.** `cell.set_property("focusable", true)` in `crates/app/src/ui/data_grid/columns.rs`, and `false` for the row number cells in `row_number_column.rs`.
- **Test.** The grid's keyboard tests in `crates/app/src/ui/data_grid/tests/gutter.rs` read `is_focusable` on the cells.
- **Remove when** a gtk4-rs release generates `ColumnViewCell::set_focusable` under v4_12: call it.
