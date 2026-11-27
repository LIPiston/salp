#!/usr/bin/env python3
"""Fetch pinned sources and build an Android FreeRDP/OpenSSL bundle (no SDK install).

Requires an existing NDK 28.2, CMake, Ninja, Make and Perl. Downloads and
intermediates stay under SALP_TOOLCHAIN; source hashes are checked on every run.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--abi', choices=('arm64-v8a', 'x86_64'), default='arm64-v8a')
parser.add_argument('--jobs', type=int, default=2)
parser.add_argument('--rebuild-openssl', action='store_true')
args = parser.parse_args()
architecture = {
    'arm64-v8a': ('aarch64-linux-android24-clang++', 'android-arm64', 'arm64'),
    'x86_64': ('x86_64-linux-android24-clang++', 'android-x86_64', 'x86_64'),
}
compiler_name, openssl_target, build_arch = architecture[args.abi]
if not 1 <= args.jobs <= 8:
    parser.error('--jobs must be between 1 and 8')
root = pathlib.Path(__file__).resolve().parents[1]
base = pathlib.Path(os.environ.get('SALP_TOOLCHAIN', str(pathlib.Path.home() / '.local/share/salp-flutter-spike')))
sdk = pathlib.Path(os.environ.get('ANDROID_HOME', str(pathlib.Path.home() / 'Android/Sdk')))
ndk = pathlib.Path(os.environ.get('ANDROID_NDK_HOME', str(sdk / 'ndk/28.2.13676358')))
compiler_dir = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
if not (compiler_dir / compiler_name).is_file():
    parser.error(f'Existing Linux NDK 28.2 required: {ndk}')
for command in ('cmake', 'ninja', 'make', 'perl'):
    if not shutil.which(command):
        parser.error(f'Missing build prerequisite: {command}')
sources = [
    {
        'name': 'FreeRDP', 'version': '3.33.1', 'folder': 'FreeRDP-3.33.1',
        'archive': 'freerdp-3.33.1.tar.gz',
        'url': 'https://codeload.github.com/FreeRDP/FreeRDP/tar.gz/refs/tags/3.33.1',
        'sha256': '6b6da1e7217f924b033da6896e70eb4c4a447c3900d03c0d10179062f0a7d495',
        'license': 'LICENSE',
    },
    {
        'name': 'OpenSSL', 'version': '4.0.1', 'folder': 'openssl-4.0.1',
        'archive': 'openssl-4.0.1.tar.gz',
        'url': 'https://github.com/openssl/openssl/releases/download/openssl-4.0.1/openssl-4.0.1.tar.gz',
        'sha256': '2db3f3a0d6ea4b59e1f094ace2c8cd536dffb87cdc39084c5afa1e6f7f37dd09',
        'license': 'LICENSE.txt',
    },
]
source_cache = base / 'native-src'
source_cache.mkdir(parents=True, exist_ok=True)
for item in sources:
    archive = source_cache / item['archive']
    if not archive.exists():
        partial = archive.with_suffix('.download')
        try:
            print('Downloading', item['url'], flush=True)
            with urllib.request.urlopen(item['url'], timeout=60) as response, partial.open('wb') as output:
                shutil.copyfileobj(response, output)
            if hashlib.file_digest(partial.open('rb'), 'sha256').hexdigest() != item['sha256']:
                raise RuntimeError(f"Source checksum mismatch: {item['name']}")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    with archive.open('rb') as source_file:
        if hashlib.file_digest(source_file, 'sha256').hexdigest() != item['sha256']:
            raise RuntimeError(f"Source checksum mismatch: {archive}; cache preserved for inspection")
    if not (source_cache / item['folder']).exists():
        with tarfile.open(archive) as source_tar:
            source_tar.extractall(source_cache, filter='data')
source = source_cache / 'FreeRDP-3.33.1'
patch = root / 'native/patches/android-private-path.patch'
shell_source = source / 'winpr/libwinpr/path/shell.c'
if 'SALP_RDP_PRIVATE_DIR' not in shell_source.read_text():
    subprocess.run(['patch', '-p1', '--input', str(patch)], cwd=source, check=True)

build = base / f'native-build/freerdp-{build_arch}'
build.mkdir(parents=True, exist_ok=True)
prefix = base / f'native-build/android-prefix-{build_arch}'
openssl_build = base / f'native-build/openssl-{build_arch}'
openssl_build.mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env['ANDROID_NDK_ROOT'] = str(ndk)
env['PATH'] = str(compiler_dir) + os.pathsep + env['PATH']
openssl_config = {
    'source': sources[1]['sha256'], 'ndk': str(ndk), 'api': 24, 'abi': args.abi,
    'options': ['no-shared', 'no-tests', 'no-apps', 'no-docs', '-fPIC', '-Os'],
}
stamp = openssl_build / 'salp-build.json'
if (args.rebuild_openssl or not stamp.exists() or
        json.loads(stamp.read_text()) != openssl_config or
        not (prefix / 'lib/libcrypto.a').exists() or
        not (prefix / 'lib/libssl.a').exists()):
    log_path = base / f'native-build/openssl-{build_arch}.log'
    print('Building OpenSSL; log:', log_path, flush=True)
    with log_path.open('w') as log:
        for command in (
            ['perl', str(source_cache / 'openssl-4.0.1/Configure'), openssl_target,
             *openssl_config['options'], '-D__ANDROID_API__=24', f'--prefix={prefix}', '--libdir=lib'],
            ['make', f'-j{args.jobs}', 'build_libs'],
            ['make', 'install_dev'],
        ):
            subprocess.run(command, cwd=openssl_build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    stamp.write_text(json.dumps(openssl_config, indent=2) + '\n')
flags={
'CMAKE_TOOLCHAIN_FILE':str(ndk/'build/cmake/android.toolchain.cmake'),'ANDROID_ABI':args.abi,'ANDROID_PLATFORM':'android-24','ANDROID_STL':'c++_static','CMAKE_BUILD_TYPE':'MinSizeRel','CMAKE_INSTALL_PREFIX':str(prefix),'CMAKE_PREFIX_PATH':str(prefix),
'OPENSSL_ROOT_DIR':str(prefix),'OPENSSL_USE_STATIC_LIBS':'ON','OPENSSL_INCLUDE_DIR':str(prefix/'include'),'OPENSSL_CRYPTO_LIBRARY':str(prefix/'lib/libcrypto.a'),'OPENSSL_SSL_LIBRARY':str(prefix/'lib/libssl.a'),
'CMAKE_SHARED_LINKER_FLAGS':'-Wl,--exclude-libs,ALL -Wl,-z,max-page-size=16384','BUILD_SHARED_LIBS':'ON','BUILD_TESTING':'OFF','WITH_MANPAGES':'OFF','WITH_CLIENT':'OFF','WITH_CLIENT_COMMON':'OFF','WITH_SERVER':'OFF','WITH_SAMPLE':'OFF','WITH_CHANNELS':'OFF','WITH_FFMPEG':'OFF','WITH_SWSCALE':'OFF','WITH_OPENH264':'OFF','WITH_JPEG':'OFF','WITH_WEBP':'OFF','WITH_CAIRO':'OFF','WITH_PULSE':'OFF','WITH_ALSA':'OFF','WITH_CUPS':'OFF','WITH_PCSC':'OFF','WITH_PKCS11':'OFF','WITH_KRB5':'OFF','WITH_GSSAPI':'OFF','WITH_WINPR_JSON':'OFF','WITH_AAD':'OFF','WITH_URIPARSER':'OFF','WITH_WINPR_TOOLS':'OFF','WITH_X11':'OFF','WITH_WAYLAND':'OFF','WITH_OPUS':'OFF','WITH_FAAC':'OFF','WITH_FAAD2':'OFF','WITH_LAME':'OFF','WITH_SOXR':'OFF','WITH_OPENSSL':'ON','WITH_MBEDTLS':'OFF','WITH_CCACHE':'OFF','WITH_CLANG_FORMAT':'OFF','WITH_SSE2':'OFF','WITH_NEON':'ON','WITH_SMARTCARD_EMULATE':'OFF','WITH_ICU':'OFF','WITH_UNICODE_BUILTIN':'ON','WITH_LIBSYSTEMD':'OFF','WITH_FUSE':'OFF','WITH_OSS':'OFF','WITH_SNDIO':'OFF','WITH_OPENSLES':'OFF','WITH_AAUDIO':'OFF',
}
flags.update(WITH_NEON='ON' if args.abi == 'arm64-v8a' else 'OFF',
             WITH_SSE2='ON' if args.abi == 'x86_64' else 'OFF')
log_path = base / f'native-build/freerdp-{build_arch}.log'
print('Building FreeRDP and salp bridge; log:', log_path, flush=True)
with log_path.open('w') as log:
    def run(command):
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    run(['cmake', '-S', str(source), '-B', str(build), '-GNinja', *[f'-D{k}={v}' for k,v in flags.items()]])
    run(['cmake', '--build', str(build), f'-j{args.jobs}', '--target', 'freerdp', 'winpr'])
    run(['cmake', '--install', str(build)])
    dest = root / 'android/app/src/main/jniLibs' / args.abi
    staged = base / f'native-build/android-bundle-{build_arch}'
    staged.mkdir(parents=True, exist_ok=True)
    for name in ('libfreerdp3.so', 'libwinpr3.so'):
        candidates = list(build.rglob(name))
        if not candidates:
            raise RuntimeError(f'Missing built library: {name}')
        shutil.copy2(candidates[0], staged / name)
    compiler = compiler_dir / compiler_name
    run([str(compiler), '-shared', '-fPIC', '-Os', '-std=c++17', '-static-libstdc++',
         f'-I{prefix}/include/freerdp3', f'-I{prefix}/include/winpr3',
         str(root / 'native/rdp_bridge.cc'), f'-L{staged}', '-lfreerdp3', '-lwinpr3', '-llog',
         '-Wl,-z,max-page-size=16384', '-o', str(staged / 'libsalp_rdp.so')])
    libraries = list(staged.glob('*.so'))
    for library in libraries:
        run([str(compiler_dir / 'llvm-strip'), '--strip-unneeded', str(library)])
    dest.mkdir(parents=True, exist_ok=True)
    for library in libraries:
        shutil.copy2(library, dest / library.name)
licenses = root / 'assets/licenses'
licenses.mkdir(parents=True, exist_ok=True)
for item in sources:
    shutil.copy2(source_cache / item['folder'] / item['license'], licenses / (item['name'] + '.txt'))
manifest = {'abi': args.abi, 'api': 24, 'ndk': '28.2.13676358', 'sources': sources, 'patches': {str(patch.relative_to(root)): hashlib.sha256(patch.read_bytes()).hexdigest()},
            'libraries': {p.name: {'bytes': p.stat().st_size, 'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
                          for p in libraries}}
manifest_path = dest / 'salp-native-build.json'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
print('Android', args.abi, 'RDP native libraries ready:', dest)
