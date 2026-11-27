#!/usr/bin/env python3
"""Verify that an APK contains the complete native stack for exactly one ABI."""
import argparse
import json
import zipfile
from pathlib import Path


def verify(apk: Path, abi: str) -> dict:
    machine = {'arm64-v8a': 183, 'x86_64': 62}[abi]
    required = {'libapp.so', 'libflutter.so', 'libsalp_rdp.so',
                'libfreerdp3.so', 'libwinpr3.so'}
    with zipfile.ZipFile(apk) as archive:
        libraries = [name for name in archive.namelist()
                     if name.startswith('lib/') and name.endswith('.so')]
        abis = {name.split('/')[1] for name in libraries}
        if abis != {abi}:
            raise ValueError(f'APK ABI mismatch: expected {abi}, found {sorted(abis)}')
        missing = required - {Path(name).name for name in libraries}
        if missing:
            raise ValueError(f'Missing native libraries: {sorted(missing)}')
        for name in libraries:
            header = archive.read(name)[:64]
            if (header[:6] != b'\x7fELF\x02\x01' or len(header) < 64 or
                    int.from_bytes(header[18:20], 'little') != machine):
                raise ValueError(f'Wrong ELF architecture for {abi}: {name}')
    return {'apk': str(apk), 'abi': abi, 'native_libraries': sorted(libraries)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abi', choices=('arm64-v8a', 'x86_64'), required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.apk, args.abi), indent=2))
