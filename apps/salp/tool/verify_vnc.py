#!/usr/bin/env python3
"""Real TigerVNC+GTK and OpenSSH on loopback; ephemeral credentials/config only."""
import datetime
import getpass
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time

app = Path(__file__).resolve().parents[1]
base = Path(os.environ.get('SALP_TOOLCHAIN', str(Path.home() / '.local/share/salp-flutter-spike')))
binaries = base / 'vnc-verify/usr/bin'
evidence = app.parents[1] / 'docs/verification/flutter-spike'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='salp-vnc-') as temporary:
    folder = Path(temporary)
    processes = []
    logs = []
    try:
        display = next(f':{n}' for n in range(180, 280) if not Path(f'/tmp/.X11-unix/X{n}').exists() and not Path(f'/tmp/.X{n}-lock').exists())
        auth = folder / 'xauthority'
        auth.touch(mode=0o600)
        subprocess.run(['xauth', '-f', str(auth), 'add', display, 'MIT-MAGIC-COOKIE-1', secrets.token_hex(16)], check=True)
        password = folder / 'password'
        password.write_bytes(subprocess.check_output([str(binaries/'vncpasswd'), '-f'], input=b'fixture8\n'))
        password.chmod(0o600)
        vnc_port, ssh_port = free_port(), free_port()
        env = os.environ.copy()
        env.update(DISPLAY=display, XAUTHORITY=str(auth), GDK_BACKEND='x11')
        log = (folder/'vnc-server.log').open('w+')
        logs.append(log)
        server = subprocess.Popen([str(binaries/'Xvnc'), display, '-geometry', '640x480', '-depth', '24', '-auth', str(auth), '-nolisten', 'tcp', '-interface', '127.0.0.1', '-rfbport', str(vnc_port), '-SecurityTypes', 'VncAuth', '-PasswordFile', str(password), '-AlwaysShared'], stdout=log, stderr=log, env=env)
        processes.append(server)
        deadline = time.monotonic()+10
        while not Path(f'/tmp/.X11-unix/X{display[1:]}').exists():
            if server.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('TigerVNC failed to start')
            time.sleep(.05)
        gtk_log = (folder/'gtk.log').open('w+')
        logs.append(gtk_log)
        desktop = subprocess.Popen([sys.executable, str(app/'tool/fixtures/vnc_desktop.py'), temporary], env=env, stdout=gtk_log, stderr=gtk_log)
        processes.append(desktop)
        deadline = time.monotonic()+10
        while not (folder/'ready').exists():
            if desktop.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('GTK fixture failed to start')
            time.sleep(.05)
        subprocess.run(['xdotool', 'search', '--name', 'salp-vnc-fixture', 'windowfocus', '--sync'], env=env, check=True)
        for name in ('host_key', 'client_key'):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(folder/name)], check=True)
        (folder/'authorized_keys').write_bytes((folder/'client_key.pub').read_bytes())
        fingerprint = subprocess.check_output(['ssh-keygen', '-lf', str(folder/'host_key.pub')], text=True).split()[1]
        (folder/'public.json').write_text(json.dumps({'vnc_port': vnc_port, 'ssh_port': ssh_port, 'username': getpass.getuser(), 'fingerprint': fingerprint}))
        (folder/'sshd_config').write_text(f'''ListenAddress 127.0.0.1
Port {ssh_port}
HostKey {folder}/host_key
PidFile {folder}/sshd.pid
AuthorizedKeysFile {folder}/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowTcpForwarding yes
PermitRootLogin no
LogLevel ERROR
''')
        ssh_log = (folder/'ssh.log').open('w+')
        logs.append(ssh_log)
        daemon = subprocess.Popen(['/usr/bin/sshd', '-D', '-e', '-f', str(folder/'sshd_config')], stdout=ssh_log, stderr=ssh_log)
        processes.append(daemon)
        for _ in range(100):
            if daemon.poll() is not None:
                raise RuntimeError('sshd fixture failed to start')
            try:
                with socket.create_connection(('127.0.0.1', ssh_port), timeout=.1):
                    break
            except OSError:
                time.sleep(.05)
        env['SALP_VNC_FIXTURE'] = temporary
        subprocess.run([sys.executable, str(app/'tool/run.py'), 'flutter', 'test', '--no-pub', 'test/vnc_integration_test.dart'], env=env, check=True)
        (evidence/'vnc-runtime.json').write_text(json.dumps({
            'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'server': 'TigerVNC 1.16.2-6', 'framebuffer': [640, 480],
            'password_rejection': True, 'direct_and_openssh_jump': True,
            'exact_red_blue_pixels': True, 'gtk_keyboard_pointer_events': True,
            'lock_suppresses_input': True, 'additional_reconnect_cycles': 10,
            'scope': 'Dart production VncSession against TigerVNC, GTK and OpenSSH; not Flutter desktop-view visual acceptance',
            'events': [json.loads(line) for line in (folder/'events.jsonl').read_text().splitlines()],
        }, indent=2)+'\n')
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.flush()
            log.seek(0)
            text = log.read()
            (evidence/('vnc-'+Path(log.name).name)).write_text(text)
            log.close()
