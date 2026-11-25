#!/usr/bin/env python3
"""Emit a trusted ScreenSaver notification only on the isolated test D-Bus."""
import os
import sys
import gi

gi.require_version('Gio', '2.0')
from gi.repository import Gio, GLib

if not os.environ.get('SALP_UI_EVIDENCE') or not os.environ.get('SALP_DATA_DIR', '').startswith('/tmp/salp-desktop-'):
    raise SystemExit('Only use within tool/verify_desktop.py isolated session')
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
reply = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                      'RequestName', GLib.Variant('(su)', ('org.freedesktop.ScreenSaver', 4)),
                      None, Gio.DBusCallFlags.NONE, 5000, None)
if reply.unpack()[0] != 1:
    raise SystemExit('Test screensaver name already owned')
print('ready', flush=True)
for line in sys.stdin:
    command = line.strip()
    if command not in ('lock', 'unlock'):
        break
    bus.emit_signal(None, '/org/freedesktop/ScreenSaver', 'org.freedesktop.ScreenSaver',
                    'ActiveChanged', GLib.Variant('(b)', (command == 'lock',)))
    bus.flush_sync(None)
