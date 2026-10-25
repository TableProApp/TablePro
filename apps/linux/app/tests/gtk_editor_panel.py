import time


def scenarios(ui):
    def save_default_query_as_writes_the_visible_sql(_database, base):
        ui.press_x11_key("e", ("Control_L",))
        ui.wait_for_node(name="Run", role=ui.pyatspi.ROLE_PUSH_BUTTON)
        ui.wait_for_node(name="Query 1", role=ui.pyatspi.ROLE_PAGE_TAB)
        ui.press_x11_key("s", ("Control_L", "Shift_L"))
        chooser = ui.wait_for_node(name="Save SQL file", role=ui.FILE_CHOOSER_ROLES)
        ui.show_file_chooser_location(chooser)
        path = base / "home" / "untitled-query.sql"
        ui.set_visible_editable_within("Save SQL file", ui.FILE_CHOOSER_ROLES, str(path))
        ui.invoke(ui.wait_for_node(name="Save", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and not path.exists():
            time.sleep(ui.POLL_SECONDS)
        assert path.exists(), "Save As did not create the SQL file"
        assert path.read_text(encoding="utf-8") == "SELECT 1;", "Save As did not write the visible default query"
        ui.wait_for_node(name="Saved")
        ui.wait_for_node_containing(path.name, role=ui.pyatspi.ROLE_PAGE_TAB)

    save_default_query_as_writes_the_visible_sql.environment = "local"

    def results_panel_preserves_query_results_and_keyboard_focus(database, _base):
        ui.run_sql("INSERT INTO safety_items(id) VALUES (842); SELECT id FROM safety_items WHERE id = 842;")
        ui.invoke(ui.wait_for_node_containing("2 · SELECT", role=ui.pyatspi.ROLE_PAGE_TAB))
        ui.wait_for_node(name="842")
        toggle = ui.wait_for_node(name="Results", role=ui.pyatspi.ROLE_TOGGLE_BUTTON)
        ui.invoke(toggle)
        ui.wait_for_node(name="842", present=False)
        ui.set_editor_text("SELECT 842;")
        ui.press_x11_key("j", ("Control_L",))
        ui.wait_for_node(name="842")
        ui.press_x11_key("j", ("Control_L",))
        ui.wait_for_node(name="842", present=False)
        ui.press_x11_key("j", ("Control_L",))
        ui.wait_for_node(name="842")
        ui.invoke(ui.wait_for_node(name="Maximize results", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Restore editor", role=ui.pyatspi.ROLE_PUSH_BUTTON)
        ui.invoke(ui.wait_for_node(name="Restore editor", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Maximize results", role=ui.pyatspi.ROLE_PUSH_BUTTON)
        ui.invoke(ui.wait_for_node(name="Errors (0)", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="No errors in the latest query run")
        ui.invoke(ui.wait_for_node(name="Show result sets", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="842")
        time.sleep(ui.POLL_SECONDS)
        assert ui.database_ids(database) == [842], "panel actions must never rerun the INSERT"

    results_panel_preserves_query_results_and_keyboard_focus.environment = "local"
    return [save_default_query_as_writes_the_visible_sql, results_panel_preserves_query_results_and_keyboard_focus]
