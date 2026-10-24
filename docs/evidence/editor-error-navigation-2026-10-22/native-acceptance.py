import json
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / "apps/linux/app/tests"))
import gtk_safety as ui

base = Path(tempfile.mkdtemp(prefix="bookie-navigation-wayland-"))
artifacts = Path("/tmp/bookie-error-navigation-evidence") / os.environ.get("BOOKIE_NAV_CASE", "dark-wide")
artifacts.mkdir(parents=True, exist_ok=True)
original = json.loads(subprocess.check_output(["hyprctl", "activewindow", "-j"]))
width = int(os.environ.get("BOOKIE_NAV_WIDTH", "1200"))
process = None
keyring = None

def wait(predicate):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(ui.accessible_snapshot())

def showing_button(name):
    found = []
    for node in ui.descendants(ui.application_node()):
        if ui.node_name(node) == name and ui.node_role(node) == ui.pyatspi.ROLE_PUSH_BUTTON:
            if node.getState().contains(ui.pyatspi.STATE_SHOWING):
                found.append(node)
    assert found, (name, ui.accessible_snapshot())
    return found[0]

def click(name):
    time.sleep(.4)
    node = showing_button(name)
    box = node.queryComponent().getExtents(ui.pyatspi.WINDOW_COORDS)
    print("click", name, tuple(box), flush=True)
    subprocess.run(["/tmp/bookie-panel-pointer", str(80 + box.x + box.width // 2), str(100 + box.y + box.height // 2)], check=True)
    time.sleep(.3)

def screenshot(name):
    subprocess.run(["grim", "-g", f"80,100 {width}x760", str(artifacts / name)], check=True)

try:
    subprocess.run(["docker", "exec", "bookie-error-navigation-20261022", "psql", "-U", "postgres", "-d", "bookie_test", "-c", "TRUNCATE navigation_probe"], check=True, capture_output=True)
    _, environment = ui.write_fixture(base, environment="local")
    preferences = base / "config/tablepro/preferences.json"
    prefs = json.loads(preferences.read_text())
    prefs["color_scheme"] = os.environ.get("BOOKIE_NAV_THEME", "dark")
    prefs["editor_font_size"] = int(os.environ.get("BOOKIE_NAV_FONT", "12"))
    preferences.write_text(json.dumps(prefs))
    environment.update(GDK_BACKEND="wayland", GTK_A11Y="atspi", GIO_USE_VFS="local")
    keyring_environment = environment.copy()
    keyring_environment.pop("GNOME_KEYRING_CONTROL", None)
    control = base / "runtime/keyring"
    control.mkdir()
    keyring = subprocess.Popen(
        ["gnome-keyring-daemon", "--foreground", "--unlock", "--components=secrets", "--control-directory=" + str(control)],
        env=keyring_environment, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    keyring.stdin.write(b"tablepro-test")
    keyring.stdin.close()
    time.sleep(.3)
    binary = Path(os.environ.get("BOOKIE_APP_BINARY", "target/debug/tablepro-app"))
    binary_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
    process = ui.start_application(str(binary), environment)
    clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"]))
    own = next(client for client in clients if client["pid"] == process.pid)
    assert not own["xwayland"]
    address = "address:" + own["address"]
    for expression in [
        'hl.dsp.window.move({workspace="9",window="'+address+'",follow=false})',
        'hl.dsp.focus({workspace="9"})',
        'hl.dsp.focus({window="'+address+'"})',
        'hl.dsp.window.float({action="set",window="'+address+'"})',
        'hl.dsp.window.resize({x='+str(width)+',y=760,relative=false,window="'+address+'"})',
        'hl.dsp.window.move({x=80,y=100,relative=false,window="'+address+'"})',
    ]:
        subprocess.run(["hyprctl", "dispatch", expression], check=True, capture_output=True)
    ui.invoke_named_action_within(ui.POSTGRES_CONNECTION_NAME, "Open connection")
    ui.invoke(ui.wait_for_node(name="Open SQL editor"))
    ui.wait_for_node(name="Run", role=ui.pyatspi.ROLE_PUSH_BUTTON)
    script = "INSERT INTO navigation_probe VALUES (842);\nSELECT 'é' AS marker;\nSELECT bookie_missing_navigation_column;"
    editor = ui.set_editor_text(script)
    ui.invoke(ui.wait_for_node(name="Run", role=ui.pyatspi.ROLE_PUSH_BUTTON))
    ui.wait_for_node_containing("Statement 3 failed")
    ui.wait_for_node(name="Go to error", role=ui.pyatspi.ROLE_PUSH_BUTTON)
    screenshot("error.png")
    ui.invoke(showing_button("Maximize results"))
    ui.wait_for_node(name="Restore editor", role=ui.pyatspi.ROLE_PUSH_BUTTON)
    click("Go to error")
    expected = script.index("bookie_missing_navigation_column")
    wait(lambda: editor.queryText().caretOffset == expected)
    assert editor.getState().contains(ui.pyatspi.STATE_FOCUSED)
    ui.wait_for_node(name="Maximize results", role=ui.pyatspi.ROLE_PUSH_BUTTON)
    screenshot("navigated.png")
    repeated = "SELECT bookie_missing_navigation_column;\nSELECT bookie_missing_navigation_column;"
    editor = ui.set_editor_text(repeated)
    assert editor.queryText().setCaretOffset(len(repeated))
    wait(lambda: editor.queryText().caretOffset == len(repeated))
    subprocess.run(["wtype", "-M", "ctrl", "-M", "shift", "-k", "Return", "-m", "shift", "-m", "ctrl"], check=True)
    ui.wait_for_node_containing("Statement 1 failed")
    click("Go to error")
    expected = repeated.rindex("bookie_missing_navigation_column")
    print("repeated position", editor.queryText().caretOffset, expected, flush=True)
    screenshot("repeated.png")
    wait(lambda: editor.queryText().caretOffset == expected)
    ui.invoke(showing_button("Errors (1)"))
    editor.queryText().setCaretOffset(0)
    click("Go to error")
    wait(lambda: editor.queryText().caretOffset == expected)
    screenshot("errors-view.png")
    editor.queryEditableText().setTextContents(repeated + "\nSELECT 1;")
    editor.queryText().setCaretOffset(0)
    click("Go to error")
    ui.wait_for_node(name="The query or connection changed. Run it again to locate the error.")
    assert editor.queryText().caretOffset == 0
    screenshot("edited-buffer.png")
    commented = "-- SELECT bookie_missing_comment_column\nSELECT bookie_missing_comment_column;"
    editor = ui.set_editor_text(commented)
    ui.invoke(ui.wait_for_node(name="Run", role=ui.pyatspi.ROLE_PUSH_BUTTON))
    ui.wait_for_node_containing('column "bookie_missing_comment_column"')
    click("Go to error")
    wait(lambda: editor.queryText().caretOffset == commented.rindex("bookie_missing_comment_column"))
    screenshot("comment-origin.png")
    count = subprocess.check_output(["docker", "exec", "bookie-error-navigation-20261022", "psql", "-U", "postgres", "-d", "bookie_test", "-Atc", "SELECT count(*) FROM navigation_probe"]).decode().strip()
    assert count == "1", count
    (artifacts / "accessibility.txt").write_text(ui.accessible_snapshot())
    (artifacts / "result.json").write_text(json.dumps({"status":"passed", "binary_sha256":binary_sha256, "backend":"native Wayland", "xwayland":own["xwayland"], "width":width, "theme":prefs["color_scheme"], "sql_font":prefs["editor_font_size"], "checks":["Unicode third statement", "pointer navigation", "restore maximized editor", "repeated current statement via real shortcut", "Errors view navigation", "edited buffer refusal", "comment-safe statement origin", "no SQL rerun"]}, indent=2))
    print("native error navigation acceptance passed", flush=True)
finally:
    if process:
        (artifacts / "stderr.txt").write_text(ui.stop_application(process))
    if keyring:
        keyring.terminate()
        keyring.wait(timeout=5)
    if original.get("address"):
        subprocess.run(["hyprctl", "dispatch", 'hl.dsp.focus({window="address:'+original["address"]+'"})'], capture_output=True)
    shutil.rmtree(base, ignore_errors=True)
