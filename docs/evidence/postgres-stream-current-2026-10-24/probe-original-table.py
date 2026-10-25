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


def resources(app):
    identity = app.identity()
    proc = Path("/proc") / str(identity["application_pid"])
    stat = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    memory = {}
    for line in (proc / "smaps_rollup").read_text().splitlines()[1:]:
        key, value = line.split(":", 1)
        if key in {"Rss", "Pss", "Private_Clean", "Private_Dirty", "Swap"}:
            memory[key] = int(value.split()[0])
    app.identity()
    return {"cpu_seconds": (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK"), "memory_kib": memory}


def scenarios(ui):
    def profile_postgres_large_stream(_database, _base):
        rows = int(os.environ.get("TABLEPRO_PROFILE_ROWS", "250000"))
        repetitions = int(os.environ.get("TABLEPRO_PROFILE_REPETITIONS", "3"))
        assert rows == 2000000 and 1 <= repetitions <= 20
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="people")
        app = ui.owned_application()
        records = []
        for cycle in range(repetitions):
            ui.invoke(ui.wait_for_node(name="Open SQL editor"))
            run = ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
            time.sleep(2)
            before = resources(app)
            started = time.monotonic()
            ui.run_sql("SELECT * FROM big")
            deadline = time.monotonic() + 5
            while run.getState().contains(pyatspi.STATE_SENSITIVE):
                assert time.monotonic() < deadline, "query never entered running state"
                time.sleep(0.02)
            samples = []
            deadline = time.monotonic() + 180
            while not run.getState().contains(pyatspi.STATE_SENSITIVE):
                assert time.monotonic() < deadline, "query did not reach a terminal state"
                samples.append({"seconds": time.monotonic() - started, **resources(app)})
                time.sleep(0.2)
            elapsed = time.monotonic() - started
            terminal_resources = resources(app)
            status = "timed_out" if ui.find_node(name="Query timed out") else "complete"
            assert status == "complete", "large PostgreSQL query did not complete"
            notice = ui.node_name(ui.wait_for_node_containing("Received ", timeout=30))
            if rows > 20000:
                assert "Retained rows" in notice
            if status == "complete":
                assert f"Received {rows} rows" in notice
                ui.wait_for_node_containing("done in", timeout=30)
                if os.environ.get("TABLEPRO_PROFILE_VERIFY_PAGER") == "1" and rows >= 20000 and rows % 5000 == 0:
                    ui.wait_for_node(name=str(rows - 4999), timeout=30)
                    for step in range(1, 4):
                        ui.invoke(ui.wait_for_node(name="Previous page", role=pyatspi.ROLE_PUSH_BUTTON))
                        start = rows - 4999 - step * 5000
                        ui.wait_for_node(name=f"Rows {start}-{start + 4999}", timeout=30)
                        ui.wait_for_node(name=str(start), timeout=30)
                    ui.wait_for_node(name=str(rows - 19999), timeout=30)
                    for step in range(1, 4):
                        ui.invoke(ui.wait_for_node(name="Next page", role=pyatspi.ROLE_PUSH_BUTTON))
                        start = rows - 19999 + step * 5000
                        ui.wait_for_node(name=f"Rows {start}-{start + 4999}", timeout=30)
                        ui.wait_for_node(name=str(start), timeout=30)
                    ui.wait_for_node(name=str(rows - 4999), timeout=30)
            time.sleep(3)
            complete = resources(app)
            ui.press_x11_key("w", ("Control_L",))
            ui.wait_for_node_containing("Received ", present=False, timeout=30)
            time.sleep(3)
            closed = resources(app)
            records.append({"cycle": cycle + 1, "terminal_seconds": elapsed, "cpu_seconds": terminal_resources["cpu_seconds"] - before["cpu_seconds"], "terminal_status": status, "retention_notice": notice, "before": before, "complete_settled": complete, "after_close_settled": closed, "samples": samples})
            Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps({"rows_requested": rows, "columns": 10, "cycles": records, **app.identity()}, indent=2) + "\n")
    return [profile_postgres_large_stream]


gtk_ux.scenarios = scenarios
gtk_safety.main()
