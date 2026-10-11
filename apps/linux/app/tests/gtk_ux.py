import ctypes
import json
import os
import time
from pathlib import Path

import gtk_input


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong), ("window_class", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
        ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p),
    ]


ATSPI_WINDOW_Y_OFFSET = int(os.environ.get("TABLEPRO_GTK_Y_OFFSET", "19"))


def x11_click(window_x, window_y, button=3, clicks=1):
    if gtk_input.uses_atspi_input():
        gtk_input.click(window_x, int(window_y) + ATSPI_WINDOW_Y_OFFSET, button, clicks)
        return
    x11 = ctypes.CDLL("libX11.so.6")
    xtst = ctypes.CDLL("libXtst.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XQueryTree.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
    xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    display = x11.XOpenDisplay(None)
    assert display, "X11 display is unavailable"
    try:
        root = x11.XDefaultRootWindow(display)
        root_return, parent, children, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        x11.XQueryTree(display, root, ctypes.byref(root_return), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
        origin = None
        for index in range(count.value):
            attrs = XWindowAttributes()
            x11.XGetWindowAttributes(display, children[index], ctypes.byref(attrs))
            if attrs.map_state == 2 and attrs.width >= 800 and attrs.height >= 600:
                origin = (attrs.x, attrs.y)
        if children:
            x11.XFree(children)
        assert origin is not None, "the application window was not found on the X display"
        xtst.XTestFakeMotionEvent(display, -1, origin[0] + int(window_x), origin[1] + int(window_y) + ATSPI_WINDOW_Y_OFFSET, 0)
        x11.XFlush(display)
        time.sleep(0.2)
        for _ in range(clicks):
            xtst.XTestFakeButtonEvent(display, button, 1, 0)
            xtst.XTestFakeButtonEvent(display, button, 0, 0)
            x11.XFlush(display)
            time.sleep(0.08)
    finally:
        x11.XCloseDisplay(display)


def scenarios(ui):
    pyatspi = ui.pyatspi
    ssh_trust_prompt_roles = (pyatspi.ROLE_ALERT, pyatspi.ROLE_FRAME)

    def wait_for_adw_dialog(name, present=True):
        if os.environ.get("TABLEPRO_GTK_OLD_ADW") == "1":
            return None
        return ui.wait_for_node(name=name, role=pyatspi.ROLE_DIALOG, present=present)

    def text_of(node):
        text = node.queryText()
        return text.getText(0, text.characterCount)

    def editor_text():
        application = ui.application_node()
        candidates = []
        for node in ui.descendants(application):
            if ui.node_role(node) != pyatspi.ROLE_TEXT:
                continue
            try:
                node.queryEditableText()
            except Exception:
                continue
            candidates.append(node)
        return text_of(max(candidates, key=lambda node: node.queryText().characterCount))

    def set_entry(name, text):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            for node in ui.descendants(ui.application_node()):
                if ui.node_name(node) == name and ui.node_role(node) in (pyatspi.ROLE_ENTRY, pyatspi.ROLE_TEXT):
                    try:
                        node.queryEditableText().setTextContents(text)
                        return
                    except Exception:
                        continue
            time.sleep(ui.POLL_SECONDS)
        raise AssertionError(f"no entry named {name!r}:\n{ui.accessible_snapshot()}")

    def saved_connections(base):
        files = list((base / "config").glob("*/connections.json"))
        assert len(files) == 1, files
        return json.loads(files[0].read_text())["connections"]

    def open_cell_menu(cell_text):
        cell = ui.wait_for_node(name=cell_text, role=pyatspi.ROLE_LABEL)
        extents = cell.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + min(extents.width, 40) // 2, extents.y + extents.height // 2)
        time.sleep(0.4)

    def wait_for_result_column(name, present=True):
        ui.wait_for_node_containing(f"{name}\n", role=pyatspi.ROLE_LABEL, present=present)

    def toggle_table_column(cell_text, column_name):
        open_cell_menu(cell_text)
        choose_menu_item(8)
        wait_for_adw_dialog("Columns")
        switch_roles = {getattr(pyatspi, "ROLE_SWITCH", pyatspi.ROLE_TOGGLE_BUTTON), pyatspi.ROLE_CHECK_BOX}
        switch = next(
            node for node in ui.descendants(ui.application_node())
            if ui.node_name(node) == column_name
            and ui.node_role(node) in switch_roles
            and node.queryAction().nActions > 0
        )
        ui.invoke(switch)
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("Columns", present=False)

    def choose_menu_item(position):
        for _ in range(position):
            ui.press_x11_key("Down")
            time.sleep(0.1)
        ui.press_x11_key("Return")

    def click_cell(cell_text, count=1):
        cell = ui.wait_for_node(name=cell_text, role=pyatspi.ROLE_LABEL)
        extents = cell.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + min(extents.width, 40) // 2, extents.y + extents.height // 2, button=1, clicks=count)
        time.sleep(0.3)

    def stored_notes(database):
        import sqlite3
        with sqlite3.connect(database) as connection:
            return connection.execute("SELECT id, note FROM safety_items ORDER BY id").fetchall()

    def browse_edit_cell_and_save_persists_to_the_database(database, base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")])
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        click_cell("alpha", count=2)
        for key in "gamma":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")
        assert stored_notes(database) == [(1, "alpha"), (2, "beta")], "an unsaved edit reached the database"
        ui.press_x11_key("s", ("Control_L",))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and stored_notes(database) != [(1, "gamma"), (2, "beta")]:
            time.sleep(ui.POLL_SECONDS)
        assert stored_notes(database) == [(1, "gamma"), (2, "beta")], stored_notes(database)
        ui.wait_for_node(name="1 unsaved change", present=False)

    def postgres_session_transaction_confirmation_cancels_or_rolls_back(database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        psql("DROP TABLE IF EXISTS public.session_rollback_probe; CREATE TABLE public.session_rollback_probe (id integer PRIMARY KEY)")

        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        session_toggle = ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.invoke(session_toggle)
        ui.run_sql("BEGIN")
        ui.wait_for_node(name="Session · transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.run_sql("INSERT INTO session_rollback_probe(id) VALUES (1)")
        ui.wait_for_node_containing("done in")
        assert psql("SELECT COUNT(*) FROM public.session_rollback_probe") == "0"
        ui.invoke(ui.wait_for_node(name="Session · transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="End the session with an open transaction?")
        ui.invoke(ui.wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
        toggle = ui.wait_for_node(name="Session · transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.run_sql("INSERT INTO session_rollback_probe(id) VALUES (2)")
        ui.wait_for_node_containing("done in")
        assert psql("SELECT COUNT(*) FROM public.session_rollback_probe") == "0"

        ui.invoke(toggle)
        ui.wait_for_node(name="End the session with an open transaction?")
        ui.invoke(ui.wait_for_node(name="Roll Back", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.wait_for_node(name="Session rolled back")
        assert psql("SELECT COUNT(*) FROM public.session_rollback_probe") == "0"

    def editing_a_saved_connection_prefills_it_and_saves_the_new_name(database, base):
        before = saved_connections(base)
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.invoke_named_action_within(ui.CONNECTION_B_NAME, "Edit connection")
        ui.wait_for_node(name=f"Edit {ui.CONNECTION_B_NAME}")
        name = ui.wait_for_node(name="Name (optional)", role=pyatspi.ROLE_TEXT)
        assert text_of(name) == ui.CONNECTION_B_NAME, text_of(name)
        ui.set_text_by_name("Name (optional)", "Renamed B")
        ui.invoke(ui.wait_for_node(name="Connect", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Renamed B — BookiE", role=pyatspi.ROLE_FRAME)
        after = saved_connections(base)
        assert len(after) == len(before), (before, after)
        assert "Renamed B" in [connection["name"] for connection in after], after
        assert ui.CONNECTION_B_NAME not in [connection["name"] for connection in after], after

    def open_edit_dialog_for(name):
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.invoke_named_action_within(name, "Edit connection")
        ui.wait_for_node(name=f"Edit {name}")

    def test_connection_reports_success_in_the_dialog(database, base):
        open_edit_dialog_for(ui.CONNECTION_B_NAME)
        ui.invoke(ui.wait_for_node(name="Test", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing("Connection ok")

    def test_connection_reports_failure_in_the_dialog(database, base):
        open_edit_dialog_for(ui.BROKEN_CONNECTION_NAME)
        ui.invoke(ui.wait_for_node(name="Test", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing("Test failed")
        assert ui.find_node_containing("Connection ok") is None

    def connect_dialog_cancel_stops_a_hanging_connection(database, base):
        import socket
        import threading

        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 5432))
        server.listen(4)
        held = []
        threading.Thread(target=lambda: [held.append(server.accept()) for _ in range(4)], daemon=True).start()
        try:
            ui.invoke(ui.wait_for_node(name="New connection", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name="Connect to PostgreSQL")
            set_entry("Host", "127.0.0.1")
            ui.invoke(ui.wait_for_node(name="Connect", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.invoke(ui.wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node_containing("Connection cancelled")
            ui.wait_for_node(name="Connect", role=pyatspi.ROLE_PUSH_BUTTON)
            assert ui.find_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON) is None
        finally:
            server.close()

        # A cancelled candidate must not take ownership of the workspace or
        # prevent a subsequent saved-connection switch from using its own DB.
        ui.invoke(ui.wait_for_node(name="Close", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Connect to PostgreSQL", present=False)
        ui.open_saved_connection(ui.CONNECTION_B_NAME)
        ui.wait_for_frame_containing(f"{ui.CONNECTION_B_NAME} — BookiE")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("INSERT INTO safety_items(id) VALUES (55)")
        database_b = base / "safety-b.sqlite"
        ui.wait_for_database_count(database_b, 1)
        assert ui.database_ids(database) == [], "cancelled connection changed the original database"
        assert ui.database_ids(database_b) == [55], "switch after cancellation used the wrong database"

    def app_memory_kb():
        import glob
        for status in glob.glob("/proc/[0-9]*/status"):
            try:
                executable = os.readlink(status.replace("status", "exe"))
                text = open(status).read()
            except OSError:
                continue
            if not executable.endswith("/usr/bin/tablepro"):
                continue
            fields = dict(line.split(":", 1) for line in text.splitlines() if ":" in line)
            return int(fields["VmRSS"].split()[0]), int(fields["VmHWM"].split()[0])
        raise AssertionError("application process not found")

    def a_second_launch_raises_the_window_and_exits_cleanly(database, base):
        import glob
        import subprocess
        for status in glob.glob("/proc/[0-9]*/status"):
            try:
                executable = os.readlink(status.replace("status", "exe"))
                raw_environment = open(status.replace("status", "environ"), "rb").read()
            except OSError:
                continue
            if executable.endswith("/usr/bin/tablepro"):
                break
        else:
            raise AssertionError("application process not found")
        environment = dict(item.split("=", 1) for item in raw_environment.decode().split("\0") if "=" in item)
        result = subprocess.run([executable], env=environment, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (result.returncode, result.stderr)
        assert "did not unregister" not in result.stderr, result.stderr
        assert "asked it to show its window" in result.stderr, result.stderr
        ui.wait_for_frame_containing(" — BookiE")

    def profile_table_browse_payload(rows, payload_bytes):
        ui.run_sql("CREATE TABLE profile_cells (id INTEGER PRIMARY KEY, person TEXT NOT NULL, payload TEXT NOT NULL)")
        ui.wait_for_node_containing("done in", timeout=300)
        half_bytes = (payload_bytes + 1) // 2
        ui.run_sql(
            f"WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {rows}) "
            "INSERT INTO profile_cells "
            f"SELECT x, 'person-' || x, substr(lower(hex(randomblob({half_bytes}))), 1, {payload_bytes}) FROM c"
        )
        ui.wait_for_node_containing("done in", timeout=300)
        before_rss, _ = app_memory_kb()
        started = time.monotonic()
        ui.wait_for_node(name="profile_cells")
        ui.invoke_named_action_within("profile_cells", "Open profile_cells")
        time.sleep(3)
        after_load = app_memory_kb()[0] / 1024
        actual_delta_mb = after_load - before_rss / 1024
        minimum_delta_mb = payload_bytes / (1024 * 1024) / 2
        assert actual_delta_mb >= minimum_delta_mb, (
            f"large table page did not retain the expected payload: delta={actual_delta_mb:.1f} MB, "
            f"minimum={minimum_delta_mb:.1f} MB"
        )
        with open(os.environ["TABLEPRO_PROFILE_OUT"], "a") as out:
            out.write(json.dumps({
                "profile_mode": "table-browse",
                "rows_requested": rows,
                "cell_payload_bytes": payload_bytes,
                "observation_after_open_seconds": round(time.monotonic() - started, 2),
                "rss_before_mb": round(before_rss / 1024, 1),
                "rss_delta_mb": round(actual_delta_mb, 1),
            }) + "\n")

    def profile_large_result_in_the_grid(database, base):
        rows = int(os.environ["TABLEPRO_PROFILE_ROWS"])
        payload_bytes = int(os.environ.get("TABLEPRO_PROFILE_CELL_BYTES", "0"))
        if rows < 1 or (payload_bytes != 0 and not 8_193 <= payload_bytes <= 8 * 1024 * 1024):
            raise ValueError("profile rows and cell payload size are outside their supported bounds")
        if payload_bytes:
            profile_table_browse_payload(rows, payload_bytes)
            return

        def rss_sample():
            resident, high_water = app_memory_kb()
            return {"rss_mb": round(resident / 1024, 1), "peak_mb": round(high_water / 1024, 1)}

        sql = (
            f"WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < {rows}) "
            "SELECT x, 'person-' || x, x * 1.5, x % 2, datetime('2026-01-01', '+' || (x % 100000) || ' seconds'), "
            "'a note of moderate length for row ' || x || ' to give text columns some weight' FROM c"
        )
        before_rss, _ = app_memory_kb()
        started = time.monotonic()
        ui.run_sql(sql)
        ui.wait_for_node_containing("done in", timeout=300)
        first_result_seconds = time.monotonic() - started
        time.sleep(3)
        after_load = rss_sample()

        application = ui.application_node()
        scrollbars = []
        for node in ui.descendants(application):
            if ui.node_role(node) != ui.pyatspi.ROLE_SCROLL_BAR:
                continue
            try:
                bounds = node.queryComponent().getExtents(ui.pyatspi.WINDOW_COORDS)
                value = node.queryValue()
                if bounds.height > bounds.width and value.maximumValue > value.minimumValue:
                    scrollbars.append((bounds.height, bounds.x, bounds.y, value))
            except Exception:
                continue
        assert scrollbars, f"no usable vertical scrollbar in accessibility tree:\n{ui.accessible_snapshot()}"

        def visible_row_range():
            found = []
            for node in ui.descendants(application):
                name = ui.node_name(node)
                if name.startswith("person-"):
                    try:
                        found.append(int(name.removeprefix("person-")))
                    except ValueError:
                        pass
            return [min(found), max(found)] if found else []

        initial_visible = visible_row_range()
        probes = []
        for height, x, y, value in scrollbars:
            value.set_currentValue(value.maximumValue)
            time.sleep(0.5)
            observed = visible_row_range()
            probes.append({"x": x, "y": y, "height": height, "rows": observed})
            value.set_currentValue(value.minimumValue)
            time.sleep(0.3)
        moving = [entry for entry in probes if entry["rows"] and initial_visible and entry["rows"][1] > initial_visible[1]]
        assert moving, f"no vertical scrollbar moved grid rows: initial={initial_visible}, probes={probes}"
        chosen = max(moving, key=lambda entry: entry["rows"][1])
        scrollbar = next(value for _, x, y, value in scrollbars if x == chosen["x"] and y == chosen["y"])
        lower = scrollbar.minimumValue
        upper = scrollbar.maximumValue

        def traverse_to(start_fraction, end_fraction, steps):
            started_scroll = time.monotonic()
            for step in range(1, steps + 1):
                fraction = start_fraction + (end_fraction - start_fraction) * step / steps
                scrollbar.set_currentValue(lower + (upper - lower) * fraction)
                time.sleep(0.005)
            time.sleep(2)
            sample = rss_sample()
            sample["visible_rows"] = visible_row_range()
            sample["scrollbar_value"] = round(scrollbar.currentValue, 2)
            return round(time.monotonic() - started_scroll, 3), sample

        scroll_steps = int(os.environ.get("TABLEPRO_PROFILE_SCROLL_STEPS", str(min(20000, max(1000, rows // 10)))))
        middle_steps = max(1, scroll_steps // 2)
        middle_seconds, middle = traverse_to(0.0, 0.5, middle_steps)
        end_seconds, end = traverse_to(0.5, 1.0, scroll_steps - middle_steps or 1)
        top_seconds, top = traverse_to(1.0, 0.0, scroll_steps)
        _, peak = app_memory_kb()
        result_status = sorted({
            ui.node_name(node) for node in ui.descendants(application)
            if any(word in ui.node_name(node).lower() for word in ("done in", "truncat"))
        })
        line = json.dumps({
            "rows_requested": rows,
            "cell_payload_bytes": payload_bytes,
            "repetition": int(os.environ.get("TABLEPRO_PROFILE_REPETITION", "1")),
            "rows_loaded_inferred": end["visible_rows"][1] if end["visible_rows"] else None,
            "truncated_inferred": bool(end["visible_rows"] and end["visible_rows"][1] < rows),
            "result_status": result_status,
            "first_result_seconds": round(first_result_seconds, 2),
            "rss_before_mb": round(before_rss / 1024, 1),
            "after_load": after_load, "after_middle": middle,
            "after_end": end, "after_return_top": top,
            "scroll_seconds": {"middle": middle_seconds, "end": end_seconds, "top": top_seconds},
            "visible_person_rows": visible_row_range(),
            "scrollbar_probes": probes,
            "peak_mb": round(peak / 1024, 1),
        })
        with open(os.environ["TABLEPRO_PROFILE_OUT"], "a") as out:
            out.write(line + "\n")

    def find_bar_replaces_every_match_in_the_editor(database, base):
        ui.set_editor_text("select a, a from t where a = 1")
        time.sleep(0.3)
        ui.press_x11_key("f", ("Control_L",))
        ui.wait_for_node(name="Next match", role=pyatspi.ROLE_PUSH_BUTTON)
        set_entry("Find", "a")
        ui.invoke(ui.wait_for_node(name="Replace", role=pyatspi.ROLE_TOGGLE_BUTTON))
        set_entry("Replace with", "b")
        ui.invoke(ui.wait_for_node(name="Replace All", role=pyatspi.ROLE_PUSH_BUTTON))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and editor_text() != "select b, b from t where b = 1":
            time.sleep(ui.POLL_SECONDS)
        assert editor_text() == "select b, b from t where b = 1", editor_text()

    def view_value_opens_the_whole_cell_with_pretty_json(database, base):
        ui.run_sql("""SELECT '{"a":1}' AS payload""")
        open_cell_menu('{"a":1}')
        choose_menu_item(3)
        wait_for_adw_dialog("payload")
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            if any(
                ui.node_role(node) == pyatspi.ROLE_TEXT and '"a": 1' in text_of(node)
                for node in ui.descendants(ui.application_node())
            ):
                break
            time.sleep(ui.POLL_SECONDS)
        else:
            raise AssertionError(f"the viewer did not show pretty JSON:\n{ui.accessible_snapshot()}")
        ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_PUSH_BUTTON)

    def columns_dialog_hides_a_column_and_keeps_the_last_one(database, base):
        ui.run_sql("SELECT 1 AS alpha, 2 AS beta")
        wait_for_result_column("beta")
        open_cell_menu("1")
        choose_menu_item(6)
        wait_for_adw_dialog("Columns")
        switch_roles = {getattr(pyatspi, "ROLE_SWITCH", pyatspi.ROLE_TOGGLE_BUTTON), pyatspi.ROLE_CHECK_BOX}
        switches = [
            node for node in ui.descendants(ui.application_node())
            if ui.node_name(node) in ("alpha", "beta")
            and ui.node_role(node) in switch_roles
            and node.queryAction().nActions > 0
        ]
        assert len(switches) == 2, ui.accessible_snapshot()
        by_name = {ui.node_name(node): node for node in switches}
        ui.invoke(by_name["beta"])
        ui.invoke(by_name["alpha"])
        time.sleep(0.3)
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("Columns", present=False)
        wait_for_result_column("beta", present=False)
        wait_for_result_column("alpha")

    def session_transaction_label_and_toggle_off_confirmation(database, base):
        def session_toggle(name):
            return ui.wait_for_node(name=name, role=pyatspi.ROLE_TOGGLE_BUTTON)

        ui.invoke(session_toggle("Session"))
        time.sleep(0.5)
        ui.run_sql("BEGIN")
        session_toggle("Session \u00b7 transaction open")
        ui.invoke(session_toggle("Session \u00b7 transaction open"))
        ui.invoke(ui.wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Roll Back", role=pyatspi.ROLE_PUSH_BUTTON, present=False)
        session_toggle("Session \u00b7 transaction open")
        ui.invoke(session_toggle("Session \u00b7 transaction open"))
        ui.invoke(ui.wait_for_node(name="Roll Back", role=pyatspi.ROLE_PUSH_BUTTON))
        session_toggle("Session")

    def wait_for_editor_text(expected):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            if editor_text() == expected:
                return
            time.sleep(ui.POLL_SECONDS)
        raise AssertionError(f"expected the {expected!r} tab, the editor shows {editor_text()!r}")

    def open_three_editor_tabs():
        ui.set_editor_text("-- one")
        for label in ("-- two", "-- three"):
            ui.press_x11_key("t", ("Control_L",))
            time.sleep(0.5)
            ui.set_editor_text(label)
        wait_for_editor_text("-- three")

    def ctrl_tab_returns_to_the_most_recently_used_tab(database, base):
        open_three_editor_tabs()
        ui.press_x11_key("Tab", ("Control_L",))
        wait_for_editor_text("-- two")
        ui.press_x11_key("Tab", ("Control_L",))
        wait_for_editor_text("-- three")

    def holding_ctrl_while_pressing_tab_walks_deeper_into_the_history(database, base):
        open_three_editor_tabs()
        ui.press_x11_key("Tab", ("Control_L",), presses=2)
        wait_for_editor_text("-- one")
        ui.press_x11_key("Tab", ("Control_L",))
        wait_for_editor_text("-- three")

    def interactive_controls_have_accessible_names(database, base):
        ui.run_sql("SELECT 1 AS alpha")
        wait_for_result_column("alpha")
        roles = {
            pyatspi.ROLE_PUSH_BUTTON: "push button",
            pyatspi.ROLE_TOGGLE_BUTTON: "toggle button",
            pyatspi.ROLE_CHECK_BOX: "check box",
            pyatspi.ROLE_COMBO_BOX: "combo box",
            pyatspi.ROLE_ENTRY: "entry",
        }
        unnamed = [
            f"{roles[ui.node_role(node)]} {node.getRoleName()!r} at {node.queryComponent().getExtents(pyatspi.WINDOW_COORDS).x},"
            f"{node.queryComponent().getExtents(pyatspi.WINDOW_COORDS).y}"
            for node in ui.descendants(ui.application_node())
            if ui.node_role(node) in roles and not ui.node_name(node).strip()
        ]
        assert not unnamed, "controls without an accessible name:\n" + "\n".join(unnamed)

    def alt_arrows_jump_between_statements(database, base):
        sql = "select 1;\nselect 2;\nselect 3"
        editor = ui.set_editor_text(sql)

        def caret():
            return editor.queryText().caretOffset

        def wait_for_caret(expected):
            deadline = time.monotonic() + ui.WAIT_SECONDS
            while time.monotonic() < deadline:
                if caret() == expected:
                    return
                time.sleep(ui.POLL_SECONDS)
            raise AssertionError(f"expected the caret at {expected}, it is at {caret()}")

        extents = editor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + 60, extents.y + 10, button=1)
        time.sleep(0.3)
        ui.press_x11_key("End", ("Control_L",))
        wait_for_caret(len(sql))
        second, third = sql.index("select 2"), sql.index("select 3")
        ui.press_x11_key("Up", ("Alt_L", "Shift_L"))
        wait_for_caret(third)
        ui.press_x11_key("Up", ("Alt_L", "Shift_L"))
        wait_for_caret(second)
        ui.press_x11_key("Down", ("Alt_L", "Shift_L"))
        wait_for_caret(third)

    def row_inspector_lists_every_column_of_the_selected_row(database, base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")])
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        ui.invoke(ui.wait_for_node(name="Row inspector", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="No row selected")
        click_cell("beta")
        ui.wait_for_node(name="No row selected", present=False)
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            names = {ui.node_name(node) for node in ui.descendants(ui.application_node())}
            titles = [name for name in names if "\u00b7" in name and name.split(" ")[0] in ("id", "note")]
            if len(titles) >= 2 and "beta" in names:
                break
            time.sleep(ui.POLL_SECONDS)
        else:
            raise AssertionError(f"the inspector did not list the row:\n{ui.accessible_snapshot()}")

    def find_in_loaded_rows_lists_matches_and_selects_one(database, base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")])
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        click_cell("alpha")
        ui.press_x11_key("f", ("Control_L", "Alt_L"))
        search = ui.wait_for_node(name="Search the loaded rows")
        search.queryEditableText().setTextContents("bet")
        ui.wait_for_node(name="2 \u00b7 note: beta")
        ui.press_x11_key("Return")
        ui.wait_for_node(name="Search the loaded rows", present=False)

    def ctrl_slash_toggles_a_comment_in_the_editor(database, base):
        editor = ui.set_editor_text("select 1")
        extents = editor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + 60, extents.y + 10, button=1)
        time.sleep(0.3)
        ui.press_x11_key("slash", ("Control_L",))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and not editor_text().startswith("--"):
            time.sleep(ui.POLL_SECONDS)
        assert editor_text().startswith("--"), editor_text()
        assert ui.find_node(name="Keyboard Shortcuts") is None, "the shortcuts window opened instead"

    def postgres_saved_connection_browses_rows_and_values(database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="people")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("SELECT id, name, profile, active FROM people ORDER BY id")
        ui.wait_for_node(name="Ada Lovelace", role=pyatspi.ROLE_LABEL)
        ui.wait_for_node(name="Grace Hopper", role=pyatspi.ROLE_LABEL)
        open_cell_menu("Ada Lovelace")
        choose_menu_item(3)
        wait_for_adw_dialog("name")
        ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("name", present=False)

    def postgres_hidden_projection_refresh_and_edit_preserve_hidden_value(database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.invoke_named_action_within("public.people", "Open people")
        ui.wait_for_node(name="Ada Lovelace", role=pyatspi.ROLE_LABEL)
        toggle_table_column("Ada Lovelace", "profile")
        wait_for_result_column("profile", present=False)
        ui.press_x11_key("F5")
        ui.wait_for_node(name="Ada Lovelace", role=pyatspi.ROLE_LABEL)
        click_cell("Ada Lovelace")
        ui.invoke(ui.wait_for_node(name="Row inspector", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="Not fetched")
        assert psql("SELECT profile->>'role' FROM people WHERE id=1") == "analyst"

        psql("UPDATE people SET name='AdaByron' WHERE id=1")
        ui.press_x11_key("F5")
        ui.wait_for_node(name="AdaByron", role=pyatspi.ROLE_LABEL)
        click_cell("AdaByron", count=2)
        for key in "AdaLovelace":
            ui.press_x11_key(key.lower(), ("Shift_L",) if key.isupper() else ())
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")
        ui.press_x11_key("s", ("Control_L",))
        wait_for_oracle(psql, "SELECT name FROM people WHERE id=1", "AdaLovelace")
        assert psql("SELECT profile->>'role' FROM people WHERE id=1") == "analyst"

        toggle_table_column("AdaLovelace", "profile")
        ui.press_x11_key("F5")
        wait_for_result_column("profile")
        ui.wait_for_node_containing("analyst", role=pyatspi.ROLE_LABEL)

    def postgres_saved_mtls_connection_authenticates_and_queries(database, base):
        ui.open_saved_connection(ui.POSTGRES_MTLS_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_MTLS_CONNECTION_NAME} — BookiE")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("SELECT count(*) AS row_count FROM release_items")
        ui.wait_for_node(name="3", role=pyatspi.ROLE_LABEL)

    def postgres_ssh_unknown_host_key_decline_is_durably_audited(database, base):
        name = ui.POSTGRES_SSH_AUDIT_CONNECTION_NAME
        connection_id = ui.POSTGRES_SSH_AUDIT_CONNECTION_ID
        ui.open_saved_connection(name)
        prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
        ui.wait_for_node_containing("127.0.0.1:2223")
        ui.invoke(ui.wait_within(prompt, name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)
        ui.wait_for_node(name="Connection failed")

        journal = base / "data" / ui.storage_dir_name() / "audit.jsonl"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        records = []
        while time.monotonic() < deadline:
            if journal.exists():
                records = [json.loads(line)["event"] for line in journal.read_text().splitlines() if line.strip()]
                attempts = [event for event in records if event.get("transport_attempt")]
                if attempts:
                    break
            time.sleep(ui.POLL_SECONDS)
        attempts = [event for event in records if event.get("transport_attempt")]
        assert len(attempts) == 1, f"expected one durable SSH outcome, found {attempts!r}"
        event = attempts[0]
        assert event["connection_id"] == connection_id, event
        assert event["phase"] == "outcome", event
        assert event["terminal_status"] == "denied", event
        assert event["transport_attempt"] == {"client": "builtin_ssh", "outcome": "host_key_refused"}, event

        known_hosts = base / "config" / ui.storage_dir_name() / "known_hosts"
        assert not known_hosts.exists() or not known_hosts.read_text().strip(), (
            "declining the host key must not learn it"
        )

    def trust_postgres_ssh_chain():
        prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
        ui.wait_for_node_containing("127.0.0.1:2223")
        ui.invoke(ui.wait_within(prompt, name="Trust", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)
        jump_host = os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST")
        if jump_host:
            jump_port = os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_PORT", "22")
            second_prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
            ui.wait_for_node_containing(f"{jump_host}:{jump_port}")
            ui.invoke(ui.wait_within(second_prompt, name="Trust", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)

    def postgres_ssh_unknown_host_key_accepts_and_queries(database, base):
        name = ui.POSTGRES_SSH_AUDIT_CONNECTION_NAME
        ui.open_saved_connection(name)
        trust_postgres_ssh_chain()
        ui.wait_for_frame_containing(f"{name} — BookiE")

        known_hosts = base / "config" / ui.storage_dir_name() / "known_hosts"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and (not known_hosts.exists() or not known_hosts.read_text().strip()):
            time.sleep(ui.POLL_SECONDS)
        assert known_hosts.exists() and known_hosts.read_text().strip(), (
            "accepting the host key must persist it in the isolated known_hosts file"
        )
        if os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST"):
            assert len([line for line in known_hosts.read_text().splitlines() if line.strip()]) == 2, (
                "the full jump chain must persist both accepted host keys"
            )

        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("SELECT count(*) AS row_count FROM release_items")
        ui.wait_for_node(name="3", role=pyatspi.ROLE_LABEL)

        journal = base / "data" / ui.storage_dir_name() / "audit.jsonl"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        attempts = []
        while time.monotonic() < deadline:
            if journal.exists():
                records = [json.loads(line)["event"] for line in journal.read_text().splitlines() if line.strip()]
                attempts = [event for event in records if event.get("transport_attempt")]
                if attempts:
                    break
            time.sleep(ui.POLL_SECONDS)
        assert len(attempts) == 1, f"expected one terminal SSH audit event for the complete chain: {attempts!r}"
        assert attempts[0]["connection_id"] == ui.POSTGRES_SSH_AUDIT_CONNECTION_ID
        assert attempts[0]["transport_attempt"] == {"client": "builtin_ssh", "outcome": "connected"}

    def postgres_ssh_multihop_trusts_both_hops_and_queries(database, base):
        assert os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST") == "relay", (
            "the two-hop release fixture must configure its relay jump host"
        )
        postgres_ssh_unknown_host_key_accepts_and_queries(database, base)

    def postgres_ssh_second_hop_decline_does_not_learn_key(database, base):
        name = ui.POSTGRES_SSH_AUDIT_CONNECTION_NAME
        ui.open_saved_connection(name)
        first_prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
        ui.wait_for_node_containing("127.0.0.1:2223")
        ui.invoke(ui.wait_within(first_prompt, name="Trust", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)

        second_prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
        ui.wait_for_node_containing("relay:22")
        ui.invoke(ui.wait_within(second_prompt, name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)
        ui.wait_for_node(name="Connection failed")

        known_hosts = base / "config" / ui.storage_dir_name() / "known_hosts"
        assert known_hosts.exists(), "first-hop trust should persist before the second-hop decision"
        learned = [line for line in known_hosts.read_text().splitlines() if line.strip()]
        assert len(learned) == 1, f"declining the second hop must not persist its key: {learned!r}"

        journal = base / "data" / ui.storage_dir_name() / "audit.jsonl"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        attempts = []
        while time.monotonic() < deadline:
            if journal.exists():
                records = [json.loads(line)["event"] for line in journal.read_text().splitlines() if line.strip()]
                attempts = [event for event in records if event.get("transport_attempt")]
                if attempts:
                    break
            time.sleep(ui.POLL_SECONDS)
        assert len(attempts) == 1, f"expected one terminal SSH refusal event, got {attempts!r}"
        event = attempts[0]
        assert event["connection_id"] == ui.POSTGRES_SSH_AUDIT_CONNECTION_ID, event
        assert event["terminal_status"] == "denied", event
        assert event["transport_attempt"] == {"client": "builtin_ssh", "outcome": "host_key_refused"}, event

    def postgres_ssh_changed_second_hop_key_is_refused(database, base):
        name = ui.POSTGRES_SSH_AUDIT_CONNECTION_NAME
        known_hosts = base / "config" / ui.storage_dir_name() / "known_hosts"
        known_hosts.parent.mkdir(parents=True, exist_ok=True)
        wrong_host_key = Path(os.environ["TABLEPRO_FIXTURE_MATERIALS"]) / "ssh_host_ed25519_key.pub"
        key_parts = wrong_host_key.read_text(encoding="utf-8").split()
        assert len(key_parts) >= 2, "the release fixture must provide the bastion host public key"
        relay_record = f"relay {key_parts[0]} {key_parts[1]} fixture-wrong-relay-key\n"
        known_hosts.write_text(relay_record, encoding="utf-8")

        ui.open_saved_connection(name)
        first_prompt = ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles)
        ui.wait_for_node_containing("127.0.0.1:2223")
        ui.invoke(ui.wait_within(first_prompt, name="Trust", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)
        ui.wait_for_node(name="Connection failed")
        ui.wait_for_node(name="Trust this SSH host?", role=ssh_trust_prompt_roles, present=False)
        ui.wait_for_node_containing("changed")

        records_in_file = [line for line in known_hosts.read_text().splitlines() if line.strip()]
        assert len(records_in_file) == 2, f"the changed relay key must not overwrite either record: {records_in_file!r}"
        assert records_in_file[0] == relay_record.strip(), "the pre-trusted wrong relay key must remain unchanged"

        journal = base / "data" / ui.storage_dir_name() / "audit.jsonl"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        attempts = []
        while time.monotonic() < deadline:
            if journal.exists():
                records = [json.loads(line)["event"] for line in journal.read_text().splitlines() if line.strip()]
                attempts = [event for event in records if event.get("transport_attempt")]
                if attempts:
                    break
            time.sleep(ui.POLL_SECONDS)
        assert len(attempts) == 1, f"expected one terminal host-key-change event, got {attempts!r}"
        event = attempts[0]
        assert event["connection_id"] == ui.POSTGRES_SSH_AUDIT_CONNECTION_ID, event
        assert event["terminal_status"] == "denied", event
        assert event["transport_attempt"] == {"client": "builtin_ssh", "outcome": "host_key_changed"}, event

    def postgres_ssh_setup_failure_is_durably_audited(database, base):
        ui.open_saved_connection(ui.POSTGRES_SSH_SETUP_FAILURE_CONNECTION_NAME)
        ui.wait_for_node(name="Connection failed")

        journal = base / "data" / ui.storage_dir_name() / "audit.jsonl"
        deadline = time.monotonic() + ui.WAIT_SECONDS
        attempts = []
        while time.monotonic() < deadline:
            if journal.exists():
                records = [json.loads(line)["event"] for line in journal.read_text().splitlines() if line.strip()]
                attempts = [
                    event for event in records
                    if event.get("decision_rule") == "transport_attempt"
                    and event.get("connection_id") == ui.POSTGRES_SSH_SETUP_FAILURE_CONNECTION_ID
                ]
                if attempts:
                    break
            time.sleep(ui.POLL_SECONDS)
        assert len(attempts) == 1, f"expected one durable SSH setup failure outcome, found {attempts!r}"
        event = attempts[0]
        assert event["phase"] == "outcome", event
        assert event["terminal_status"] == "failed", event
        assert event["transport_attempt"] == {"client": "builtin_ssh", "outcome": "connection_failed"}, event

    def postgres_ssh_tunnel_loss_retires_session_and_reconnects(database, base):
        import urllib.request

        def set_bastion_enabled(enabled):
            request = urllib.request.Request(
                "http://127.0.0.1:8474/proxies/bastion",
                data=json.dumps({"enabled": enabled}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                assert response.status == 200, f"Toxiproxy returned {response.status}"

        psql(
            "DROP TABLE IF EXISTS public.session_tunnel_loss_probe; "
            "CREATE TABLE public.session_tunnel_loss_probe (id integer PRIMARY KEY)"
        )
        name = ui.POSTGRES_SSH_AUDIT_CONNECTION_NAME
        ui.open_saved_connection(name)
        trust_postgres_ssh_chain()
        ui.wait_for_frame_containing(f"{name} — BookiE")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.invoke(ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.run_sql("BEGIN")
        ui.wait_for_node(name="Session · transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON)
        # Observe the insert result before issuing the SELECT. The GTK action
        # starts query work asynchronously, so dispatching both back-to-back
        # can let the SELECT race ahead of the INSERT on a loaded runner.
        ui.run_sql("INSERT INTO session_tunnel_loss_probe VALUES (1) RETURNING id")
        ui.wait_for_node(name="1", role=pyatspi.ROLE_LABEL)
        ui.run_sql("SELECT id FROM session_tunnel_loss_probe WHERE id = 1")
        ui.wait_for_node(name="1", role=pyatspi.ROLE_LABEL)
        assert psql("SELECT count(*) FROM public.session_tunnel_loss_probe") == "0"

        set_bastion_enabled(False)
        try:
            ui.wait_for_node_containing("Connection lost — reconnecting")
        finally:
            set_bastion_enabled(True)
        # The monitor uses a five-second initial backoff. Allow that bounded
        # attempt to finish; then the stale-session and replacement-session
        # assertions below provide the observable recovery proof.
        time.sleep(6)

        # The old dedicated session must be retired even though the saved
        # connection has already reconnected. A write through that stale
        # session must not reach PostgreSQL.
        ui.run_sql("INSERT INTO session_tunnel_loss_probe VALUES (2)")
        ui.wait_for_node_containing("error in")
        ui.wait_for_node_containing("session was retired")
        assert psql("SELECT count(*) FROM public.session_tunnel_loss_probe") == "0"

        ui.invoke(ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON)
        for _ in range(4):
            ui.run_sql("SELECT 42")
            try:
                ui.wait_for_node(name="42", role=pyatspi.ROLE_LABEL, timeout=10)
                break
            except AssertionError:
                continue
        else:
            ui.run_sql("SELECT 42")
            ui.wait_for_node(name="42", role=pyatspi.ROLE_LABEL)
        assert psql("SELECT count(*) FROM public.session_tunnel_loss_probe") == "0"

    def psql(sql):
        import subprocess
        out = subprocess.run(
            ["docker", "exec", os.environ["TABLEPRO_GTK_POSTGRES_CONTAINER"], "psql",
             f"--username={os.environ.get('TABLEPRO_GTK_POSTGRES_USER', 'postgres')}",
             f"--dbname={os.environ.get('TABLEPRO_GTK_POSTGRES_DB', 'bookie_test')}",
             "--tuples-only", "--no-align", f"--command={sql}"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()

    def wait_for_psql(sql, expected):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and psql(sql) != expected:
            time.sleep(ui.POLL_SECONDS)
        assert psql(sql) == expected, (sql, psql(sql), expected)

    def grid_edit_and_delete_commit_to_the_server(connection_name, table_anchor, oracle):
        ui.open_saved_connection(connection_name)
        ui.wait_for_frame_containing(f"{connection_name} — BookiE")
        ui.invoke_named_action_within(table_anchor, "Open people")
        ui.wait_for_node(name="Grace Hopper", role=pyatspi.ROLE_LABEL)
        click_cell("Grace Hopper", count=2)
        for key in "gracey":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")
        assert oracle("SELECT name FROM people WHERE id = 2") == "Grace Hopper", "an unsaved edit reached the server"
        ui.press_x11_key("s", ("Control_L",))
        wait_for_oracle(oracle, "SELECT name FROM people WHERE id = 2", "gracey")
        assert ui.find_node(name="Approve once") is None, "a plain grid edit asked for approval"
        ui.wait_for_node(name="1 unsaved change", present=False)

        open_cell_menu("gracey")
        choose_menu_item(14)
        ui.wait_for_node(name="1 unsaved change")
        assert oracle("SELECT count(*) FROM people") == "2", "an unsaved delete reached the server"
        ui.press_x11_key("s", ("Control_L",))
        assert ui.find_node(name="Approve once") is None, "a plain grid delete asked for approval"
        ui.wait_for_node(name="1 unsaved change", present=False)
        wait_for_oracle(oracle, "SELECT count(*) FROM people", "1")
        wait_for_oracle(oracle, "SELECT id FROM people", "1")
        assert ui.find_node(name="Approve once") is None, "a plain grid delete asked for approval"

    def wait_for_oracle(oracle, sql, expected):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and oracle(sql) != expected:
            time.sleep(ui.POLL_SECONDS)
        assert oracle(sql) == expected, (sql, oracle(sql), expected)

    def postgres_database_switcher_reconnects_to_the_chosen_database(database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="public.people", role=pyatspi.ROLE_LIST_ITEM)
        ui.invoke(ui.wait_for_node(name="Switch database", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.wait_for_node(name="bookie_test")
        ui.invoke(ui.wait_for_node(name="bookie_other", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="public.other_things", role=pyatspi.ROLE_LIST_ITEM)
        ui.wait_for_node(name="public.people", role=pyatspi.ROLE_LIST_ITEM, present=False)
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and {c["name"]: c["database"] for c in saved_connections(base)}.get(ui.POSTGRES_CONNECTION_NAME) != "bookie_other":
            time.sleep(ui.POLL_SECONDS)
        databases = {connection["name"]: connection["database"] for connection in saved_connections(base)}
        assert databases[ui.POSTGRES_CONNECTION_NAME] == "bookie_other", databases

    def mysql(sql):
        import subprocess
        out = subprocess.run(
            ["docker", "exec", os.environ["TABLEPRO_GTK_MYSQL_CONTAINER"], "mysql", "--user=root",
             "--password=tablepro_test", "--batch", "--skip-column-names", "bookie_test", f"--execute={sql}"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()

    def mongodb(sql):
        import subprocess
        out = subprocess.run(
            ["docker", "exec", os.environ["TABLEPRO_GTK_MONGODB_CONTAINER"], "mongosh", "--quiet",
             "bookie_test", f"--eval={sql}"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()

    def clickhouse(sql):
        import subprocess
        out = subprocess.run(
            ["docker", "exec", os.environ["TABLEPRO_GTK_CLICKHOUSE_CONTAINER"], "clickhouse-client",
             "--user=default", "--password=tablepro", "--format=TabSeparatedRaw", f"--query={sql}"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()

    def mongodb_name():
        return json.loads(mongodb("JSON.stringify(db.people.findOne({_id: 2}).name)"))

    def mongodb_grid_observes_cursor_values_until_refresh_and_edits_native_row(database, base):
        name = ui.MONGODB_CONNECTION_NAME
        ui.open_saved_connection(name)
        ui.wait_for_frame_containing(f"{name} — BookiE")
        ui.invoke_named_action_within("bookie_test.people", "Open people")
        ui.wait_for_node(name="Grace Hopper", role=pyatspi.ROLE_LABEL)

        assert mongodb_name() == "Grace Hopper"
        assert mongodb(
            'db.people.updateOne({_id: 2}, {$set: {name: "Server update"}}).matchedCount'
        ) == "1"
        ui.wait_for_node(name="Grace Hopper", role=pyatspi.ROLE_LABEL)
        assert ui.find_node(name="Server update") is None, "a loaded page changed without a new cursor"

        ui.press_x11_key("F5")
        ui.wait_for_node(name="Grace Hopper", role=pyatspi.ROLE_LABEL, present=False)
        ui.wait_for_node(name="Server update", role=pyatspi.ROLE_LABEL)
        click_cell("Server update", count=2)
        for key in "clientedit":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")
        assert mongodb_name() == "Server update", "an unsaved grid edit reached MongoDB"
        ui.press_x11_key("s", ("Control_L",))
        ui.wait_for_node(name="Approve write: Safety MongoDB")
        ui.invoke(ui.wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON))
        try:
            ui.wait_for_node(name="1 unsaved change", present=False)
        except AssertionError as error:
            raise AssertionError(
                f"MongoDB grid edit did not save; server value is {mongodb_name()}: {error}"
            ) from error
        assert mongodb_name() == "clientedit"
        row = json.loads(mongodb("JSON.stringify(db.people.findOne({_id: 2}))"))
        assert row == {"_id": 2, "name": "clientedit", "note": "untouched"}, row
    def clickhouse_enum_grid_edit_preserves_native_label_and_siblings(database, base):
        ui.open_saved_connection(ui.CLICKHOUSE_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.CLICKHOUSE_CONNECTION_NAME} — BookiE")
        ui.invoke_named_action_within("default.enum_grid", "Open enum_grid")
        ui.wait_for_node(name="low8", role=pyatspi.ROLE_LABEL)
        click_cell("low8", count=2)
        for key in "high8":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        click_cell("low16", count=2)
        for key in "high16":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="2 unsaved changes")

        query = (
            "SELECT toString(id), "
            "toString(isNull(state8)), toString(CAST(assumeNotNull(state8) AS Int8)), "
            "ifNull(toString(state8), '<SQL_NULL>'), "
            "toString(isNull(state16)), toString(CAST(assumeNotNull(state16) AS Int16)), "
            "ifNull(toString(state16), '<SQL_NULL>') "
            "FROM default.enum_grid ORDER BY id FORMAT TabSeparatedRaw"
        )
        before_save = "\n".join((
            "1\t0\t-128\tlow8\t0\t-32768\tlow16",
            "2\t0\t0\tNULL\t0\t0\tNULL",
            "3\t1\t0\t<SQL_NULL>\t1\t0\t<SQL_NULL>",
            "4\t0\t1\t\t0\t1\t",
            "5\t0\t127\thigh8\t0\t32767\thigh16",
        ))
        after_save = "\n".join((
            "1\t0\t127\thigh8\t0\t32767\thigh16",
            "2\t0\t0\tNULL\t0\t0\tNULL",
            "3\t1\t0\t<SQL_NULL>\t1\t0\t<SQL_NULL>",
            "4\t0\t1\t\t0\t1\t",
            "5\t0\t127\thigh8\t0\t32767\thigh16",
        ))
        assert clickhouse(query) == before_save, "pending grid edits reached ClickHouse"
        ui.press_x11_key("s", ("Control_L",))
        approval = ui.find_node(name="Approve once")
        if approval is not None:
            ui.invoke(approval)
        wait_for_oracle(clickhouse, query, after_save)
        ui.wait_for_node(name="2 unsaved changes", present=False)

    def postgres_grid_edit_and_delete_commit_to_the_server(database, base):
        grid_edit_and_delete_commit_to_the_server(ui.POSTGRES_CONNECTION_NAME, "public.people", psql)

    def postgres_enum_grid_edit_preserves_native_label_and_siblings(database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.invoke_named_action_within("public.enum_grid", "Open enum_grid")
        ui.wait_for_node(name="ready", role=pyatspi.ROLE_LABEL)
        click_cell("ready", count=2)
        for key in "done":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")

        click_cell("NULL", count=2)
        for key in "done":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="2 unsaved changes")

        snapshot = "SELECT string_agg(format('%s:%s:%s:%s', id, " \
            "COALESCE(state::text, '<SQL_NULL>'), state IS NULL, sibling), E'\\n' ORDER BY id) " \
            "FROM public.enum_grid"
        before = "\n".join((
            "1:ready:f:target",
            "2:NULL:f:literal NULL",
            "3:<SQL_NULL>:t:SQL NULL",
            "4::f:empty",
            "5:ready:f:sibling",
        ))
        after = before.replace("1:ready:f:target", "1:done:f:target").replace(
            "2:NULL:f:literal NULL", "2:done:f:literal NULL"
        )
        actual = psql(snapshot)
        assert actual == before, ("pending enum edit changed the native rows", actual, before)
        ui.press_x11_key("s", ("Control_L",))
        wait_for_oracle(psql, snapshot, after)
        assert ui.find_node(name="Approve once") is None, "a plain enum grid edit asked for approval"
        ui.wait_for_node(name="1 unsaved change", present=False)

    def mysql_grid_edit_and_delete_commit_to_the_server(database, base):
        grid_edit_and_delete_commit_to_the_server(ui.MYSQL_CONNECTION_NAME, "bookie_test.people", mysql)

    def mysql_enum_set_grid_edit_preserves_native_values_and_siblings(database, base):
        ui.open_saved_connection(ui.MYSQL_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.MYSQL_CONNECTION_NAME} — BookiE")
        ui.invoke_named_action_within("bookie_test.enum_grid", "Open enum_grid")
        ui.wait_for_node(name="ready", role=pyatspi.ROLE_LABEL)
        click_cell("ready", count=2)
        for key in "done":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        click_cell("read", count=2)
        for key in "read":
            ui.press_x11_key(key)
        ui.press_x11_key("comma")
        for key in "write":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="2 unsaved changes")

        query = (
            "SELECT CONCAT_WS(':', id, IFNULL(CAST(state + 0 AS CHAR), '<SQL_NULL>'), "
            "IFNULL(HEX(state), '<SQL_NULL>'), IF(state IS NULL, '1', '0'), "
            "IFNULL(CONCAT('[', state, ']'), '<SQL_NULL>'), "
            "IFNULL(CAST(permissions + 0 AS CHAR), '<SQL_NULL>'), "
            "IFNULL(HEX(permissions), '<SQL_NULL>'), IF(permissions IS NULL, '1', '0'), "
            "IFNULL(CONCAT('[', permissions, ']'), '<SQL_NULL>'), sibling) "
            "FROM enum_grid ORDER BY id"
        )
        before = "\n".join((
            "1:1:7265616479:0:[ready]:1:72656164:0:[read]:target",
            "2:3:4E554C4C:0:[NULL]:4:4E554C4C:0:[NULL]:literal NULL",
            "3:<SQL_NULL>:<SQL_NULL>:1:<SQL_NULL>:<SQL_NULL>:<SQL_NULL>:1:<SQL_NULL>:SQL NULL",
            "4:4::0:[]:0::0:[]:empty",
            "5:1:7265616479:0:[ready]:3:726561642C7772697465:0:[read,write]:sibling",
        ))
        after = before.replace("1:1:7265616479:0:[ready]:1:72656164:0:[read]:target",
                              "1:2:646F6E65:0:[done]:3:726561642C7772697465:0:[read,write]:target")
        actual = mysql(query)
        assert actual == before, ("pending enum/set edits changed native rows", actual, before)
        ui.press_x11_key("s", ("Control_L",))
        wait_for_oracle(mysql, query, after)
        assert ui.find_node(name="Approve once") is None, "a plain enum/set grid edit asked for approval"
        ui.wait_for_node(name="2 unsaved changes", present=False)

    result = [
        editing_a_saved_connection_prefills_it_and_saves_the_new_name,
        find_bar_replaces_every_match_in_the_editor,
        view_value_opens_the_whole_cell_with_pretty_json,
        columns_dialog_hides_a_column_and_keeps_the_last_one,
        ctrl_slash_toggles_a_comment_in_the_editor,
        browse_edit_cell_and_save_persists_to_the_database,
        test_connection_reports_success_in_the_dialog,
        test_connection_reports_failure_in_the_dialog,
        connect_dialog_cancel_stops_a_hanging_connection,
        a_second_launch_raises_the_window_and_exits_cleanly,
        session_transaction_label_and_toggle_off_confirmation,
        ctrl_tab_returns_to_the_most_recently_used_tab,
        holding_ctrl_while_pressing_tab_walks_deeper_into_the_history,
        interactive_controls_have_accessible_names,
        alt_arrows_jump_between_statements,
        row_inspector_lists_every_column_of_the_selected_row,
        find_in_loaded_rows_lists_matches_and_selects_one,
    ]
    if os.environ.get("TABLEPRO_PROFILE_ROWS"):
        result.append(profile_large_result_in_the_grid)
    if os.environ.get("TABLEPRO_GTK_MYSQL_CONTAINER"):
        result.append(mysql_grid_edit_and_delete_commit_to_the_server)
        result.append(mysql_enum_set_grid_edit_preserves_native_values_and_siblings)
    if os.environ.get("TABLEPRO_GTK_MONGODB_CONTAINER"):
        result.append(mongodb_grid_observes_cursor_values_until_refresh_and_edits_native_row)
    if os.environ.get("TABLEPRO_GTK_CLICKHOUSE_CONTAINER"):
        result.append(clickhouse_enum_grid_edit_preserves_native_label_and_siblings)
    if os.environ.get("TABLEPRO_GTK_POSTGRES_PORT"):
        result.append(postgres_session_transaction_confirmation_cancels_or_rolls_back)
        result.append(postgres_saved_connection_browses_rows_and_values)
        result.append(postgres_hidden_projection_refresh_and_edit_preserve_hidden_value)
        result.append(postgres_grid_edit_and_delete_commit_to_the_server)
        result.append(postgres_enum_grid_edit_preserves_native_label_and_siblings)
        result.append(postgres_database_switcher_reconnects_to_the_chosen_database)
    if os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_PORT"):
        result.append(postgres_saved_mtls_connection_authenticates_and_queries)
    if os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_PORT"):
        result.append(postgres_ssh_unknown_host_key_decline_is_durably_audited)
        result.append(postgres_ssh_unknown_host_key_accepts_and_queries)
        result.append(postgres_ssh_setup_failure_is_durably_audited)
        result.append(postgres_ssh_tunnel_loss_retires_session_and_reconnects)
        if os.environ.get("TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST"):
            result.append(postgres_ssh_multihop_trusts_both_hops_and_queries)
            result.append(postgres_ssh_second_hop_decline_does_not_learn_key)
            result.append(postgres_ssh_changed_second_hop_key_is_refused)
    for scenario in result:
        scenario.environment = "local"
    return result
