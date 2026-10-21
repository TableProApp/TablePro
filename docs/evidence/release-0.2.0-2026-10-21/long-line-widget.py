import os, sys
from pathlib import Path
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("GtkSource", "5")
from gi.repository import Gtk, GtkSource, GLib
Path(os.environ["BOOKIE_PROBE_PIDFILE"]).write_text(str(os.getpid()))
mode=sys.argv[1]
text="--"+"x"*(8*1024*1024-2)
if mode.endswith("multiline"):
    text=("--"+"x"*77+"\n")*(len(text)//80)
buffer=GtkSource.Buffer() if mode.startswith("source") else Gtk.TextBuffer()
buffer.set_text(text)
view=GtkSource.View.new_with_buffer(buffer) if mode.startswith("source") else Gtk.TextView.new_with_buffer(buffer)
view.set_monospace(True)
scroll=Gtk.ScrolledWindow()
scroll.set_child(view)
window=Gtk.Window(default_width=1000,default_height=700,child=scroll)
window.present()
loop=GLib.MainLoop()
def finish():
    window.destroy()
    loop.quit()
    return False
GLib.timeout_add_seconds(7,finish)
loop.run()
