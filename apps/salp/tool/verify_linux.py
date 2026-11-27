#!/usr/bin/env python3
"""Check library resolution and launch the installed Linux/Flatpak package."""
import argparse
import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=Path)
parser.add_argument('--flatpak', action='store_true')
args = parser.parse_args()
env = os.environ.copy()
env.update(GDK_BACKEND='x11', LIBGL_ALWAYS_SOFTWARE='1')
with tempfile.TemporaryDirectory(prefix='salp-linux-smoke-') as folder:
    env['SALP_DATA_DIR'] = folder
    if args.flatpak:
        command = ['flatpak', 'run', '--env=GDK_BACKEND=x11',
                   '--env=LIBGL_ALWAYS_SOFTWARE=1',
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
