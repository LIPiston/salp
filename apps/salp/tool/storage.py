#!/usr/bin/env python3
"""Record allocated disk use without adding parent and child paths twice."""
import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import subprocess

app = Path(__file__).resolve().parents[1]
base = Path(os.environ.get('SALP_TOOLCHAIN', str(Path.home() / '.local/share/salp-flutter-spike')))
sdk = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Android/Sdk')))
evidence = app.parents[1] / 'docs/verification/flutter-spike'
previous = json.loads((evidence / 'storage.json').read_text())
paths = {
    'android_sdk': sdk, 'gradle': Path.home() / '.gradle',
    'flutter_toolchain': base, 'app_build': app / 'build',
    'android_native_bundle': app / 'android/app/src/main/jniLibs',
    'android_ndk': sdk / 'ndk/28.2.13676358',
    'android_platform35': sdk / 'platforms/android-35',
    'android_cmake': sdk / 'cmake/3.22.1',
    'native_sources': base / 'native-src',
    'native_build': base / 'native-build',
    'android_avd': base / 'android-avd',
}
def measure(item):
    name, path = item
    value = int(subprocess.check_output(['du', '-sk', str(path)], text=True).split()[0]) if path.exists() else 0
    return name, value
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    sizes = dict(pool.map(measure, paths.items()))
baseline = previous['baseline_kib']
root_names = ['android_sdk', 'gradle', 'flutter_toolchain', 'app_build', 'android_native_bundle']
result = {
    'captured_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'paths': {name: str(path) for name, path in paths.items()},
    'disk_kib': sizes, 'baseline_kib': baseline,
    'counted_roots': root_names,
    'incremental_kib': sum(sizes[name] - baseline.get(name, 0) for name in root_names),
    'notes': list(dict.fromkeys(previous['notes'] + [
        'FreeRDP/OpenSSL source and build directories are included in flutter_toolchain.',
        'Native jniLibs is outside app_build and is counted separately.',
        'No Rust builds are included or inspected.',
        'Android verification AVD data is included in flutter_toolchain; its system image already existed in the SDK baseline.',
    ])),
}
(evidence / 'storage.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
