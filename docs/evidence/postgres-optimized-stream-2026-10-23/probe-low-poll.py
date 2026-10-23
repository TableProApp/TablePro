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
        run_button = ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        before = app.memory_kb()
        started = time.monotonic()
        ui.run_sql(f"SELECT n AS row_id, 'person-' || n AS name, n * 1.5 AS amount, n % 2 AS active, timestamp '2026-01-01' + n * interval '1 second' AS created_at, 'a note of moderate length for row ' || n AS note FROM generate_series(1, {rows}) AS n")
        deadline = time.monotonic() + 5
        while run_button.getState().contains(pyatspi.STATE_SENSITIVE):
            assert time.monotonic() < deadline, "query never entered running state"
            time.sleep(0.02)
        samples = []
        deadline = time.monotonic() + 180
        while not run_button.getState().contains(pyatspi.STATE_SENSITIVE):
            assert time.monotonic() < deadline, "query did not reach a terminal state"
            samples.append({"seconds": round(time.monotonic() - started, 3), "memory_kib": app.memory_kb()})
            time.sleep(0.2)
        elapsed = time.monotonic() - started
        status = "timed_out" if ui.find_node(name="Query timed out") else "complete"
        progress = ui.wait_for_node_containing("Received ", timeout=30)
        retained_notice = ui.node_name(progress)
        assert "Retained rows" in retained_notice if rows > 20000 else True
        if status == "complete":
            assert f"Received {rows} rows" in retained_notice
            ui.wait_for_node_containing("done in", timeout=30)
        time.sleep(3)
        complete = app.memory_kb()
        ui.press_x11_key("w", ("Control_L",))
        ui.wait_for_node_containing("Received ", present=False, timeout=30)
        time.sleep(3)
        closed = app.memory_kb()
        record = {"rows_requested": rows, "columns": 6, "terminal_seconds": elapsed, "terminal_status": status, "retention_notice": retained_notice, "polling": "cached Run-button sensitive state every 200ms; no result-tree walk during query", "memory_kib": {"before": before, "complete_settled": complete, "after_close_settled": closed}, "samples": samples, **app.identity()}
        Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(record, indent=2) + "\n")
    return [profile_postgres_large_stream]


gtk_ux.scenarios = scenarios
gtk_safety.main()
