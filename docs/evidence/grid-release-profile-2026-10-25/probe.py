import json
import os
import sqlite3
import sys
import time
from pathlib import Path

repo = Path(os.environ["TABLEPRO_PROFILE_REPO"])
sys.path.insert(0, str(repo / "apps/linux/app/tests"))
import gtk_safety
import gtk_ux
import pyatspi


def sample():
    app = gtk_safety.owned_application()
    identity = app.identity()
    proc = Path("/proc") / str(identity["application_pid"])
    stat = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    memory = {}
    for line in (proc / "smaps_rollup").read_text().splitlines()[1:]:
        key, value = line.split(":", 1)
        if key in {"Rss", "Pss", "Private_Dirty", "Swap"}:
            memory[key] = int(value.split()[0])
    return {
        "cpu_seconds": (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK"),
        "memory_kib": memory,
    }


def create_large_cell(database):
    payload_bytes = int(os.environ.get("TABLEPRO_PROFILE_CELL_BYTES", str(8 * 1024 * 1024)))
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE profile_large_cell (id INTEGER PRIMARY KEY, payload TEXT NOT NULL)")
        connection.execute(
            "INSERT INTO profile_large_cell(id, payload) VALUES (1, ?)", ("x" * payload_bytes,)
        )
    return {"profile_mode": "large_cell", "payload_bytes": payload_bytes}


def create_keyless_cell(database):
    payload_bytes = int(os.environ.get("TABLEPRO_PROFILE_CELL_BYTES", str(8 * 1024 * 1024)))
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE profile_keyless (payload TEXT NOT NULL)")
        connection.execute("INSERT INTO profile_keyless(payload) VALUES (?)", ("x" * payload_bytes,))
    return {"profile_mode": "keyless_cell", "payload_bytes": payload_bytes}


def create_wide_grid(database):
    columns = int(os.environ.get("TABLEPRO_PROFILE_COLUMNS", "257"))
    rows = int(os.environ.get("TABLEPRO_PROFILE_ROWS", "100"))
    if not 2 <= columns <= 512 or not 1 <= rows <= 500:
        raise ValueError("profile shape is outside the 2-512 column and 1-500 row bounds")
    names = [f"grid_c{index:03}" for index in range(columns - 1)]
    declaration = ", ".join(f'"{name}" TEXT NOT NULL' for name in names)
    placeholders = ", ".join("?" for _ in range(columns))
    with sqlite3.connect(database) as connection:
        connection.execute(f"CREATE TABLE profile_wide (id INTEGER PRIMARY KEY, {declaration})")
        values = [tuple([row, *(f"v{column}-{row}" for column in range(columns - 1))]) for row in range(rows)]
        connection.executemany(f"INSERT INTO profile_wide VALUES ({placeholders})", values)
    return {"profile_mode": "wide_grid", "columns": columns, "rows": rows}


def run_result(sql, expected_header, shape):
    ui = gtk_safety
    ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
    before = sample()
    started = time.monotonic()
    ui.run_sql(sql)
    ui.wait_for_node_containing("done in", timeout=120)
    ui.wait_for_node_containing(f"{expected_header}\nTEXT", role=pyatspi.ROLE_LABEL, timeout=60)
    elapsed = time.monotonic() - started
    after = sample()
    time.sleep(2)
    settled = sample()
    result = {
        **shape,
        "wall_seconds_to_header": round(elapsed, 4),
        "cpu_seconds_to_header": round(after["cpu_seconds"] - before["cpu_seconds"], 4),
        "rss_delta_kib_to_header": after["memory_kib"]["Rss"] - before["memory_kib"]["Rss"],
        "pss_delta_kib_to_header": after["memory_kib"]["Pss"] - before["memory_kib"]["Pss"],
        "settled": settled,
    }
    output = Path(os.environ["TABLEPRO_PROFILE_OUT"])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True), flush=True)


def scenarios(_ui):
    def profile_issue_1315_large_cell(database, _base):
        shape = create_large_cell(database)
        gtk_safety.open_saved_connection(gtk_safety.CONNECTION_NAME)
        run_result("SELECT id, payload FROM profile_large_cell", "payload", shape)

    def profile_issue_1315_keyless_cell(database, _base):
        shape = create_keyless_cell(database)
        gtk_safety.open_saved_connection(gtk_safety.CONNECTION_NAME)
        gtk_safety.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        gtk_safety.wait_for_node(name="profile_keyless")
        before = sample()
        started = time.monotonic()
        gtk_safety.invoke_named_action_within("profile_keyless", "Open profile_keyless")
        gtk_safety.wait_for_node_containing("payload\nTEXT", role=pyatspi.ROLE_LABEL, timeout=120)
        elapsed = time.monotonic() - started
        after = sample()
        time.sleep(2)
        settled = sample()
        preview = next(
            node for node in gtk_safety.descendants(gtk_safety.application_node())
            if gtk_safety.node_role(node) == pyatspi.ROLE_LABEL
            and gtk_safety.node_name(node).startswith("x" * 100)
            and "more chars" in gtk_safety.node_name(node)
        )
        display_characters = len(gtk_safety.node_name(preview))
        assert display_characters < 10_500, display_characters
        result = {
            **shape,
            "display_characters": display_characters,
            "wall_seconds_to_header": round(elapsed, 4),
            "cpu_seconds_to_header": round(after["cpu_seconds"] - before["cpu_seconds"], 4),
            "rss_delta_kib_to_header": after["memory_kib"]["Rss"] - before["memory_kib"]["Rss"],
            "pss_delta_kib_to_header": after["memory_kib"]["Pss"] - before["memory_kib"]["Pss"],
            "settled": settled,
        }
        output = Path(os.environ["TABLEPRO_PROFILE_OUT"])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, sort_keys=True), flush=True)

    def profile_issue_1315_wide_grid(database, _base):
        shape = create_wide_grid(database)
        gtk_safety.open_saved_connection(gtk_safety.CONNECTION_NAME)
        run_result("SELECT * FROM profile_wide", "grid_c255", shape)

    return [profile_issue_1315_large_cell, profile_issue_1315_keyless_cell, profile_issue_1315_wide_grid]


gtk_ux.scenarios = scenarios
if os.environ.get("TABLEPRO_PROFILE_HEAP_RAW"):
    original_start = gtk_safety.start_application

    def start_with_heaptrack(binary, environment, restored=False):
        environment = environment.copy()
        environment["LD_PRELOAD"] = "/usr/lib/heaptrack/libheaptrack_preload.so"
        environment["DUMP_HEAPTRACK_OUTPUT"] = os.environ["TABLEPRO_PROFILE_HEAP_RAW"]
        return original_start(binary, environment, restored)

    gtk_safety.start_application = start_with_heaptrack

gtk_safety.main()
