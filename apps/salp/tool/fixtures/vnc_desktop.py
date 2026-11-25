#!/usr/bin/env python3
"""Real GTK desktop for TigerVNC; records OS-delivered input, never a fake RFB peer."""
import json
from pathlib import Path
import sys
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib

folder = Path(sys.argv[1])
window = Gtk.Window(title='salp-vnc-fixture')
window.set_decorated(False)
window.set_default_size(640, 480)
window.move(0, 0)
fixed = Gtk.Fixed()
window.add(fixed)


def record(value):
    with (folder / 'events.jsonl').open('a') as log:
        log.write(json.dumps(value) + '\n')


for offset, color in [(0, '#ff0000'), (320, '#0000ff')]:
    panel = Gtk.EventBox()
    panel.set_size_request(320, 480)
    rgba = Gdk.RGBA()
    rgba.parse(color)
    panel.override_background_color(Gtk.StateFlags.NORMAL, rgba)
    panel.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK)
    panel.connect('button-press-event', lambda _, event: record({'button': event.button, 'x': event.x_root, 'y': event.y_root}) or False)
    fixed.put(panel, offset, 0)
window.add_events(Gdk.EventMask.KEY_PRESS_MASK | Gdk.EventMask.KEY_RELEASE_MASK)
window.connect('key-press-event', lambda _, event: record({'key': event.keyval}) or False)
window.connect('destroy', Gtk.main_quit)
window.show_all()
window.present()
GLib.timeout_add(400, lambda: (folder / 'ready').touch() or False)
Gtk.main()
