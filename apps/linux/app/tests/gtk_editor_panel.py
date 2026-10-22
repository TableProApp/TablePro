import time


def scenarios(ui):
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
    return [results_panel_preserves_query_results_and_keyboard_focus]
