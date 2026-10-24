import json
import resource
import sys
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("GtkSource", "5")
from gi.repository import GLib, Gtk, GtkSource

size = int(sys.argv[1])
unit = sys.argv[2]
if size not in (65_536, 262_144, 1_048_576) or unit not in ("ascii", "emoji"):
    raise SystemExit("expected a calibrated byte size and ascii or emoji")
character = "x" if unit == "ascii" else "😀"
payload = character * ((size - 2) // len(character.encode("utf-8")))
text = "--" + payload
baseline = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
buffer = GtkSource.Buffer()
buffer.set_language(GtkSource.LanguageManager.get_default().get_language("sql"))
buffer.set_text(text)
view = GtkSource.View.new_with_buffer(buffer)
view.set_monospace(True)
scroll = Gtk.ScrolledWindow()
scroll.set_child(view)
window = Gtk.Window(default_width=1000, default_height=700, child=scroll)
window.present()
loop = GLib.MainLoop()
started = time.monotonic()
ticks = []

def heartbeat():
    ticks.append(time.monotonic() - started)
    return True

def finish():
    window.destroy()
    loop.quit()
    return False

GLib.timeout_add(100, heartbeat)
GLib.timeout_add_seconds(3, finish)
loop.run()
print(json.dumps({
    "bytes": len(text.encode("utf-8")),
    "character_kind": unit,
    "baseline_rss_kib": baseline,
    "peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    "heartbeat_count": len(ticks),
    "first_heartbeat_seconds": ticks[0] if ticks else None,
    "maximum_heartbeat_gap_seconds": max((b-a for a,b in zip(ticks,ticks[1:])), default=None),
}))
