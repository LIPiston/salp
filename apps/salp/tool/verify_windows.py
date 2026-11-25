#!/usr/bin/env python3
"""Windows runner check: load the portable DLLs and launch the actual executable.
This proves packaging/startup, not interactive protocol or hardware acceptance.
"""
import ctypes
from ctypes import wintypes
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def verify(bundle: Path):
    if sys.platform != 'win32':
        raise RuntimeError('This check must run on Windows')
    bundle = bundle.resolve(strict=True)
    for name in ('salp.exe', 'flutter_windows.dll', 'flutter_pty.dll',
                 'salp_rdp.dll', 'libserialport.dll', 'data/app.so', 'data/icudtl.dat'):
        if not (bundle / name).is_file():
            raise RuntimeError(f'Missing portable file: {name}')
    # Exclude vcpkg/Visual Studio/Flutter from DLL lookup. Only the bundle and OS
    # are allowed, otherwise a broken archive can appear healthy on a build host.
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.SetDefaultDllDirectories.argtypes = [wintypes.DWORD]
    kernel.SetDefaultDllDirectories.restype = wintypes.BOOL
    if not kernel.SetDefaultDllDirectories(0x1000):  # LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
        raise ctypes.WinError(ctypes.get_last_error())
    with os.add_dll_directory(str(bundle)):
        libraries = {path.name: ctypes.CDLL(str(path), winmode=0x1100)
                     for path in bundle.glob('*.dll')}
        rdp = libraries['salp_rdp.dll']
        for export in ('start', 'state', 'error', 'frame', 'certificate',
                       'trust', 'input', 'lock', 'stop', 'free'):
            getattr(rdp, 'salp_rdp_' + export)
        serial = libraries['libserialport.dll']
        ports = ctypes.c_void_p()
        serial.sp_list_ports.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        serial.sp_list_ports.restype = ctypes.c_int
        serial.sp_free_port_list.argtypes = [ctypes.c_void_p]
        if serial.sp_list_ports(ctypes.byref(ports)) != 0:
            raise RuntimeError('libserialport failed to enumerate ports')
        serial.sp_free_port_list(ports)
        with tempfile.TemporaryDirectory(prefix='salp-windows-smoke-') as folder:
            env = os.environ.copy()
            env.update(APPDATA=folder, LOCALAPPDATA=folder, SALP_DATA_DIR=str(Path(folder) / 'vault'),
                       PATH=str(bundle) + os.pathsep + str(Path(env['SystemRoot']) / 'System32'))
            process = subprocess.Popen([str(bundle / 'salp.exe')], cwd=bundle, env=env)
            try:
                user = ctypes.WinDLL('user32', use_last_error=True)
                callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
                user.EnumWindows.argtypes = [callback_type, wintypes.LPARAM]
                user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
                user.IsWindowVisible.argtypes = [wintypes.HWND]
                visible = []

                @callback_type
                def inspect_window(handle, _):
                    pid = wintypes.DWORD()
                    user.GetWindowThreadProcessId(handle, ctypes.byref(pid))
                    if pid.value == process.pid and user.IsWindowVisible(handle):
                        visible.append(int(handle))
                    return True

                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f'salp exited during startup: {process.returncode}')
                    user.EnumWindows(inspect_window, 0)
                    if visible:
                        break
                    time.sleep(.2)
                if not visible:
                    raise RuntimeError('No visible salp window after 30 seconds')
                # The runner shows its window after Flutter's first rendered frame.
                time.sleep(2)
                if process.poll() is not None:
                    raise RuntimeError(f'salp crashed after first frame: {process.returncode}')
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)
    report = {
        'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'dlls_loaded_from_portable_bundle': sorted(libraries),
        'rdp_bridge_exports': True, 'serial_enumeration': True,
        'flutter_first_frame_visible': True,
        'scope': 'Windows CI startup; no interactive SSH/RDP/PTY, lock-screen or hardware claim',
    }
    (bundle / 'windows-smoke.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
