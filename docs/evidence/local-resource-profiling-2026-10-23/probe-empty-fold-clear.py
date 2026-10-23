import json
import time

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GtkSource", "5")
from gi.repository import Gtk, GtkSource

Gtk.init()
results = []
for size in (1024 * 1024, 8 * 1024 * 1024):
    buffer = GtkSource.Buffer()
    tag = Gtk.TextTag(name="sql-fold", invisible=True)
    buffer.get_tag_table().add(tag)
    line = "SELECT 1 AS value; -- profile\n"
    buffer.set_text(line * (size // len(line)))
    samples = []
    for _ in range(10):
        started = time.perf_counter()
        buffer.remove_tag(tag, buffer.get_start_iter(), buffer.get_end_iter())
        buffer.remove_source_marks(buffer.get_start_iter(), buffer.get_end_iter(), "sql-fold")
        samples.append(time.perf_counter() - started)
    results.append({"requested_bytes": size, "clear_seconds": samples})
print(json.dumps(results, indent=2))
