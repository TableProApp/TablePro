import sqlite3
import time

import gtk_ux


def scenarios(ui):
    def notes(database):
        with sqlite3.connect(database) as connection:
            return connection.execute("SELECT id, note FROM safety_items ORDER BY id").fetchall()

    def wait_for_file(path):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and not path.exists():
            time.sleep(ui.POLL_SECONDS)

    def invoke_row_action(row_name, action):
        row = ui.wait_for_node(name=row_name, role=ui.pyatspi.ROLE_LIST_ITEM)
        actions = row.queryAction()
        for index in range(actions.nActions):
            if actions.getName(index) == action:
                actions.doAction(index)
                return
        names = [actions.getName(index) for index in range(actions.nActions)]
        raise AssertionError(f"{row_name!r} has no {action!r} action: {names!r}")

    def start_import(table, path):
        invoke_row_action(table, "sidebar-row.import-csv")
        ui.wait_for_node(name="Import CSV", role=ui.pyatspi.ROLE_DIALOG)
        ui.press_x11_key("l", ("Control_L",))
        ui.set_visible_editable_within("Import CSV", ui.FILE_CHOOSER_ROLES, str(path), action_name="Open")
        ui.invoke(ui.wait_for_node(name="Open", role=ui.pyatspi.ROLE_PUSH_BUTTON))
        ui.invoke(ui.wait_for_node(name="Import", role=ui.pyatspi.ROLE_PUSH_BUTTON))

    def import_csv_into(table, path):
        start_import(table, path)
        ui.wait_for_node_containing("Imported", role=ui.pyatspi.ROLE_LABEL)

    def open_tabs_with_unrelated_dirty_edit(database):
        ui.run_sql("CREATE TABLE other_items(id INTEGER PRIMARY KEY, note TEXT)")
        ui.wait_for_node(name="other_items", role=ui.pyatspi.ROLE_LIST_ITEM)
        with sqlite3.connect(database) as connection:
            connection.executemany(
                "INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")]
            )
            connection.executemany(
                "INSERT INTO other_items(id, note) VALUES (?, ?)", [(1, "x"), (2, "y")]
            )
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=ui.pyatspi.ROLE_LABEL)
        ui.invoke_named_action_within("other_items", "Open other_items")
        ui.wait_for_node_containing("other_items", role=ui.pyatspi.ROLE_PAGE_TAB)
        other_cell = ui.wait_for_node(name="x", role=ui.pyatspi.ROLE_LABEL)
        bounds = other_cell.queryComponent().getExtents(ui.pyatspi.WINDOW_COORDS)
        gtk_ux.x11_click(bounds.x + min(bounds.width, 40) // 2, bounds.y + bounds.height // 2, button=1, clicks=2)
        time.sleep(0.3)
        for key in "zz":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")

    def import_refreshes_only_the_imported_table(database, base):
        open_tabs_with_unrelated_dirty_edit(database)

        csv_path = base / "home" / "more.csv"
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        csv_path.write_text("id,note\n3,gamma\n4,delta\n", encoding="utf-8")
        import_csv_into("safety_items", csv_path)

        ui.wait_for_node_containing("Imported 2 rows", role=ui.pyatspi.ROLE_LABEL)
        ui.wait_for_node(name="Discard pending changes?", present=False)
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="gamma", role=ui.pyatspi.ROLE_LABEL)
        ui.invoke_named_action_within("other_items", "Open other_items")
        ui.wait_for_node(name="1 unsaved change")
        assert ui.find_node(name="Discard pending changes?") is None, "the import prompted to discard an unrelated edit"

    def failed_import_keeps_unrelated_edits(database, base):
        open_tabs_with_unrelated_dirty_edit(database)

        # Row 3 would commit, row 1 duplicates an existing key and stops the import.
        csv_path = base / "home" / "clash.csv"
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        csv_path.write_text("id,note\n3,gamma\n1,dup\n", encoding="utf-8")
        start_import("safety_items", csv_path)

        ui.wait_for_node_containing("Import stopped")
        # A discard prompt, if the refresh raised one, appears just after the
        # import ends. Give it time to show before asserting it is absent.
        time.sleep(3)
        assert ui.find_node(name="Discard pending changes?") is None, "the failed import prompted to discard an unrelated edit"
        assert notes(database) == [(1, "alpha"), (2, "beta")], "a failed import changed committed rows"
        ui.invoke_named_action_within("other_items", "Open other_items")
        ui.wait_for_node(name="1 unsaved change")
        assert ui.find_node(name="Discard pending changes?") is None, "the failed import prompted to discard an unrelated edit"

    import_refreshes_only_the_imported_table.environment = "local"
    failed_import_keeps_unrelated_edits.environment = "local"
    return [import_refreshes_only_the_imported_table, failed_import_keeps_unrelated_edits]
