#!/usr/bin/env python3
"""Real Windows OpenSSH agent + bounded named-pipe fault fixtures, CI only.

Only adds/removes its own temporary key; restores the service's prior state.
"""
import base64
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def powershell(script):
    return subprocess.check_output(
        ['powershell', '-NoProfile', '-NonInteractive', '-Command',
         "$ErrorActionPreference='Stop'; " + script], text=True,
    ).strip()


def main():
    if sys.platform != 'win32' or os.environ.get('CI') != 'true':
        raise RuntimeError('Run this service fixture only on an ephemeral Windows CI runner')
    app = Path(__file__).resolve().parents[1]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR] + [wintypes.DWORD] * 6 + [ctypes.c_void_p]
    kernel.CreateNamedPipeW.restype = wintypes.HANDLE
    kernel.ConnectNamedPipe.argtypes = [wintypes.HANDLE, ctypes.c_void_p]
    kernel.ConnectNamedPipe.restype = wintypes.BOOL
    kernel.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    kernel.ReadFile.restype = wintypes.BOOL
    kernel.WriteFile.argtypes = kernel.ReadFile.argtypes
    kernel.WriteFile.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel.FlushFileBuffers.argtypes = [wintypes.HANDLE]
    prior = json.loads(powershell("Get-Service ssh-agent | Select-Object Status,StartType | ConvertTo-Json -Compress"))
    added = False
    done = threading.Event()
    with tempfile.TemporaryDirectory(prefix='salp-windows-agent-') as temporary:
        root = Path(temporary)
        key = root / 'key'
        env = os.environ.copy()
        env.pop('SSH_AUTH_SOCK', None)
        openssh = Path(env['SYSTEMROOT']) / 'System32/OpenSSH'
        try:
            powershell("Set-Service ssh-agent -StartupType Manual; Start-Service ssh-agent")
            subprocess.run([str(openssh / 'ssh-keygen.exe'), '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True, env=env)
            subprocess.run([str(openssh / 'ssh-add.exe'), str(key)], check=True, env=env)
            added = True
            public = key.with_suffix('.pub').read_text().strip()
            (root / 'allowed_signers').write_text('fixture ' + public + '\n')
            blob = base64.b64decode(public.split()[1])
            payload = bytes([12]) + struct.pack('>II', 1, len(blob)) + blob + struct.pack('>I', 0)
            response = struct.pack('>I', len(payload)) + payload
            prefix = '\\\\.\\pipe\\salp-agent-' + uuid.uuid4().hex
            failures = []

            def serve(handle, mode):
                try:
                    if not kernel.ConnectNamedPipe(handle, None) and ctypes.get_last_error() != 535:
                        raise ctypes.WinError(ctypes.get_last_error())
                    data = ctypes.create_string_buffer(5)
                    count = wintypes.DWORD()
                    received = b''
                    while len(received) < 5:
                        if not kernel.ReadFile(handle, data, 5 - len(received), ctypes.byref(count), None):
                            raise ctypes.WinError(ctypes.get_last_error())
                        received += data.raw[:count.value]
                    if received != b'\0\0\0\1\x0b':
                        raise AssertionError('Unexpected agent request: ' + received.hex())
                    if mode in ('stall', 'revoked'):
                        done.wait(45)
                        return
                    chunks = {
                        'fragment': [response[:1], response[1:3], response[3:7], response[7:]],
                        'oversize': [struct.pack('>I', 256 * 1024 + 1)],
                        'truncated': [struct.pack('>I', 20), b'\x0c\0'],
                    }[mode]
                    for chunk in chunks:
                        if not kernel.WriteFile(handle, chunk, len(chunk), ctypes.byref(count), None):
                            raise ctypes.WinError(ctypes.get_last_error())
                        time.sleep(.02)
                    kernel.FlushFileBuffers(handle)
                except BaseException as error:
                    failures.append(f'{mode}: {error}')
                finally:
                    kernel.CloseHandle(handle)

            threads = []
            for mode in ('fragment', 'oversize', 'truncated', 'stall', 'revoked'):
                handle = kernel.CreateNamedPipeW(prefix + '-' + mode, 3, 8, 1, 4096, 4096, 0, None)
                if handle == ctypes.c_void_p(-1).value:
                    raise ctypes.WinError(ctypes.get_last_error())
                thread = threading.Thread(target=serve, args=(handle, mode), daemon=True)
                thread.start()
                threads.append(thread)
            env.update(SALP_WINDOWS_AGENT_FIXTURE=str(root), SALP_WINDOWS_AGENT_PIPE_PREFIX=prefix)
            result = subprocess.run(['flutter', 'test', '--no-pub', '--reporter', 'expanded',
                                     'test/windows_agent_test.dart'], cwd=app, env=env, shell=True)
            done.set()
            if result.returncode:
                raise RuntimeError(f'Windows agent tests failed ({result.returncode})')
            for thread in threads:
                thread.join(timeout=5)
            if failures or any(thread.is_alive() for thread in threads):
                raise RuntimeError('Pipe fixture failed: ' + repr(failures))
            print('Windows OpenSSH real signature and named-pipe fault checks passed')
        finally:
            done.set()
            if added:
                subprocess.run([str(openssh / 'ssh-add.exe'), '-d', str(key)], check=True, env=env)
            # ServiceControllerStatus.Running=4; ServiceStartMode.Disabled=4.
            if prior['Status'] != 4:
                powershell('Stop-Service ssh-agent')
            startup = {2: 'Automatic', 3: 'Manual', 4: 'Disabled'}[prior['StartType']]
            powershell('Set-Service ssh-agent -StartupType ' + startup)


if __name__ == '__main__':
    main()
