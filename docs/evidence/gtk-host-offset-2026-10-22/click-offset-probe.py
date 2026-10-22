from pathlib import Path
import json
import select
import subprocess
import sys
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, Gtk


def application():
    app = Adw.Application(application_id="org.bookie.GeometryProbe", flags=Gio.ApplicationFlags.NON_UNIQUE)

    def activate(instance):
        window = Adw.ApplicationWindow(application=instance, title="Geometry probe")
        window.set_default_size(1200, 760)
        window.set_size_request(1000, 650)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        box.set_margin_start(64)
        box.set_margin_top(64)
        button = Gtk.Button(label="Geometry probe target")
        button.connect("clicked", lambda *_: print("clicked", flush=True))
        box.append(button)
        window.set_content(box)
        window.present()

    app.connect("activate", activate)
    app.run([])


def find_target(node):
    if node.name == "Geometry probe target":
        return node
    for child in node:
        found = find_target(child)
        if found is not None:
            return found
    return None


def probe():
    import pyatspi

    process = subprocess.Popen([sys.executable, __file__, "app"], stdout=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        target = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"the probe application exited with {process.returncode}")
            target = find_target(pyatspi.Registry.getDesktop(0))
            if target is not None and target.queryComponent().getExtents(pyatspi.WINDOW_COORDS).width > 0:
                break
            time.sleep(0.1)
        if target is None:
            raise RuntimeError("the target button did not become accessible")
        time.sleep(0.5)
        bounds = {}
        for name, mode in (("window", pyatspi.WINDOW_COORDS), ("desktop", pyatspi.DESKTOP_COORDS)):
            rect = target.queryComponent().getExtents(mode)
            bounds[name] = dict(x=rect.x, y=rect.y, width=rect.width, height=rect.height)
        sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "apps/linux/app/tests"))
        import gtk_ux
        rect = target.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
        clicks = {}
        for offset in (19, gtk_ux.ATSPI_WINDOW_Y_OFFSET):
            gtk_ux.ATSPI_WINDOW_Y_OFFSET = offset
            gtk_ux.x11_click(rect.x + rect.width // 2, rect.y + rect.height // 2, button=1)
            ready = select.select([process.stdout], [], [], 1)[0]
            clicks[str(offset)] = bool(ready and process.stdout.readline().strip() == "clicked")
        print(json.dumps({"clicks": clicks, "gtk": [Gtk.get_major_version(), Gtk.get_minor_version(), Gtk.get_micro_version()], "target": bounds}))
    finally:
        process.terminate()
        process.wait(timeout=5)


if __name__ == "__main__":
    application() if sys.argv[1:] == ["app"] else probe()
