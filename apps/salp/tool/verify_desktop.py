#!/usr/bin/env python3
"""Run under dbus-run-session + xvfb-run; real isolated OS keyring and PTY."""
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

app = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='salp-desktop-') as temporary:
    env = os.environ.copy()
    for name, suffix in [('SALP_DATA_DIR','vault'), ('XDG_DATA_HOME','data'), ('XDG_CONFIG_HOME','config'), ('XDG_CACHE_HOME','cache')]:
        env[name] = str(Path(temporary) / suffix)
    env.update(GDK_BACKEND='x11', SALP_UI_EVIDENCE=str(app.parents[1] / 'docs/verification/flutter-spike'), SHELL='/bin/sh')
    result = subprocess.run(['gnome-keyring-daemon', '--unlock', '--components=secrets'],
                            input=secrets.token_urlsafe(32), text=True, capture_output=True, env=env, check=True)
    for line in result.stdout.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in ('GNOME_KEYRING_CONTROL','SSH_AUTH_SOCK'): env[key] = value
    subprocess.run(['python3', str(app/'tool/run.py'), 'flutter', 'test', '-d', 'linux',
                    '--no-pub', 'integration_test/desktop_flow_test.dart'], cwd=app, env=env, check=True)
