#!/usr/bin/env python3
"""Run salp against WsgiDAV on loopback in an ephemeral authenticated share.
Install tool/webdav-requirements.txt in SALP_TOOLCHAIN/webdav-verify first.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

app = Path(__file__).resolve().parents[1]
base = Path(os.environ.get('SALP_TOOLCHAIN', str(Path.home() / '.local/share/salp-flutter-spike')))
python = base / 'webdav-verify/bin/python'
with tempfile.TemporaryDirectory(prefix='salp-webdav-') as temporary:
    root = Path(temporary)
    (root/'share').mkdir()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    config = {
        'host': '127.0.0.1', 'port': port, 'server': 'cheroot',
        'provider_mapping': {'/': str(root/'share')},
        'http_authenticator': {'accept_basic': True, 'accept_digest': False, 'default_to_digest': False},
        'simple_dc': {'user_mapping': {'/': {'fixture': {'password': 'fixture-only-password'}}}},
        'verbose': 3,
    }
    (root/'config.json').write_text(json.dumps(config))
    with (root/'server.log').open('w+') as log:
        server = subprocess.Popen([str(python.parent/'wsgidav'), '--config', str(root/'config.json')], stdout=log, stderr=log)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.05)
            env = os.environ.copy()
            env.update(SALP_WEBDAV_FIXTURE=temporary, SALP_WEBDAV_PORT=str(port))
            result = subprocess.run(['python3', str(app/'tool/run.py'), 'flutter', 'test', '--no-pub', 'test/webdav_integration_test.dart'], env=env)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            log.flush()
            log.seek(0)
            (app.parents[1]/'docs/verification/flutter-spike/webdav-server.log').write_text(log.read())
    sys.exit(result.returncode)
