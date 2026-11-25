#!/usr/bin/env python3
"""Run the app with an optional isolated Flutter toolchain; no shell config edits."""
import os, sys, subprocess, shutil
from pathlib import Path
base = Path(os.environ.get('SALP_TOOLCHAIN', str(Path.home()/'.local/share/salp-flutter-spike')))
env = os.environ.copy()
env.update(CI='true', FLUTTER_SUPPRESS_ANALYTICS='true')
if base.exists(): env['PUB_CACHE']=str(base/'pub-cache')
env['PATH'] = str(base/'flutter/bin') + os.pathsep + env['PATH']
if not shutil.which('clang'):
    env['PATH'] = str(base/'native-tools/usr/bin') + ':' + env['PATH']
env['LD_LIBRARY_PATH'] = str(base/'native-tools/usr/lib') + (':' + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
if (base/'jdk').exists():
    env['JAVA_HOME'] = str(base/'jdk')
    env['PATH'] = str(base/'jdk/bin') + ':' + env['PATH']
command = sys.argv[1:] or ['flutter', '--version']
raise SystemExit(subprocess.call(command, env=env, cwd=Path(__file__).resolve().parents[1]))
