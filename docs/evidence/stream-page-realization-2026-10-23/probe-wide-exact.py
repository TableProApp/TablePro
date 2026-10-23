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
        expected = 'é東京,"\n' * 1024
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
        result = {"rows": count, "retention_notice": notice, "preview_characters": len(preview), "preview_height_pixels": bounds.height, "clipboard": "not verified: menu activation unresolved for the oversized multiline row", "csv_bytes": export.stat().st_size, "csv_sha256": digest.hexdigest(), "memory_before_export_rss_hwm_kib": before_export, "memory_after_export_rss_hwm_kib": after_export, **app.identity()}
        Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(result, indent=2) + "\n")
    return [profile_wide_exact]


gtk_ux.scenarios = scenarios
gtk_safety.main()
