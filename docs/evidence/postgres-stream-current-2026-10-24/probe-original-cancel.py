import json
import os
from pathlib import Path
import subprocess
import sys
import time

repo = Path(os.environ["TABLEPRO_PROFILE_REPO"])
sys.path.insert(0, str(repo / "apps/linux/app/tests"))
import gtk_safety
import gtk_ux
import pyatspi


def scenarios(ui):
    def profile_stream_cancellation(_database, _base):
        ui.open_saved_connection(ui.POSTGRES_CONNECTION_NAME)
        ui.wait_for_frame_containing(f"{ui.POSTGRES_CONNECTION_NAME} — BookiE")
        ui.wait_for_node(name="people")
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        records = []
        for cycle in range(5):
            ui.run_sql("SELECT * FROM big")
            run = ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
            deadline = time.monotonic() + 5
            while run.getState().contains(pyatspi.STATE_SENSITIVE):
                assert time.monotonic() < deadline, "query never started"
                time.sleep(0.01)
            time.sleep(0.3)
            started = time.monotonic()
            ui.invoke(ui.wait_for_node(name="Cancel", role=pyatspi.ROLE_PUSH_BUTTON))
            deadline = time.monotonic() + 10
            while not run.getState().contains(pyatspi.STATE_SENSITIVE):
                assert time.monotonic() < deadline, "run control stayed disabled after cancellation"
                time.sleep(0.05)
            cancellation_seconds = time.monotonic() - started
            terminal = "cancelled" if ui.find_node(name="Query cancelled") else "failed"
            errors = [
                ui.node_name(node)
                for node in ui.descendants(ui.application_node())
                if ui.node_role(node) == pyatspi.ROLE_LABEL
                and "outcome could not be confirmed" in ui.node_name(node)
            ]
            if errors:
                terminal = "unknown"
            assert terminal in {"cancelled", "unknown"}, "cancel ended without an explicit interruption outcome"
            active = subprocess.check_output(
                [
                    "docker",
                    "exec",
                    os.environ["TABLEPRO_GTK_POSTGRES_CONTAINER"],
                    "psql",
                    "--username=postgres",
                    "--dbname=bookie_test",
                    "-Atc",
                    "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND datname = current_database() AND backend_type = 'client backend' AND (state = 'active' OR state LIKE 'idle in transaction%')",
                ],
                text=True,
                timeout=10,
            ).strip()
            assert active == "0", "a query or transaction remains active in the isolated database"
            ui.run_sql(f"SELECT {700 + cycle} AS after_cancel")
            ui.wait_for_node_containing("done in", timeout=30)
            ui.wait_for_node(name=str(700 + cycle), timeout=30)
            time.sleep(0.2)
            assert ui.find_node(name="Query cancelled") is None, "retired cancellation result replaced the new query"
            records.append(
                {
                    "cycle": cycle + 1,
                    "terminal": terminal,
                    "cancellation_seconds": cancellation_seconds,
                    "active_or_open_transaction_clients": int(active),
                    "next_query_value": 700 + cycle,
                    "memory_kib": ui.owned_application().memory_kb(),
                }
            )
            Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(records, indent=2) + "\n")
    return [profile_stream_cancellation]


gtk_ux.scenarios = scenarios
gtk_safety.main()
