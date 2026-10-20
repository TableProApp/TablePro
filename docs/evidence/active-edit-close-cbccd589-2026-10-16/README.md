# Active-edit close GTK evidence

Source revision: `cbccd58981fa6768fe209a197de9aacbb726a0da` on `ux/active-edit-close`.

The release build completed with:

```text
CARGO_TARGET_DIR="$PWD/target" CARGO_BUILD_JOBS=2 cargo build --release --locked -p tablepro-app --bin tablepro-app
```

The resulting binary SHA-256 was `346c4ee1f5c361f89ce9e34848e51dfbe57bdcb50a33e775329a249b1da9c163`.

The isolated GTK safety harness exited successfully with all ten selected scenarios passing under D-Bus and Xvfb:

```text
TABLEPRO_GTK_BINARY="$PWD/target/release/tablepro-app" \
TABLEPRO_GTK_SCENARIO=active_cell_edit_enter_control,active_cell_edit_survives_cancelled_tab_close,active_cell_edit_survives_cancelled_keyboard_close,active_cell_edit_survives_cancelled_close_button,active_cell_edit_save_then_close_persists_the_value,active_cell_edit_discard_then_close_leaves_the_database_unchanged,active_cell_edit_keeps_its_preview_when_another_table_opens,active_cell_edit_survives_cancelled_window_quit,active_cell_edit_survives_cancelled_disconnect,active_cell_edit_saves_when_close_button_targets_an_inactive_tab \
bash scripts/test-gtk-safety.sh
```

The scenarios check the persisted edited value and unchanged sibling or database state after cancellation, save, discard, preview replacement, quit, disconnect and inactive-tab closure. The run used Xvfb, not an installed package on Wayland. `Close Other Tabs`, `Close Tabs to the Right`, IME preedit and value-popover closure remain manual acceptance paths.
