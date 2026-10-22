import json, sys, subprocess, time, os
from pathlib import Path
subprocess.run(["gdbus", "call", "--session", "--dest", "org.a11y.Bus", "--object-path", "/org/a11y/bus", "--method", "org.a11y.Bus.GetAddress"], check=True, stdout=subprocess.DEVNULL)
sys.path.insert(0, str(Path.cwd()/"apps/linux/app/tests"))
import gtk_safety as ui
samples=[]
original=ui.start_application
pid=None
app_process=None

def start(*args, **kwargs):
    global pid, app_process
    process=original(*args, **kwargs)
    pid=process.pid
    app_process=process
    return process

ui.start_application=start

def sample(phase):
    fields={}
    for line in Path(f"/proc/{pid}/status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:")):
            key,value,*_=line.split()
            fields[key.rstrip(":")]=int(value)
    stat=Path(f"/proc/{pid}/stat").read_text().rsplit(")",1)[1].split()
    fields["cpu_ticks"]=int(stat[11])+int(stat[12])
    samples.append({"cpu_ticks":fields["cpu_ticks"],"monotonic":time.monotonic(),"phase":phase, "rss_kib":fields["VmRSS"], "high_water_kib":fields["VmHWM"]})

def repeated_editor_close_cycles(database, base):
    sample("initial")
    for cycle in range(6):
        ui.run_sql(f"SELECT {cycle} AS cycle")
        ui.wait_for_node_containing("done in")
        ui.set_editor_text(("-- " + "x" * 100 + "\n") * 10000 + "SELECT 1;")
        for index in range(3):
            ui.invoke_accessible_action("win.open-editor")
            ui.wait_for_node(name="Run", role=ui.pyatspi.ROLE_PUSH_BUTTON)
            ui.run_sql(f"SELECT {cycle * 10 + index} AS another_tab")
            ui.wait_for_node_containing("done in")
            ui.set_editor_text(("-- " + "x" * 100 + "\n") * 10000 + "SELECT 1;")
        sample(f"cycle-{cycle}-four-tabs")
        for _ in range(4):
            ui.invoke_accessible_action("win.close-current")
            time.sleep(0.2)
        button=ui.wait_for_node(name="Open SQL editor",role=ui.pyatspi.ROLE_PUSH_BUTTON)
        time.sleep(1)
        sample(f"cycle-{cycle}-closed")
        bounds=button.queryComponent().getExtents(ui.pyatspi.WINDOW_COORDS)
        assert bounds.width>0 and bounds.height>0
        ui.gtk_ux.x11_click(bounds.x+bounds.width//2,bounds.y+bounds.height//2,button=1)
        ui.wait_for_node(name="Run",role=ui.pyatspi.ROLE_PUSH_BUTTON)
    ui.run_sql("SELECT 99 AS still_responsive")
    ui.wait_for_node_containing("done in")
    ui.set_editor_text(("-- " + "x" * 100 + "\n") * 10000 + "SELECT 1;")
    time.sleep(3)
    sample("final")
    ui.invoke_accessible_action("win.quit")
    assert app_process.wait(timeout=30) == 0

repeated_editor_close_cycles.environment="local"
try:
    ui.run_scenario(Path(sys.argv[1]),repeated_editor_close_cycles)
finally:
    (Path(os.environ["TABLEPRO_GTK_ARTIFACT_DIR"])/"samples.json").write_text(json.dumps(samples,indent=2)+"\n")
