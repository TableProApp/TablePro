import csv
import hashlib
import json
import os
from pathlib import Path
import sys
import time

repo = Path(os.environ["TABLEPRO_PROFILE_REPO"])
sys.path.insert(0, str(repo / "apps/linux/app/tests"))
import gtk_safety
import gtk_ux
import pyatspi


def clipboard_text():
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, GLib, Gtk
    Gtk.init()
    loop = GLib.MainLoop()
    values = []
    def received(clipboard, result):
        values.append(clipboard.read_text_finish(result))
        loop.quit()
    Gdk.Display.get_default().get_clipboard().read_text_async(None, received)
    timer = GLib.timeout_add_seconds(10, lambda: (loop.quit(), False)[1])
    loop.run()
    if values:
        GLib.source_remove(timer)
    assert values, "clipboard read timed out"
    return values[0]


def scenarios(ui):
    def profile_wide_exact(_database, base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="people")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("""SELECT n AS row_id, repeat('é東京,"\n', 1024) || n AS payload FROM generate_series(1, 50000) AS n""")
        ui.wait_for_node_containing("done in", timeout=60)
        notice = ui.node_name(ui.wait_for_node_containing("Received "))
        assert "Received 50000 rows" in notice and "45001-50000" in notice
        ui.wait_for_node(name="45001")
        label = next(node for node in ui.descendants(ui.application_node()) if ui.node_role(node) == pyatspi.ROLE_LABEL and ui.node_name(node).startswith('é東京,"') and node.getState().contains(pyatspi.STATE_SHOWING))
        preview = ui.node_name(label)
        assert len(preview) < 1024, "oversized value was fully laid out"
        bounds = label.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        assert bounds.height < 100, "multiline cell is still excessively tall"
        expected = 'é東京,"\n' * 1024
        cell = label.parent
        assert ui.node_role(cell) == pyatspi.ROLE_TABLE_CELL
        checkpoint = {"preview_height_pixels": bounds.height, "preview_characters": len(preview), "cell_role": cell.getRoleName()}
        screen = label.queryComponent().getExtents(pyatspi.DESKTOP_COORDS)
        checkpoint["screen_bounds"] = [screen.x, screen.y, screen.width, screen.height]
        checkpoint["window_bounds"] = [bounds.x, bounds.y, bounds.width, bounds.height]
        Path(os.environ["TABLEPRO_PROFILE_OUT"] + ".partial").write_text(json.dumps(checkpoint, indent=2) + "\n")
        if os.environ.get("TABLEPRO_PROFILE_LAYOUT_ONLY") == "1":
            os.environ["TABLEPRO_GTK_ARTIFACT_DIR"] = str(Path(os.environ["TABLEPRO_PROFILE_OUT"]).parent)
            gtk_ux.capture_grid_navigation_artifact("layout-diagnostic")
            return
        ui.press_x11_key("Escape")
        gtk_ux.x11_click(bounds.x + min(bounds.width, 40) // 2, bounds.y + bounds.height // 2)
        time.sleep(0.4)
        os.environ["TABLEPRO_GTK_ARTIFACT_DIR"] = str(Path(os.environ["TABLEPRO_PROFILE_OUT"]).parent)
        gtk_ux.capture_grid_navigation_artifact("pointer-diagnostic")
        ui.invoke(ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_MENU_ITEM))
        copied = clipboard_text()
        assert copied == expected + "45001", "copy lost full Unicode or newline text"
        checkpoint["pointer_copy_passed"] = True
        Path(os.environ["TABLEPRO_PROFILE_OUT"] + ".partial").write_text(json.dumps(checkpoint, indent=2) + "\n")
        ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_MENU_ITEM, present=False)
        from gi.repository import Gdk
        Gdk.Display.get_default().get_clipboard().set("keyboard-copy-sentinel")
        gtk_ux.x11_click(bounds.x + min(bounds.width, 40) // 2, bounds.y + bounds.height // 2, button=1)
        ui.press_x11_key("F10", ("Shift_L",))
        ui.invoke(ui.wait_for_node(name="Copy value", role=pyatspi.ROLE_MENU_ITEM))
        assert clipboard_text() == copied, "keyboard copy did not preserve the full value"
        app = ui.owned_application()
        before_export = app.memory_kb()
        ui.invoke(ui.wait_for_node(name="Export all rows…", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.invoke(ui.wait_for_node(name="Export…", role=pyatspi.ROLE_PUSH_BUTTON))
        export = base / "home" / "wide-exact.csv"
        ui.wait_for_node(name="Export Results", role=ui.FILE_CHOOSER_ROLES)
        ui.set_visible_editable_within("Export Results", ui.FILE_CHOOSER_ROLES, str(export))
        ui.invoke(ui.wait_for_node(name="Save", role=pyatspi.ROLE_PUSH_BUTTON))
        deadline = time.monotonic() + 120
        while not export.exists():
            assert time.monotonic() < deadline, "export did not finish"
            time.sleep(0.1)
        after_export = app.memory_kb()
        with export.open(newline="", encoding="utf-8") as source:
            reader = csv.reader(source)
            assert next(reader) == ["row_id", "payload"]
            count = 0
            for count, row in enumerate(reader, 1):
                assert row == [str(count), expected + str(count)], f"CSV changed row {count}"
            assert count == 50000, "export lost rows outside the retained window"
        digest = hashlib.sha256()
        with export.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        result = {"rows": count, "retention_notice": notice, "preview_characters": len(preview), "preview_height_pixels": bounds.height, "clipboard_paths": ["pointer menu", "Shift+F10 menu"], "pointer_y_offset": gtk_ux.ATSPI_WINDOW_Y_OFFSET, "clipboard_bytes": len(copied.encode()), "clipboard_sha256": hashlib.sha256(copied.encode()).hexdigest(), "csv_bytes": export.stat().st_size, "csv_sha256": digest.hexdigest(), "memory_before_export_rss_hwm_kib": before_export, "memory_after_export_rss_hwm_kib": after_export, **app.identity()}
        Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(result, indent=2) + "\n")
    return [profile_wide_exact]


gtk_ux.scenarios = scenarios
gtk_safety.main()
