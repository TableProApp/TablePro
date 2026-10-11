#!/usr/bin/env bash
set -euo pipefail
if [[ "${CHECK_INNER:-0}" != "1" ]]; then
  exec env CHECK_INNER=1 dbus-run-session -- xvfb-run --auto-servernum --server-args="-screen 0 1280x1024x24 -nolisten tcp" "$0"
fi
export GDK_BACKEND=x11 GTK_A11Y=atspi
unset NO_AT_BRIDGE
dbus-update-activation-environment DISPLAY XAUTHORITY GDK_BACKEND GTK_A11Y
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >/dev/null
flatpak run com.tablepro.linux >/tmp/flatpak-app.log 2>&1 &
app=$!
trap 'kill $app 2>/dev/null || true' EXIT
python3 - <<'PY'
import gi, sys, time
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

def walk(node, depth=0):
    yield node
    for index in range(node.get_child_count()):
        try:
            child = node.get_child_at_index(index)
        except Exception:
            continue
        if child is not None:
            yield from walk(child, depth + 1)

deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    desktop = Atspi.get_desktop(0)
    for index in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(index)
        if app is None:
            continue
        for node in walk(app):
            if node.get_role_name() == "frame" and "BookiE" in (node.get_name() or ""):
                states = node.get_state_set()
                showing = states.contains(Atspi.StateType.SHOWING)
                names = sorted({n.get_name() for n in walk(node) if n.get_name()})[:12]
                print("frame:", node.get_name(), "showing:", showing, "children:", names)
                sys.exit(0 if showing else 2)
    time.sleep(2)
print("no BookiE frame appeared in the accessibility tree")
sys.exit(1)
PY
