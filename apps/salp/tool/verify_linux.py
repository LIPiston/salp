#!/usr/bin/env python3
"""Check library resolution and launch the installed Linux/Flatpak package."""
import argparse
import ctypes
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=Path)
parser.add_argument('--flatpak', action='store_true')
args = parser.parse_args()
env = os.environ.copy()
env.update(GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1', NO_AT_BRIDGE='1')
with tempfile.TemporaryDirectory(prefix='salp-linux-smoke-') as folder:
    env['SALP_DATA_DIR'] = folder
    # CI has no logged-in desktop session. Create an isolated, unlocked Secret
    # Service before the app asks for its vault key; never use a user's keyring.
    keyring_env = env.copy()
    for key, child in [('XDG_DATA_HOME', 'data'), ('XDG_CONFIG_HOME', 'config'),
                       ('XDG_CACHE_HOME', 'cache')]:
        keyring_env[key] = str(Path(folder) / child)
    subprocess.run(['dbus-update-activation-environment', 'DISPLAY', 'XAUTHORITY'],
                   env=env, check=True)
    keyring = subprocess.run(
        ['gnome-keyring-daemon', '--unlock', '--components=secrets'],
        input=secrets.token_urlsafe(32), text=True, capture_output=True,
        env=keyring_env, check=True,
    )
    for line in keyring.stdout.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in ('GNOME_KEYRING_CONTROL', 'SSH_AUTH_SOCK'):
                env[key] = value
    if args.flatpak:
        dependencies = subprocess.run(
            ['flatpak', 'run', '--command=sh', 'dev.salp.salp', '-ec',
             'export LD_LIBRARY_PATH=/app/lib/salp/lib; '
             'for library in /app/lib/salp/salp /app/lib/salp/lib/*.so*; '
             'do ldd "$library"; done'],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        if dependencies.returncode or 'not found' in dependencies.stdout:
            raise RuntimeError(f'Unresolved Flatpak runtime dependencies:\n{dependencies.stdout}')
        command = ['flatpak', 'run', '--env=GDK_BACKEND=x11',
                   '--env=LIBGL_ALWAYS_SOFTWARE=1',
                   '--env=NO_AT_BRIDGE=1',
                   '--env=SALP_DATA_DIR=/tmp/salp-smoke-vault', 'dev.salp.salp']
    else:
        bundle = args.bundle.resolve(strict=True)
        env['LD_LIBRARY_PATH'] = str(bundle / 'lib')
        env['OPENSSL_MODULES'] = str(bundle / 'lib/ossl-modules')
        for library in [bundle / 'salp', *list((bundle / 'lib').glob('*.so*'))]:
            result = subprocess.run(['ldd', str(library)], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            if result.returncode or 'not found' in result.stdout:
                raise RuntimeError(f'Unresolved dependencies: {library}\n{result.stdout}')
        os.environ['OPENSSL_MODULES'] = env['OPENSSL_MODULES']
        crypto = ctypes.CDLL(str(bundle / 'lib/libcrypto.so.3'))
        crypto.OSSL_PROVIDER_load.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        crypto.OSSL_PROVIDER_load.restype = ctypes.c_void_p
        if not crypto.OSSL_PROVIDER_load(None, b'legacy'):
            raise RuntimeError('Bundled OpenSSL legacy provider failed to load')
        command = [str(bundle / 'salp')]
    with (Path(folder) / 'startup.log').open('w+') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(f'Application exited ({process.returncode}):\n{log.read()}')
                window = subprocess.run(['xdotool', 'search', '--onlyvisible', '--class',
                                         'dev.salp.salp'], stdout=subprocess.DEVNULL)
                if window.returncode == 0:
                    time.sleep(3)
                    if process.poll() is not None:
                        raise RuntimeError('Application exited after showing a window')
                    print('PASS: installed application stays running with a visible window.')
                    break
                time.sleep(.25)
            else:
                log.seek(0)
                raise RuntimeError(f'No application window:\n{log.read()}')
        finally:
            if args.flatpak:
                subprocess.run(['flatpak', 'kill', 'dev.salp.salp'], check=False)
            elif process.poll() is None:
                process.terminate()
            process.wait(timeout=15)
