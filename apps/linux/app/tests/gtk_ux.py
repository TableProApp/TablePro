import ctypes
import json
import os
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

import gtk_input
import keyboard_paths


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


ATSPI_WINDOW_Y_OFFSET = gtk_input.window_y_offset()


def capture_grid_navigation_artifact(name):
    folder = os.environ.get("TABLEPRO_GTK_ARTIFACT_DIR")
    scrot, imagemagick = shutil.which("scrot"), shutil.which("import")
    if folder is None or os.environ.get("GDK_BACKEND") != "x11" or not (scrot or imagemagick):
        return
    path = Path(folder) / f"{name}.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    command = [scrot, str(path)] if scrot else [imagemagick, "-window", "root", str(path)]
    subprocess.run(command, check=True, timeout=10)


def wait_for_focused_grid_row(ui, pyatspi, name):
    deadline = time.monotonic() + ui.WAIT_SECONDS
    while time.monotonic() < deadline:
        node = next((
            item for item in ui.descendants(ui.application_node())
            if ui.node_name(item) == name
            and ui.node_role(item) in (pyatspi.ROLE_TABLE_ROW, pyatspi.ROLE_TABLE_CELL)
            and item.getState().contains(pyatspi.STATE_FOCUSED)
            and item.getState().contains(pyatspi.STATE_SHOWING)
        ), None)
        if node is not None:
            bounds = node.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            frame = next(
                item for item in ui.descendants(ui.application_node())
                if ui.node_role(item) == pyatspi.ROLE_FRAME
            )
            window = frame.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            if 0 <= bounds.y < window.height and bounds.height > 0:
                capture_grid_navigation_artifact(name)
                return
        time.sleep(ui.POLL_SECONDS)
    focused = [
        (ui.node_name(item), item.getRoleName()) for item in ui.descendants(ui.application_node())
        if item.getState().contains(pyatspi.STATE_FOCUSED)
    ]
    raise AssertionError(f"keyboard navigation did not focus and reveal {name}; focused={focused}\n{ui.accessible_snapshot()}")


def x11_resize_window(width, height):
    x11 = ctypes.CDLL("libX11.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XQueryTree.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
    x11.XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint, ctypes.c_uint]
    x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    assert display, "X11 display is unavailable"
    try:
        root = x11.XDefaultRootWindow(display)
        root_return, parent, children, count = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.POINTER(ctypes.c_ulong)(), ctypes.c_uint()
        x11.XQueryTree(display, root, ctypes.byref(root_return), ctypes.byref(parent), ctypes.byref(children), ctypes.byref(count))
        window = None
        for index in range(count.value):
            attrs = XWindowAttributes()
            x11.XGetWindowAttributes(display, children[index], ctypes.byref(attrs))
            if attrs.map_state == 2 and not attrs.override_redirect and attrs.width >= 800 and attrs.height >= 600:
                window = children[index]
        if children:
            x11.XFree(children)
        assert window is not None, "the application window was not found on the X display"
        x11.XResizeWindow(display, window, width, height)
        x11.XSync(display, 0)
    finally:
        x11.XCloseDisplay(display)


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
            if attrs.map_state == 2 and not attrs.override_redirect and attrs.width >= 800 and attrs.height >= 600:
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

    def saved_connection_action(name, action):
        row = ui.wait_for_node(name=name, role=pyatspi.ROLE_LIST_ITEM)
        ui.invoke(ui.wait_within(row, name="Connection actions", role=pyatspi.ROLE_TOGGLE_BUTTON))
        ui.invoke(ui.wait_for_node(name=action))

    def wait_for_adw_dialog(name, present=True):
        roles = (pyatspi.ROLE_DIALOG, pyatspi.ROLE_LABEL)
        wait_until(
            lambda: any(ui.find_node(name=name, role=role) is not None for role in roles) == present,
            f"dialog {name!r} did not become {'visible' if present else 'hidden'}",
        )

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

    def set_spin(name, value):
        node = ui.wait_for_node(name=name, role=pyatspi.ROLE_SPIN_BUTTON)
        node.queryValue().currentValue = value

    def saved_connections(base):
        files = list((base / "config").glob("*/connections.json"))
        assert len(files) == 1, files
        return json.loads(files[0].read_text())["connections"]

    def grid_cell_label(cell_text):
        for node in ui.descendants(ui.application_node()):
            if ui.node_role(node) == pyatspi.ROLE_LABEL and ui.node_name(node) == cell_text:
                parent = node.parent
                if parent is not None and ui.node_role(parent) == pyatspi.ROLE_TABLE_CELL:
                    return node
        return None

    def open_cell_menu(cell_text):
        deadline = time.monotonic() + 3
        cell = grid_cell_label(cell_text)
        while cell is None and time.monotonic() < deadline:
            time.sleep(ui.POLL_SECONDS)
            cell = grid_cell_label(cell_text)
        cell = cell or ui.wait_for_node(name=cell_text, role=pyatspi.ROLE_LABEL)
        extents = cell.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + min(extents.width, 40) // 2, extents.y + extents.height // 2)
        time.sleep(0.4)

    def wait_for_result_column(name, present=True):
        ui.wait_for_node_containing(f"{name}\n", role=pyatspi.ROLE_LABEL, present=present)

    def toggle_table_column(cell_text, column_name):
        open_cell_menu(cell_text)
        choose_menu_item(9)
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

    def sqlite_grid_context_menu_columns_action_is_reachable_via_atspi(database, _base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.execute("INSERT INTO safety_items(id, note) VALUES (1, 'alpha')")
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        cell = ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        extents = cell.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + min(extents.width, 40) // 2, extents.y + extents.height // 2)
        menu = ui.wait_for_node(role=pyatspi.ROLE_MENU)
        items = [node for node in ui.descendants(menu) if ui.node_role(node) == pyatspi.ROLE_MENU_ITEM]
        assert len(items) >= 10, f"grid menu exposed only {len(items)} actionable items"
        actions = items[10].queryAction()
        click_action = next(
            index for index in range(actions.nActions) if actions.getName(index) == "click"
        )
        assert actions.doAction(click_action)
        wait_for_adw_dialog("Columns")
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("Columns", present=False)

    def grid_keyboard_menu_uses_the_current_focused_result_cell(_database, _base):
        ui.run_sql("SELECT 'keyboard-first' AS payload UNION ALL SELECT 'keyboard-second'")
        wait_for_result_column("payload")
        ui.press_x11_key("j", ("Control_L", "Shift_L"))
        search = ui.wait_for_node(name="Search columns")
        search.queryEditableText().setTextContents("payload")
        ui.press_x11_key("Return")
        ui.wait_for_node(name="Search columns", present=False)
        for expected, key, modifiers in (
            ("keyboard-first", "Menu", ()),
            ("keyboard-second", "F10", ("Shift_L",)),
        ):
            wait_for_focused_grid_row(ui, pyatspi, expected)
            ui.press_x11_key(key, modifiers)
            choose_menu_item(4)
            wait_for_adw_dialog("payload")
            deadline = time.monotonic() + ui.WAIT_SECONDS
            while time.monotonic() < deadline:
                if any(
                    ui.node_role(node) == pyatspi.ROLE_TEXT and expected in text_of(node)
                    for node in ui.descendants(ui.application_node())
                ):
                    break
                time.sleep(ui.POLL_SECONDS)
            else:
                raise AssertionError("the keyboard menu opened a different cell value")
            ui.press_x11_key("Escape")
            wait_for_adw_dialog("payload", present=False)
            if expected == "keyboard-first":
                ui.press_x11_key("Down")

    def grid_pointer_menu_uses_the_clicked_result_cell(_database, _base):
        ui.run_sql("SELECT 'pointer-first' AS payload UNION ALL SELECT 'pointer-second'")
        wait_for_result_column("payload")
        ui.press_x11_key("j", ("Control_L", "Shift_L"))
        search = ui.wait_for_node(name="Search columns")
        search.queryEditableText().setTextContents("payload")
        ui.press_x11_key("Return")
        ui.wait_for_node(name="Search columns", present=False)
        wait_for_focused_grid_row(ui, pyatspi, "pointer-first")
        open_cell_menu("pointer-second")
        choose_menu_item(4)
        wait_for_adw_dialog("payload")
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            if any(
                ui.node_role(node) == pyatspi.ROLE_TEXT and "pointer-second" in text_of(node)
                for node in ui.descendants(ui.application_node())
            ):
                break
            time.sleep(ui.POLL_SECONDS)
        else:
            raise AssertionError("the pointer menu opened a different cell value")
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("payload", present=False)

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

    def closing_and_reopening_a_browse_tab_keeps_it_editable(database, base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")])
        ui.open_table_in_new_tab("safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        ui.invoke_accessible_action("win.close-current")
        ui.wait_for_node(name="safety_items", role=pyatspi.ROLE_PAGE_TAB, present=False)
        ui.press_x11_key("t", ("Control_L", "Shift_L"))
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        click_cell("alpha", count=2)
        for key in "gamma":
            ui.press_x11_key(key)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")
        assert stored_notes(database) == [(1, "alpha"), (2, "beta")], "reopened browse edit reached the database before save"
        ui.press_x11_key("s", ("Control_L",))
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline and stored_notes(database) != [(1, "gamma"), (2, "beta")]:
            time.sleep(ui.POLL_SECONDS)
        assert stored_notes(database) == [(1, "gamma"), (2, "beta")], stored_notes(database)
        ui.wait_for_node(name="1 unsaved change", present=False)

    def postgres_reopened_browse_tab_keeps_its_schema_after_switching(database, base):
        try:
            psql(
                "DROP SCHEMA IF EXISTS bookie_reopen_a CASCADE; "
                "DROP SCHEMA IF EXISTS bookie_reopen_b CASCADE; "
                "CREATE SCHEMA bookie_reopen_a; CREATE SCHEMA bookie_reopen_b; "
                "CREATE TABLE bookie_reopen_a.reopen_items (id integer PRIMARY KEY, note text); "
                "CREATE TABLE bookie_reopen_b.reopen_items (id integer PRIMARY KEY, note text); "
                "INSERT INTO bookie_reopen_a.reopen_items VALUES (1, 'schema_a'); "
                "INSERT INTO bookie_reopen_b.reopen_items VALUES (1, 'schema_b')"
            )
            ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
            ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
            ui.open_table_in_new_tab("bookie_reopen_a.reopen_items")
            ui.wait_for_node(name="schema_a", role=pyatspi.ROLE_LABEL)
            ui.invoke_accessible_action("win.close-current")
            ui.wait_for_node(name="bookie_reopen_a.reopen_items", role=pyatspi.ROLE_PAGE_TAB, present=False)
            ui.open_table_in_new_tab("bookie_reopen_b.reopen_items")
            ui.wait_for_node(name="schema_b", role=pyatspi.ROLE_LABEL)
            ui.press_x11_key("t", ("Control_L", "Shift_L"))
            ui.wait_for_node(name="schema_a", role=pyatspi.ROLE_LABEL)
            click_cell("schema_a", count=2)
            for key in "updateda":
                ui.press_x11_key(key)
            ui.press_x11_key("Return")
            ui.wait_for_node(name="1 unsaved change")
            ui.press_x11_key("s", ("Control_L",))
            wait_for_psql("SELECT note FROM bookie_reopen_a.reopen_items WHERE id=1", "updateda")
            assert psql("SELECT note FROM bookie_reopen_b.reopen_items WHERE id=1") == "schema_b"
            ui.wait_for_node(name="1 unsaved change", present=False)
        finally:
            psql("DROP SCHEMA IF EXISTS bookie_reopen_a CASCADE; DROP SCHEMA IF EXISTS bookie_reopen_b CASCADE")

    def postgres_structure_tabs_keep_backend_count_bounded(_database, _base):
        tables = [f"public.structure_activity_{index:02}" for index in range(20)]
        psql("DROP TABLE IF EXISTS " + ", ".join(tables))
        psql("; ".join(
            f"CREATE TABLE {table} (id integer PRIMARY KEY, marker_{index:02} text)"
            for index, table in enumerate(tables)
        ))
        try:
            ui.open_saved_connection(ui.POSTGRES_MTLS_CONNECTION_NAME)
            ui.wait_for_node(name="public.release_items", role=pyatspi.ROLE_LIST_ITEM)
            initial = None
            for index, table in enumerate(tables):
                row = ui.wait_for_node(name=table, role=pyatspi.ROLE_LIST_ITEM)
                actions = row.queryAction()
                edit = next(
                    (position for position in range(actions.nActions)
                     if actions.getName(position) == "sidebar-row.edit-structure"),
                    None,
                )
                assert edit is not None, f"{table} has no Edit Structure action"
                assert actions.doAction(edit), f"{table} did not open in a Structure tab"
                ui.wait_for_node_containing(table.rsplit(".", 1)[-1], role=pyatspi.ROLE_PAGE_TAB)
                ui.wait_for_node(name=f"marker_{index:02}")
                if index == 0:
                    initial = int(psql(
                        "SELECT count(*) FROM pg_stat_activity "
                        "WHERE application_name = 'BookiE' AND datname = current_database()"
                    ))
                    assert initial > 0, "the saved connection has no PostgreSQL backend"

            final = int(psql(
                "SELECT count(*) FROM pg_stat_activity "
                "WHERE application_name = 'BookiE' AND datname = current_database()"
            ))
            assert final == initial, ("Structure tabs increased PostgreSQL backend count", initial, final)
        finally:
            psql("DROP TABLE IF EXISTS " + ", ".join(tables))

    def grid_paste_preserves_multiline_text_and_sibling_rows(database, base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany(
                "INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta"), (3, "sibling")]
            )
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        click_cell("alpha")
        clipboard_text = '"line1\nline2"\n"line3\r\nline4"'
        clipboard_code = """import sys, gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
from gi.repository import Gdk, GLib, Gtk
Gtk.init()
Gdk.Display.get_default().get_clipboard().set(sys.argv[1])
GLib.idle_add(lambda: print('ready', flush=True))
GLib.MainLoop().run()
"""
        clipboard_owner = subprocess.Popen(
            [sys.executable, "-c", clipboard_code, clipboard_text],
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            ready, _, _ = select.select([clipboard_owner.stdout], [], [], ui.WAIT_SECONDS)
            announced = clipboard_owner.stdout.readline().strip() if ready else b""
            if announced != b"ready":
                clipboard_owner.terminate()
                detail = clipboard_owner.stderr.read().decode(errors="replace")
                raise AssertionError(f"the clipboard owner never took the clipboard: {announced!r} {detail}")
            assert clipboard_owner.poll() is None, clipboard_owner.stderr.read().decode()
            ui.press_x11_key("v", ("Control_L",))
            ui.wait_for_node(name="2 unsaved changes")
            assert stored_notes(database) == [(1, "alpha"), (2, "beta"), (3, "sibling")]
            ui.press_x11_key("s", ("Control_L",))
            expected = [(1, "line1\nline2"), (2, "line3\r\nline4"), (3, "sibling")]
            deadline = time.monotonic() + ui.WAIT_SECONDS
            while time.monotonic() < deadline and stored_notes(database) != expected:
                time.sleep(ui.POLL_SECONDS)
            assert stored_notes(database) == expected, stored_notes(database)
            ui.wait_for_node(name="2 unsaved changes", present=False)
        finally:
            clipboard_owner.terminate()
            clipboard_owner.wait(timeout=ui.WAIT_SECONDS)

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

    def postgres_session_commit_distinguishes_aborted_rollback_from_recovered_commit(database, base):
        def run_session_sql(sql):
            ui.set_editor_text(sql)
            ui.invoke(ui.wait_for_sensitive_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON))

        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        psql("DROP TABLE IF EXISTS public.session_commit_probe; CREATE TABLE public.session_commit_probe (id integer PRIMARY KEY)")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        for row_id, recover, status, count in [
            (1, False, "Session rolled back", "0"),
            (2, True, "Session committed", "1"),
        ]:
            ui.invoke(ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON))
            run_session_sql(
                f"BEGIN; INSERT INTO public.session_commit_probe VALUES ({row_id}); "
                "SAVEPOINT recovery; SELECT 1 / 0;"
            )
            ui.invoke(ui.wait_for_node(name="Approve once", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name="Approve once", present=False)
            ui.wait_for_node_containing("division by zero")
            if recover:
                run_session_sql("ROLLBACK TO recovery")
                ui.wait_for_node_containing("done in")
            ui.invoke(ui.wait_for_node(name="Session · transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON))
            ui.wait_for_node(name="End the session with an open transaction?")
            ui.invoke(ui.wait_for_node(name="Commit", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name=status)
            ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON)
            stored = psql("SELECT COUNT(*) FROM public.session_commit_probe")
            assert stored == count, (recover, stored, count)

    def check_saved_connection_removal(database, base, welcome):
        before = saved_connections(base)
        target = next(record for record in before if record["name"] == ui.CONNECTION_B_NAME)
        database_file = Path(target["database"])
        database_before = database_file.read_bytes()
        if welcome:
            ui.invoke_accessible_action("win.disconnect")
        heading = f"Delete {ui.CONNECTION_B_NAME}?"
        for cancel in (True, False):
            if ui.find_node(name=ui.CONNECTION_B_NAME, role=pyatspi.ROLE_LIST_ITEM) is None:
                ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
            ui.wait_for_node(name=ui.CONNECTION_B_NAME, role=pyatspi.ROLE_LIST_ITEM)
            saved_connection_action(ui.CONNECTION_B_NAME, "Remove connection")
            ui.wait_for_node(name=heading)
            ui.invoke(ui.wait_for_node(name="Cancel" if cancel else "Delete", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name=heading, present=False)
            if cancel:
                assert saved_connections(base) == before
                continue
            expected = [record for record in before if record["id"] != target["id"]]
            deadline = time.monotonic() + ui.WAIT_SECONDS
            while saved_connections(base) != expected and time.monotonic() < deadline:
                time.sleep(ui.POLL_SECONDS)
            assert saved_connections(base) == expected
        assert database_file.read_bytes() == database_before

    def workspace_connection_removal_confirms_once_and_preserves_the_database(database, base):
        check_saved_connection_removal(database, base, False)

    def welcome_connection_removal_confirms_once_and_preserves_the_database(database, base):
        check_saved_connection_removal(database, base, True)

    def editing_a_saved_connection_prefills_it_and_saves_the_new_name(database, base):
        before = saved_connections(base)
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        saved_connection_action(ui.CONNECTION_B_NAME, "Edit connection")
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

    def saved_connection_row_controls_have_keyboard_focus_order(_database, _base):
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        row = ui.wait_for_node(name=ui.CONNECTION_B_NAME, role=pyatspi.ROLE_LIST_ITEM)
        favorite = ui.wait_within(row, name="Add to favourites", role=pyatspi.ROLE_PUSH_BUTTON)
        actions = ui.wait_within(row, name="Connection actions", role=pyatspi.ROLE_TOGGLE_BUTTON)
        open_connection = ui.wait_within(row, name="Open connection", role=pyatspi.ROLE_PUSH_BUTTON)
        for control in (favorite, actions, open_connection):
            assert any(control.queryAction().getName(index) == "click" for index in range(control.queryAction().nActions)), (
                f"{ui.node_name(control)!r} has no accessible click action"
            )
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while not favorite.getState().contains(pyatspi.STATE_FOCUSED) and time.monotonic() < deadline:
            ui.press_x11_key("Tab")
            time.sleep(ui.POLL_SECONDS)
        assert favorite.getState().contains(pyatspi.STATE_FOCUSED), (
            f"favourite action is not keyboard reachable:\n{ui.accessible_snapshot()}"
        )
        ui.press_x11_key("Tab")
        time.sleep(ui.POLL_SECONDS)
        assert actions.getState().contains(pyatspi.STATE_FOCUSED), (
            f"Tab did not move focus from favourite to actions:\n{ui.accessible_snapshot()}"
        )
        ui.press_x11_key("Tab")
        time.sleep(ui.POLL_SECONDS)
        assert open_connection.getState().contains(pyatspi.STATE_FOCUSED), (
            f"Tab did not move focus from actions to open:\n{ui.accessible_snapshot()}"
        )
        ui.press_x11_key("Return")
        ui.wait_for_frame_containing(f"{ui.CONNECTION_B_NAME} — BookiE")

    def open_edit_dialog_for(name):
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        saved_connection_action(name, "Edit connection")
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

    def connection_dialog_environment_choice_is_operable(database, base):
        ui.invoke(ui.wait_for_node(name="New connection", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Connect to PostgreSQL")
        environment = ui.wait_for_node(name="Environment", role=pyatspi.ROLE_TOGGLE_BUTTON)
        actions = environment.queryAction()
        names = [actions.getName(index).lower() for index in range(actions.nActions)]
        assert any(name in {"click", "activate", "press", "toggle", "default.activate"} for name in names), (
            f"Environment has no accessible activation action: {names!r}"
        )

    def connect_dialog_cancel_stops_a_hanging_connection(database, base):
        import socket
        import threading

        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(4)
            held = []
            threading.Thread(target=lambda: [held.append(server.accept()) for _ in range(4)], daemon=True).start()
            ui.invoke(ui.wait_for_node(name="New connection", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node(name="Connect to PostgreSQL")
            set_entry("Host", "127.0.0.1")
            set_spin("Port", server.getsockname()[1])
            ui.invoke(ui.wait_for_node(name="Connect", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.invoke(ui.wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
            ui.wait_for_node_containing("Connection cancelled")
            ui.wait_for_node(name="Connect", role=pyatspi.ROLE_PUSH_BUTTON)
            assert ui.find_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON) is None

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
        return ui.owned_application().memory_kb()

    def a_second_launch_raises_the_window_and_exits_cleanly(database, base):
        result = ui.owned_application().launch_again()
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
                **ui.owned_application().identity(),
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
            **ui.owned_application().identity(),
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
        choose_menu_item(4)
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

    def explain_plan_window_closes_on_escape(_database, _base):
        ui.run_sql("SELECT 1 AS value")
        ui.invoke(ui.wait_for_node(name="Explain", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_frame_containing("Explain plan")
        ui.press_x11_key("Escape")
        ui.wait_for_frame_containing("Explain plan", present=False)

    def columns_dialog_hides_a_column_and_keeps_the_last_one(database, base):
        ui.run_sql("SELECT 1 AS alpha, 2 AS beta")
        wait_for_result_column("beta")
        open_cell_menu("1")
        choose_menu_item(7)
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

    def switching_connection_asks_before_rolling_back_an_open_session_transaction(database, base):
        ui.invoke(ui.wait_for_node(name="Session", role=pyatspi.ROLE_TOGGLE_BUTTON))
        time.sleep(0.5)
        ui.run_sql("BEGIN")
        ui.wait_for_node(name="Session \u00b7 transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON)

        ui.open_saved_connection(ui.CONNECTION_B_NAME)
        ui.wait_for_node(name="Switch with an open session transaction?")
        time.sleep(0.5)
        ui.press_x11_key("Escape")
        ui.wait_for_node(name="Switch with an open session transaction?", present=False)
        ui.wait_for_frame_containing(f"{ui.CONNECTION_NAME} \u2014 BookiE")
        ui.wait_for_node(name="Session \u00b7 transaction open", role=pyatspi.ROLE_TOGGLE_BUTTON)

        ui.open_saved_connection(ui.CONNECTION_B_NAME)
        ui.wait_for_node(name="Switch with an open session transaction?")
        ui.invoke(ui.wait_for_node(name="Roll Back and Switch", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_frame_containing(f"{ui.CONNECTION_B_NAME} \u2014 BookiE")

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

    def wide_result_jumps_by_keyboard_and_keeps_headers_over_their_cells(database, base):
        ui.run_sql("SELECT " + ", ".join(f"{1000 + index} AS c{index}" for index in range(1, 301)))
        wait_for_result_column("c1")

        def showing(node):
            return node is not None and node.getState().contains(pyatspi.STATE_SHOWING)

        def left_edge(node):
            return node.queryComponent().getExtents(pyatspi.WINDOW_COORDS).x

        for index in (150, 300, 1):
            ui.press_x11_key("j", ("Control_L", "Shift_L"))
            search = ui.wait_for_node(name="Search columns")
            search.queryEditableText().setTextContents(f"c{index}")
            time.sleep(0.3)
            ui.press_x11_key("Return")
            ui.wait_for_node(name="Search columns", present=False)
            frame = next(
                node for node in ui.descendants(ui.application_node()) if ui.node_role(node) == pyatspi.ROLE_FRAME
            )
            window_width = frame.queryComponent().getExtents(pyatspi.WINDOW_COORDS).width

            def aligned_in_view():
                header = ui.find_node_containing(f"c{index}\n", role=pyatspi.ROLE_LABEL)
                cell = ui.find_node(name=str(1000 + index), role=pyatspi.ROLE_LABEL)
                target = ui.find_node(name=str(1000 + index), role=pyatspi.ROLE_TABLE_CELL)
                if not (showing(header) and showing(cell) and showing(target)):
                    return None
                if not target.getState().contains(pyatspi.STATE_FOCUSED):
                    return None
                header_x, cell_x = left_edge(header), left_edge(cell)
                in_view = 0 <= header_x < window_width and 0 <= cell_x < window_width
                return (header_x, cell_x) if in_view and abs(header_x - cell_x) <= 12 else None

            deadline = time.monotonic() + ui.WAIT_SECONDS
            while aligned_in_view() is None:
                assert time.monotonic() < deadline, f"c{index} did not scroll into view over its header"
                time.sleep(ui.POLL_SECONDS)
            capture_grid_navigation_artifact(f"wide-result-column-{index}")
            if index == 150:
                ui.press_x11_key("j", ("Control_L", "Shift_L"))
                ui.wait_for_node(name="Search columns")
                ui.press_x11_key("Escape")
                ui.wait_for_node(name="Search columns", present=False)
                deadline = time.monotonic() + ui.WAIT_SECONDS
                while aligned_in_view() is None:
                    assert time.monotonic() < deadline, "closing column search did not restore c150 focus and alignment"
                    time.sleep(ui.POLL_SECONDS)

    def grid_search_dialogs_return_keyboard_navigation_to_large_results(database, base):
        ui.run_sql(
            "WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM rows WHERE n < 5000) "
            "SELECT printf('keyboard-row-%04d', n) AS keyboard_row FROM rows"
        )
        wait_for_result_column("keyboard_row")
        ui.press_x11_key("j", ("Control_L", "Shift_L"))
        search = ui.wait_for_node(name="Search columns")
        search.queryEditableText().setTextContents("keyboard_row")
        ui.press_x11_key("Return")
        ui.wait_for_node(name="Search columns", present=False)

        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-0001")
        for key, expected in (("End", "keyboard-row-5000"), ("Home", "keyboard-row-0001")):
            ui.press_x11_key(key, ("Control_L",))
            wait_for_focused_grid_row(ui, pyatspi, expected)
        ui.press_x11_key("j", ("Control_L", "Shift_L"))
        ui.wait_for_node(name="Search columns")
        ui.press_x11_key("Escape")
        ui.wait_for_node(name="Search columns", present=False)
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-0001")
        ui.press_x11_key("End", ("Control_L",))
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-5000")
        ui.press_x11_key("f", ("Control_L", "Alt_L"))
        search = ui.wait_for_node(name="Search the loaded rows")
        search.queryEditableText().setTextContents("keyboard-row-2500")
        ui.wait_for_node(name="2500 · keyboard_row: keyboard-row-2500")
        ui.press_x11_key("Return")
        ui.wait_for_node(name="Search the loaded rows", present=False)
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-2500")
        ui.press_x11_key("Home", ("Control_L",))
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-0001")
        ui.press_x11_key("f", ("Control_L", "Alt_L"))
        ui.wait_for_node(name="Search the loaded rows")
        ui.press_x11_key("Escape")
        ui.wait_for_node(name="Search the loaded rows", present=False)
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-0001")
        ui.press_x11_key("End", ("Control_L",))
        wait_for_focused_grid_row(ui, pyatspi, "keyboard-row-5000")

    def narrow_window_keeps_main_and_editor_toolbar_actions_reachable(database, base):
        ui.open_saved_connection(ui.CONNECTION_NAME)
        window = ui.wait_for_frame_containing(" — BookiE")
        ui.wait_for_node(name="Split", role=pyatspi.ROLE_TOGGLE_BUTTON)
        for width in (928, 847, 802):
            x11_resize_window(width, 760)
            time.sleep(0.5)
            bounds = window.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            assert bounds.width == width, f"window did not resize to {width} px: {bounds.width} px"
            editor_panel = ui.wait_for_node(name="Query 1", role=pyatspi.ROLE_PANEL)
            panel_bounds = editor_panel.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            assert panel_bounds.width >= width - 140, (
                f"editor content did not reclaim the collapsed sidebar width at {width} px: "
                f"content width={panel_bounds.width}\n{ui.accessible_snapshot()}"
            )
            for name, role in (
                ("Main menu", pyatspi.ROLE_TOGGLE_BUTTON),
                ("Split", pyatspi.ROLE_TOGGLE_BUTTON),
                ("Close", pyatspi.ROLE_PUSH_BUTTON),
            ):
                control = ui.wait_for_node(name=name, role=role)
                extents = control.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
                assert extents.width > 0 and extents.x >= 0 and extents.x + extents.width <= bounds.width, (
                    f"{name} is outside the {width} px window: "
                    f"x={extents.x}, width={extents.width}\n{ui.accessible_snapshot()}"
                )
    def tables_sidebar_button_hides_the_docked_sidebar_and_opens_the_overlay(database, base):
        ui.open_saved_connection(ui.CONNECTION_NAME)
        window = ui.wait_for_frame_containing(" — BookiE")

        def wait_for_sidebar(shown):
            deadline = time.monotonic() + ui.WAIT_SECONDS
            while True:
                search = ui.find_node(name="Search tables", role=pyatspi.ROLE_TOGGLE_BUTTON)
                if (search is not None and search.getState().contains(pyatspi.STATE_SHOWING)) == shown:
                    return
                assert time.monotonic() < deadline, (
                    f"the tables sidebar did not {'appear' if shown else 'hide'}:\n{ui.accessible_snapshot()}"
                )
                time.sleep(ui.POLL_SECONDS)

        for width in (1200, 900):
            x11_resize_window(width, 760)
            time.sleep(0.5)
            bounds = window.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            assert bounds.width == width, f"window did not resize to {width} px: {bounds.width} px"
            toggle = ui.wait_for_node(name="Tables sidebar", role=pyatspi.ROLE_TOGGLE_BUTTON)
            extents = toggle.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
            assert toggle.getState().contains(pyatspi.STATE_SHOWING) and extents.width > 0, (
                f"the Tables sidebar button is not shown at {width} px:\n{ui.accessible_snapshot()}"
            )
            assert extents.x >= 0 and extents.x + extents.width <= bounds.width, (
                f"the Tables sidebar button is outside the {width} px window: x={extents.x}, width={extents.width}"
            )
            # Wide windows dock the sidebar open; narrow ones collapse it into a closed overlay.
            docked = width == 1200
            wait_for_sidebar(docked)
            ui.invoke(toggle)
            wait_for_sidebar(not docked)
            ui.invoke(toggle)
            wait_for_sidebar(docked)

    def connection_colour_chooser_has_an_accessible_button(database, base):
        ui.invoke_accessible_action("win.disconnect")
        ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON)
        ui.invoke(ui.wait_for_node(name="Open saved connection", role=pyatspi.ROLE_TOGGLE_BUTTON))
        saved_connection_action(ui.CONNECTION_NAME, "Group and tags")
        chooser = ui.wait_for_node(name="No colour", role=pyatspi.ROLE_PUSH_BUTTON)
        actions = chooser.queryAction()
        assert any(actions.getName(index) == "click" for index in range(actions.nActions)), (
            f"colour chooser has no accessible click action:\n{ui.accessible_snapshot()}"
        )
        ui.invoke(chooser)
        option = ui.wait_for_node(name="Blue", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.invoke(option)
        ui.wait_for_node(name="No colour", role=pyatspi.ROLE_PUSH_BUTTON, present=False)
        ui.wait_for_node(name="Blue", role=pyatspi.ROLE_PUSH_BUTTON)

    def sql_editor_clickables_all_have_a_keyboard_path(database, base):
        ui.run_sql("SELECT 1 AS alpha")
        wait_for_result_column("alpha")
        clickable = (
            pyatspi.ROLE_PUSH_BUTTON,
            pyatspi.ROLE_TOGGLE_BUTTON,
            pyatspi.ROLE_CHECK_BOX,
            pyatspi.ROLE_COMBO_BOX,
            pyatspi.ROLE_LINK,
        )
        names = [
            ui.node_name(node).strip()
            for node in ui.descendants(ui.application_node())
            if ui.node_role(node) in clickable and node.getState().contains(pyatspi.STATE_SHOWING)
        ]
        missing = keyboard_paths.unregistered(names, keyboard_paths.SQL_EDITOR)
        assert not missing, "clickable without a registered keyboard path:\n" + "\n".join(missing)
        line = ui.wait_for_node(name="SELECT 1 AS alpha", role=pyatspi.ROLE_LABEL)
        extents = line.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + extents.width // 2, extents.y + extents.height // 2, button=1)
        def main_menu_showing():
            menu = ui.find_node(name="Main menu", role=pyatspi.ROLE_MENU)
            return menu is not None and menu.getState().contains(pyatspi.STATE_SHOWING)

        assert not main_menu_showing(), "the main menu was already open"
        ui.press_x11_key("F10")
        deadline = time.monotonic() + 5
        while not main_menu_showing():
            assert time.monotonic() < deadline, f"F10 did not open the main menu:\n{ui.accessible_snapshot()}"
            time.sleep(0.1)
        ui.press_x11_key("Escape")

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

    def query_history_opens_as_a_docked_panel_and_closes_without_leaving_the_workspace(database, base):
        ui.open_saved_connection(ui.CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.CONNECTION_NAME} — BookiE")
        ui.invoke_accessible_action("win.show-history")
        ui.wait_for_node(name="Close history", role=pyatspi.ROLE_PUSH_BUTTON)
        assert ui.find_node(name="Query History", role=pyatspi.ROLE_DIALOG) is None
        ui.invoke(ui.wait_for_node(name="Close history", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node(name="Close history", present=False)
        ui.wait_for_frame_containing(f"{ui.CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)

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
        choose_menu_item(4)
        wait_for_adw_dialog("name")
        ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.press_x11_key("Escape")
        wait_for_adw_dialog("name", present=False)

    def postgres_large_stream_pages_show_retained_range_and_navigate(database, base):
        container = os.environ["TABLEPRO_GTK_POSTGRES_CONTAINER"]
        subprocess.run(
            [
                "docker", "exec", container, "psql", "--username=postgres", "--dbname=bookie_test",
                "--set=ON_ERROR_STOP=1", "--command",
                "CREATE TABLE pager_rows AS SELECT value AS id, repeat('x', 4500) AS payload "
                "FROM generate_series(1, 15000) AS value",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("SELECT id, payload FROM pager_rows ORDER BY id")
        ui.wait_for_node_containing("Retained rows 5001-15000", timeout=120)
        ui.wait_for_node_containing("Rows 10001-15000", timeout=120)
        ui.wait_for_node(name="10001")
        scheme = os.environ.get("ADW_DEBUG_COLOR_SCHEME", "prefer-light")
        capture_grid_navigation_artifact(f"postgres-stream-{scheme}-retained-last-page")
        ui.invoke(ui.wait_for_node(name="Previous page", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing("Rows 5001-10000", timeout=10)
        ui.wait_for_node(name="5001")
        capture_grid_navigation_artifact(f"postgres-stream-{scheme}-retained-previous-page")
        ui.invoke(ui.wait_for_node(name="Next page", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing("Rows 10001-15000", timeout=10)
        ui.wait_for_node(name="10001")

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
        ui.set_editor_text("BEGIN")
        ui.invoke(ui.wait_for_sensitive_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing("done in")
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
        def reconnect_banner_visible():
            node = ui.find_node_containing("Connection lost — reconnecting")
            if node is None:
                return False
            showing = node.getState().contains(pyatspi.STATE_SHOWING)
            return showing and node.queryComponent().getExtents(pyatspi.DESKTOP_COORDS).height > 0

        def wait_for_stable_connection():
            deadline = time.monotonic() + 90
            quiet_since = None
            while time.monotonic() < deadline:
                if reconnect_banner_visible():
                    quiet_since = None
                elif quiet_since is None:
                    quiet_since = time.monotonic()
                elif time.monotonic() - quiet_since >= 5:
                    return
                time.sleep(0.5)
            raise AssertionError("the connection did not stay reconnected for 5 seconds")

        wait_for_stable_connection()

        # The old dedicated session must be retired even though the saved
        # connection has already reconnected. A write through that stale
        # session must not reach PostgreSQL.
        refusal_prefix = "Could not read the session's string settings:"
        assert ui.find_node_containing(refusal_prefix) is None
        ui.run_sql("INSERT INTO session_tunnel_loss_probe VALUES (2)")
        refusal = ui.wait_for_node_containing(refusal_prefix, role=pyatspi.ROLE_LABEL)
        assert "session was retired" in refusal.name, refusal.name
        assert psql("SELECT count(*) FROM public.session_tunnel_loss_probe") == "0"

        def toggle_is_on(toggle):
            state = toggle.getState()
            return state.contains(pyatspi.STATE_PRESSED) or state.contains(pyatspi.STATE_CHECKED)

        def session_node():
            return ui.wait_for_node_containing("Session", role=pyatspi.ROLE_TOGGLE_BUTTON)

        def session_toggle(on, sensitive=False):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                toggle = session_node()
                ready = toggle.getState().contains(pyatspi.STATE_SENSITIVE) or not sensitive
                if toggle_is_on(toggle) == on and ready:
                    return toggle
                time.sleep(0.2)
            raise AssertionError(f"Session toggle did not become {'on' if on else 'off'}")

        def end_session():
            toggle = session_toggle(True, sensitive=True)
            had_transaction = "transaction open" in toggle.name
            ui.invoke(toggle)
            if had_transaction:
                ui.invoke(ui.wait_for_node(name="Roll Back", role=pyatspi.ROLE_PUSH_BUTTON))
            session_toggle(False, sensitive=True)

        def reopen_session():
            if toggle_is_on(session_node()):
                end_session()
            wait_for_stable_connection()
            ui.invoke(session_toggle(False, sensitive=True))
            session_toggle(True)

        for _ in range(3):
            reopen_session()
            ui.run_sql("SELECT 42")
            try:
                ui.wait_for_node(name="42", role=pyatspi.ROLE_LABEL, timeout=10)
                break
            except AssertionError:
                continue
        else:
            raise AssertionError(
                f"no fresh editor session could run SELECT 42 after the tunnel loss:\n{ui.accessible_snapshot()}"
            )
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
        choose_menu_item(15)
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
        time.sleep(1.0)
        ui.press_x11_key("Down")
        time.sleep(0.3)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="1 unsaved change")

        click_cell("NULL", count=2)
        time.sleep(1.0)
        ui.press_x11_key("Up")
        time.sleep(0.3)
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
        time.sleep(1.0)
        ui.press_x11_key("Down")
        time.sleep(0.3)
        ui.press_x11_key("Return")
        ui.wait_for_node(name="done", role=pyatspi.ROLE_LABEL)
        click_cell("read", count=2)
        apply = ui.wait_for_node(name="Apply", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.press_x11_key("Down")
        time.sleep(0.3)
        ui.press_x11_key("Return")
        time.sleep(0.3)
        ui.invoke(apply)
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

    def page_tab_names():
        return [
            ui.node_name(node) for node in ui.descendants(ui.application_node())
            if ui.node_role(node) == pyatspi.ROLE_PAGE_TAB
        ]

    def wait_until(predicate, describe):
        deadline = time.monotonic() + ui.WAIT_SECONDS
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(ui.POLL_SECONDS)
        raise AssertionError(f"{describe}:\n{ui.accessible_snapshot()}")

    def own_clipboard(text):
        clipboard_code = """import sys, gi
gi.require_version('Gtk', '4.0')
gi.require_version('Gdk', '4.0')
from gi.repository import Gdk, GLib, Gtk
Gtk.init()
Gdk.Display.get_default().get_clipboard().set(sys.argv[1])
GLib.MainLoop().run()
"""
        owner = subprocess.Popen(
            [sys.executable, "-c", clipboard_code, text],
            env=os.environ.copy(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.3)
        assert owner.poll() is None, owner.stderr.read().decode()
        return owner

    def reopen_cell_menu(cell_text):
        # A click that lands while the previous popover is still closing is swallowed on slower stacks.
        for _ in range(3):
            open_cell_menu(cell_text)
            if ui.find_node(role=pyatspi.ROLE_MENU) is not None:
                return
            time.sleep(0.5)

    def invoke_menu_item(position):
        menu = ui.wait_for_node(role=pyatspi.ROLE_MENU)
        items = [node for node in ui.descendants(menu) if ui.node_role(node) == pyatspi.ROLE_MENU_ITEM]
        actions = items[position].queryAction()
        click = next(index for index in range(actions.nActions) if actions.getName(index) == "click")
        assert actions.doAction(click)

    def pinned_results_stay_ahead_of_the_next_run(_database, _base):
        ui.run_sql("SELECT 1 AS one;\nSELECT 2 AS two;")
        wait_until(lambda: sum("SELECT (1)" in name for name in page_tab_names()) == 2, "two results did not appear")
        ui.invoke(ui.wait_for_node(name="Pin results", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.run_sql("SELECT 3 AS three;")
        pinned = lambda: [name for name in page_tab_names() if "\U0001F4CC" in name]
        wait_until(lambda: len(pinned()) == 2 and len(page_tab_names()) >= 4, "pinned results did not stay")
        ui.run_sql("SELECT 4 AS four;\nSELECT * FROM missing_table;")
        ui.wait_for_node(name="Statement 2 failed")
        ui.wait_for_node(name="Statement 4 failed", present=False)
        unpin = ui.wait_for_node_containing("Unpin results", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.invoke(unpin)
        wait_until(lambda: not pinned(), "unpinning did not drop the pinned results")

    def local_filter_narrows_a_pinned_result_and_a_second_result_set(_database, _base):
        ui.run_sql(
            "SELECT 'apple' AS fruit UNION ALL SELECT 'pear' UNION ALL SELECT 'apple';\n"
            "SELECT 'red' AS colour UNION ALL SELECT 'blue';"
        )
        wait_until(lambda: len(page_tab_names()) >= 2, "two result sets did not appear")
        ui.invoke(ui.wait_for_node(name="Pin results", role=pyatspi.ROLE_PUSH_BUTTON))
        filter_by_this_value = 3
        open_cell_menu("pear")
        invoke_menu_item(filter_by_this_value)
        ui.wait_for_node_containing("Showing 1 of 3 loaded rows", role=pyatspi.ROLE_LABEL)
        ui.wait_for_node(name="apple", role=pyatspi.ROLE_LABEL, present=False)
        export_visible, export_all_loaded = 6, 7
        for item, rows in ((export_visible, "1 loaded rows"), (export_all_loaded, "3 loaded rows")):
            reopen_cell_menu("pear")
            invoke_menu_item(item)
            ui.wait_for_node(name=rows, role=pyatspi.ROLE_LABEL)
            ui.press_x11_key("Escape")
            ui.wait_for_node(name=rows, role=pyatspi.ROLE_LABEL, present=False)
        second = next(
            node for node in ui.descendants(ui.application_node())
            if ui.node_role(node) == pyatspi.ROLE_PAGE_TAB and ui.node_name(node).startswith("2 · ")
        )
        ui.invoke(second)
        reopen_cell_menu("blue")
        invoke_menu_item(filter_by_this_value)
        ui.wait_for_node_containing("Showing 1 of 2 loaded rows", role=pyatspi.ROLE_LABEL)

    def filter_by_this_value_narrows_the_browse_rows(database, _base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany(
                "INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta"), (3, "alpha")]
            )
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL)
        open_cell_menu("beta")
        invoke_menu_item(5)
        ui.wait_for_node(name="alpha", role=pyatspi.ROLE_LABEL, present=False)
        ui.wait_for_node(name="beta", role=pyatspi.ROLE_LABEL)

    def selection_statistics_summarise_the_selected_rows(database, _base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany(
                "INSERT INTO safety_items(id, note) VALUES (?, ?)", [(2, "alpha"), (4, "beta"), (9, "gamma")]
            )
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        click_cell("alpha")
        ui.press_x11_key("Down", ("Shift_L",), presses=2)
        badge = ui.wait_for_node_containing("3 selected", role=pyatspi.ROLE_PUSH_BUTTON)
        summary = badge.description
        for fact in ("count 3", "min 2", "max 9", "sum 15", "average 5"):
            assert fact in summary, (fact, summary)

    def paste_past_the_loaded_rows_changes_nothing(database, _base):
        import sqlite3
        with sqlite3.connect(database) as connection:
            connection.executemany("INSERT INTO safety_items(id, note) VALUES (?, ?)", [(1, "alpha"), (2, "beta")])
        ui.invoke_named_action_within("safety_items", "Open safety_items")
        click_cell("beta")
        owner = own_clipboard("one\ntwo")
        try:
            ui.press_x11_key("v", ("Control_L",))
            time.sleep(ui.SETTLE_SECONDS / 3)
            assert ui.find_node_containing("unsaved change") is None, "a paste past the last row was applied"
            assert stored_notes(database) == [(1, "alpha"), (2, "beta")]
        finally:
            owner.terminate()
            owner.wait(timeout=ui.WAIT_SECONDS)

    def window_controls_follow_the_desktop_button_layout(_database, _base, restart):
        def use_layout(layout):
            def write(environment):
                settings = Path(environment["XDG_CONFIG_HOME"]) / "gtk-4.0" / "settings.ini"
                settings.parent.mkdir(parents=True, exist_ok=True)
                settings.write_text(f"[Settings]\ngtk-decoration-layout={layout}\n", encoding="utf-8")
            return write

        restart(use_layout("appmenu:close"))
        ui.wait_for_node(name="Close", role=pyatspi.ROLE_PUSH_BUTTON)
        assert ui.find_node(name="Minimize", role=pyatspi.ROLE_PUSH_BUTTON) is None, "a close-only layout showed Minimize"
        restart(use_layout("icon:minimize,maximize,close"))
        ui.wait_for_node(name="Minimize", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.wait_for_node(name="Maximize", role=pyatspi.ROLE_PUSH_BUTTON)

    window_controls_follow_the_desktop_button_layout.needs_restart = True
    window_controls_follow_the_desktop_button_layout.requires_editor = False

    def restart_with_an_untouched_editor_restores_without_layout_criticals(_database, _base, restart):
        restart()

    restart_with_an_untouched_editor_restores_without_layout_criticals.needs_restart = True

    def disconnected_editor_remains_usable_without_cached_table_names(_database, _base):
        ui.invoke_accessible_action("win.disconnect")
        ui.wait_for_node(name="Open connection")
        ui.invoke_accessible_action("win.open-editor")
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        editor = ui.set_editor_text("SELECT * FROM ")
        extents = editor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        x11_click(extents.x + 120, extents.y + 12, button=1)
        ui.press_x11_key("End", ("Control_L",))
        ui.press_x11_key("space", ("Control_L",))
        time.sleep(0.3)
        assert ui.find_node(name="safety_items", role=pyatspi.ROLE_LABEL) is None, (
            "a disconnected editor offered a cached table"
        )

    result = [
        sqlite_grid_context_menu_columns_action_is_reachable_via_atspi,
        grid_keyboard_menu_uses_the_current_focused_result_cell,
        grid_pointer_menu_uses_the_clicked_result_cell,
        editing_a_saved_connection_prefills_it_and_saves_the_new_name,
        workspace_connection_removal_confirms_once_and_preserves_the_database,
        welcome_connection_removal_confirms_once_and_preserves_the_database,
        find_bar_replaces_every_match_in_the_editor,
        view_value_opens_the_whole_cell_with_pretty_json,
        explain_plan_window_closes_on_escape,
        columns_dialog_hides_a_column_and_keeps_the_last_one,
        ctrl_slash_toggles_a_comment_in_the_editor,
        browse_edit_cell_and_save_persists_to_the_database,
        closing_and_reopening_a_browse_tab_keeps_it_editable,
        grid_paste_preserves_multiline_text_and_sibling_rows,
        test_connection_reports_success_in_the_dialog,
        test_connection_reports_failure_in_the_dialog,
        connection_dialog_environment_choice_is_operable,
        connect_dialog_cancel_stops_a_hanging_connection,
        a_second_launch_raises_the_window_and_exits_cleanly,
        session_transaction_label_and_toggle_off_confirmation,
        switching_connection_asks_before_rolling_back_an_open_session_transaction,
        ctrl_tab_returns_to_the_most_recently_used_tab,
        holding_ctrl_while_pressing_tab_walks_deeper_into_the_history,
        interactive_controls_have_accessible_names,
        wide_result_jumps_by_keyboard_and_keeps_headers_over_their_cells,
        grid_search_dialogs_return_keyboard_navigation_to_large_results,
        narrow_window_keeps_main_and_editor_toolbar_actions_reachable,
        tables_sidebar_button_hides_the_docked_sidebar_and_opens_the_overlay,
        connection_colour_chooser_has_an_accessible_button,
        saved_connection_row_controls_have_keyboard_focus_order,
        sql_editor_clickables_all_have_a_keyboard_path,
        alt_arrows_jump_between_statements,
        row_inspector_lists_every_column_of_the_selected_row,
        query_history_opens_as_a_docked_panel_and_closes_without_leaving_the_workspace,
        find_in_loaded_rows_lists_matches_and_selects_one,
        pinned_results_stay_ahead_of_the_next_run,
        local_filter_narrows_a_pinned_result_and_a_second_result_set,
        filter_by_this_value_narrows_the_browse_rows,
        selection_statistics_summarise_the_selected_rows,
        paste_past_the_loaded_rows_changes_nothing,
        window_controls_follow_the_desktop_button_layout,
        restart_with_an_untouched_editor_restores_without_layout_criticals,
        disconnected_editor_remains_usable_without_cached_table_names,
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
        result.append(postgres_session_commit_distinguishes_aborted_rollback_from_recovered_commit)
        result.append(postgres_saved_connection_browses_rows_and_values)
        result.append(postgres_hidden_projection_refresh_and_edit_preserve_hidden_value)
        result.append(postgres_reopened_browse_tab_keeps_its_schema_after_switching)
        result.append(postgres_grid_edit_and_delete_commit_to_the_server)
        result.append(postgres_large_stream_pages_show_retained_range_and_navigate)
        result.append(postgres_enum_grid_edit_preserves_native_label_and_siblings)
        result.append(postgres_database_switcher_reconnects_to_the_chosen_database)
    if os.environ.get("TABLEPRO_GTK_POSTGRES_MTLS_PORT"):
        result.append(postgres_saved_mtls_connection_authenticates_and_queries)
        result.append(postgres_structure_tabs_keep_backend_count_bounded)
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
