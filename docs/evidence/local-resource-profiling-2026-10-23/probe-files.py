import json
import os
from pathlib import Path
import sys
import time

repo = Path(os.environ["TABLEPRO_PROFILE_REPO"])
sys.path.insert(0, str(repo / "apps/linux/app/tests"))
import gtk_safety as ui
import gtk_ux
import pyatspi


def snapshot():
    app = ui.owned_application()
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


def profile_sql_files(_database, base, restart):
    records = []
    sizes = [int(os.environ["TABLEPRO_PROFILE_FILE_BYTES"])] if os.environ.get("TABLEPRO_PROFILE_FILE_BYTES") else [1024 * 1024, 8 * 1024 * 1024]
    assert all(1 <= size <= 8 * 1024 * 1024 for size in sizes)
    for size in sizes:
        line = "SELECT 1 AS value; -- profile\n"
        content = (line * (size // len(line)))
        sql_file = base / f"profile-{size}.sql"
        sql_file.write_text(content)

        def seed(environment):
            path = Path(environment["XDG_CONFIG_HOME"]) / ui.storage_dir_name() / "workspace_state.json"
            path.write_text(json.dumps({"connections": {"d4f5e246-c40a-4a30-90f2-39e93e94d920": {"tabs": [{"kind": "editor", "query": content, "draft_id": None, "file": str(sql_file)}], "active_idx": 0}}}))

        started = time.monotonic()
        restart(before_start=seed, restored=True)
        ui.wait_for_node_containing(sql_file.name, role=pyatspi.ROLE_PAGE_TAB, timeout=120)
        deadline = time.monotonic() + 120
        while True:
            candidates = [node for node in ui.descendants(ui.application_node()) if ui.node_role(node) == pyatspi.ROLE_TEXT]
            editor = max(candidates, key=lambda node: node.queryText().characterCount)
            if editor.queryText().characterCount == len(content):
                break
            assert time.monotonic() < deadline, "file text did not finish loading"
            time.sleep(0.2)
        loaded_seconds = time.monotonic() - started
        loaded = snapshot()
        print(f"loaded {len(content)} bytes in {loaded_seconds:.3f}s", flush=True)
        if os.environ.get("TABLEPRO_PROFILE_EARLY_CLOSE") == "1":
            ui.press_x11_key("w", ("Control_L",))
            ui.wait_for_node_containing(sql_file.name, role=pyatspi.ROLE_PAGE_TAB, present=False)
            time.sleep(10)
            closed = snapshot()
            assert sql_file.read_text() == content
            ui.invoke(ui.wait_for_node(name="Open SQL editor"))
            ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
            ui.run_sql("SELECT 1 AS responsive_after_close")
            ui.wait_for_node_containing("done in")
            records.append({"bytes": len(content), "startup_and_load_seconds": loaded_seconds, "loaded": loaded, "closed_after_ten_seconds": closed})
            Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(records, indent=2) + "\n")
            continue
        time.sleep(3)
        settled = snapshot()
        bounds = editor.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        gtk_ux.x11_click(bounds.x + 20, bounds.y + 20, button=1)
        ui.press_x11_key("End", ("Control_L",))
        edited_at = time.monotonic()
        ui.press_x11_key("space")
        deadline = time.monotonic() + 30
        while editor.queryText().characterCount != len(content) + 1:
            assert time.monotonic() < deadline, "editor did not accept a keystroke"
            time.sleep(0.05)
        edit_seconds = time.monotonic() - edited_at
        time.sleep(3)
        edited = snapshot()
        ui.press_x11_key("w", ("Control_L",))
        ui.invoke(ui.wait_for_node(name="Discard", role=pyatspi.ROLE_PUSH_BUTTON))
        ui.wait_for_node_containing(sql_file.name, role=pyatspi.ROLE_PAGE_TAB, present=False)
        time.sleep(3)
        closed = snapshot()
        assert sql_file.read_text() == content
        ui.invoke(ui.wait_for_node(name="Open SQL editor"))
        ui.wait_for_node(name="Run", role=pyatspi.ROLE_PUSH_BUTTON)
        ui.run_sql("SELECT 1 AS responsive_after_close")
        ui.wait_for_node_containing("done in")
        records.append({"bytes": len(content), "startup_and_load_seconds": loaded_seconds, "edit_ack_seconds": edit_seconds, "loaded": loaded, "settled": settled, "edited": edited, "closed": closed})
        Path(os.environ["TABLEPRO_PROFILE_OUT"]).write_text(json.dumps(records, indent=2) + "\n")


profile_sql_files.needs_restart = True
gtk_ux.scenarios = lambda _: [profile_sql_files]
if os.environ.get("TABLEPRO_PROFILE_HEAP_DIR"):
    original_start = ui.start_application
    original_wait_frame = ui.wait_for_frame_containing
    heap_index = 0

    def wait_instrumented_frame(text, present=True, timeout=120):
        return original_wait_frame(text, present=present, timeout=timeout)

    def start_with_heaptrack(binary, environment, restored=False):
        global heap_index
        environment = environment.copy()
        environment["LD_PRELOAD"] = "/usr/lib/heaptrack/libheaptrack_preload.so"
        environment["DUMP_HEAPTRACK_OUTPUT"] = str(Path(os.environ["TABLEPRO_PROFILE_HEAP_DIR"]) / f"files-{heap_index}.raw")
        heap_index += 1
        return original_start(binary, environment, restored)

    ui.start_application = start_with_heaptrack
    ui.wait_for_frame_containing = wait_instrumented_frame
ui.main()
