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


def profile_scenarios(ui):
    def profile_wide_grid_controller_allocations(_database, _base):
        app = ui.owned_application()
        before_rss, before_peak = app.memory_kb()
        columns = ", ".join(f"printf('value-%d', n) AS c{index:03}" for index in range(256))
        sql = ("WITH RECURSIVE rows(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM rows WHERE n < 100) "
               + "SELECT n AS row_id, " + columns + " FROM rows")
        started = time.monotonic()
        ui.run_sql(sql)
        ui.wait_for_node(name="value-1", role=pyatspi.ROLE_LABEL)
        first_value_seconds = time.monotonic() - started
        time.sleep(2)
        rss, peak = app.memory_kb()
        binary = app.executable
        result = {
            "variant": os.environ["TABLEPRO_MENU_VARIANT"],
            "rows": 100, "columns": 257,
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "before_rss_kib": before_rss, "before_peak_kib": before_peak,
            "loaded_rss_kib": rss, "peak_rss_kib": peak,
            "rss_growth_kib": rss - before_rss,
            "first_value_seconds": round(first_value_seconds, 3),
            "settle_seconds": 2,
            **app.identity(),
        }
        Path(os.environ["TABLEPRO_MENU_MEASUREMENT_OUT"]).write_text(json.dumps(result, indent=2) + "\n")
    return [profile_wide_grid_controller_allocations]


gtk_ux.scenarios = profile_scenarios
gtk_safety.main()
