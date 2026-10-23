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
    def profile_postgres_large_stream(_database, _base):
        rows = int(os.environ.get("TABLEPRO_PROFILE_ROWS", "2000000"))
        assert 1 <= rows <= 2000000
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="people")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        app = ui.owned_application()
        before = app.memory_kb()
        started = time.monotonic()
        ui.run_sql(f"SELECT n AS row_id, 'person-' || n AS name, n * 1.5 AS amount, n % 2 AS active, timestamp '2026-01-01' + n * interval '1 second' AS created_at, 'a note of moderate length for row ' || n AS note FROM generate_series(1, {rows}) AS n")
        first_cell = ui.wait_for_node_containing("person-", role=pyatspi.ROLE_LABEL, timeout=300)
        first_cell_text = ui.node_name(first_cell)
        first_seconds = time.monotonic() - started
        first = app.memory_kb()
        terminal = ui.wait_for_node_containing("done in", timeout=300)
        terminal_status = ui.node_name(terminal)
        elapsed = time.monotonic() - started
        progress = ui.wait_for_node_containing(f"Received {rows} rows", timeout=30)
        retained_notice = ui.node_name(progress)
        assert "Retained rows" in retained_notice if rows > 20000 else True
        time.sleep(3)
        complete = app.memory_kb()
        ui.press_x11_key("w", ("Control_L",))
        ui.wait_for_node_containing(f"Received {rows} rows", present=False, timeout=30)
        time.sleep(3)
        closed = app.memory_kb()
        record = {"rows_requested": rows, "columns": 6, "first_value_seconds": first_seconds, "terminal_seconds": elapsed, "terminal_status": terminal_status, "first_observed_cell": first_cell_text, "retention_notice": retained_notice, "memory_kib": {"before": before, "first_value": first, "complete_settled": complete, "after_close_settled": closed}, **app.identity()}
        Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(record, indent=2) + "\n")
    return [profile_postgres_large_stream]


gtk_ux.scenarios = scenarios
gtk_safety.main()
