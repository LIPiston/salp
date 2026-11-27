#!/usr/bin/env python3
"""Package a verified Linux x64 Flutter bundle as deb, pacman and Flatpak."""
import argparse
import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile

APP_ID = 'dev.salp.salp'
APP = Path(__file__).resolve().parents[1]
REPO = APP.parents[1]


def run(*command):
    subprocess.run([str(part) for part in command], check=True)


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def stage(bundle, root, prefix):
    target = root / prefix / 'lib/salp'
    shutil.copytree(bundle, target, symlinks=True)
    launcher = root / prefix / 'bin/salp'
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(
        '#!/bin/sh\n'
        'app_dir="$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")/../lib/salp" && pwd)"\n'
        'export LD_LIBRARY_PATH="$app_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
        'export OPENSSL_MODULES="$app_dir/lib/ossl-modules"\n'
        'exec "$app_dir/salp" "$@"\n'
    )
    launcher.chmod(0o755)
    copy(APP / 'packaging/linux' / f'{APP_ID}.desktop',
         root / prefix / 'share/applications' / f'{APP_ID}.desktop')
    copy(APP / 'packaging/linux' / f'{APP_ID}.metainfo.xml',
         root / prefix / 'share/metainfo' / f'{APP_ID}.metainfo.xml')
    copy(APP / 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
         root / prefix / 'share/icons/hicolor/192x192/apps' / f'{APP_ID}.png')
    return target


def prepare_bundle(bundle):
    prefix = REPO / '.ci/linux-native/prefix'
    for pattern in ('libfreerdp3.so*', 'libwinpr3.so*'):
        for library in (prefix / 'lib').glob(pattern):
            copy(library.resolve(), bundle / 'lib' / library.name)
    # OpenSSL SONAMEs differ between Debian, Arch and Flatpak. Keep the exact
    # dynamically linked crypto and serial libraries alongside this build.
    for soname in ('libssl.so.3', 'libcrypto.so.3', 'libserialport.so.0'):
        listing = subprocess.check_output(['/sbin/ldconfig', '-p'], text=True)
        matches = [line.split('=>', 1)[1].strip() for line in listing.splitlines()
                   if line.strip().startswith(soname + ' ') and 'x86-64' in line]
        if not matches:
            raise RuntimeError(f'Missing runtime library: {soname}')
        copy(Path(matches[0]).resolve(), bundle / 'lib' / soname)
    # FreeRDP loads the OpenSSL legacy provider for NTLM. A host's OpenSSL 4
    # module cannot be loaded into the private OpenSSL 3 library.
    copy(Path('/usr/lib/x86_64-linux-gnu/ossl-modules/legacy.so'),
         bundle / 'lib/ossl-modules/legacy.so')
    licenses = bundle / 'licenses'
    copy(REPO / 'LICENSE', licenses / 'salp.txt')
    copy(APP / 'THIRD-PARTY.md', licenses / 'THIRD-PARTY.md')
    copy(REPO / '.ci/linux-native/src/FreeRDP-3.33.1/LICENSE', licenses / 'FreeRDP.txt')
    for package in ('libssl3', 'libserialport0'):
        copy(Path('/usr/share/doc') / package / 'copyright', licenses / f'{package}.txt')
    sources = bundle / 'sources'
    sources.mkdir(exist_ok=True)
    run('git', '-C', REPO, 'archive', '--format=tar.gz', f'--output={sources / "salp.tar.gz"}',
        'HEAD', 'apps/salp', '.github', 'LICENSE')
    copy(REPO / '.ci/linux-native/src/freerdp-3.33.1.tar.gz',
         sources / 'freerdp-3.33.1.tar.gz')
    build = {
        'commit': subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
        'built_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'architecture': 'x86_64', 'baseline': 'Ubuntu 22.04 (glibc 2.35)',
    }
    (bundle / 'build-info.json').write_text(json.dumps(build, indent=2) + '\n')


def package(bundle, output, version, formats):
    work = REPO / '.ci/linux-packaging'
    output.mkdir(parents=True, exist_ok=True)
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+~]*', version):
        raise ValueError(f'Invalid package version: {version}')
    if 'deb' in formats or 'pacman' in formats:
        root = work / 'native'
        if root.exists():
            shutil.rmtree(root)
        stage(bundle, root, 'usr')
        if 'deb' in formats:
            control = root / 'DEBIAN/control'
            control.parent.mkdir()
            size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
            control.write_text(
                f'Package: salp-nightly\nVersion: {version}\nArchitecture: amd64\n'
                'Maintainer: LIPiston <75552696+LIPiston@users.noreply.github.com>\n'
                'Section: net\nPriority: optional\n'
                f'Installed-Size: {(size + 1023) // 1024}\n'
                'Depends: libc6 (>= 2.35), libstdc++6, libgtk-3-0, libsecret-1-0, '
                'libudev1, zlib1g\n'
                'Recommends: gnome-keyring\nProvides: salp\nConflicts: salp\n'
                'Homepage: https://github.com/LIPiston/salp\n'
                'Description: SSH and remote access workbench (nightly)\n'
            )
            run('dpkg-deb', '--root-owner-group', '--build', root,
                output / 'salp-linux-x64-nightly.deb')
            shutil.rmtree(control.parent)
        if 'pacman' in formats:
            size = sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
            (root / '.PKGINFO').write_text(
                f'pkgname = salp-nightly\npkgbase = salp-nightly\npkgver = {version}-1\n'
                'pkgdesc = SSH and remote access workbench (nightly)\n'
                'url = https://github.com/LIPiston/salp\n'
                f'builddate = {int(datetime.datetime.now().timestamp())}\n'
                'packager = LIPiston\n'
                f'size = {size}\narch = x86_64\nlicense = GPL-3.0-or-later\n'
                'depend = glibc\ndepend = gcc-libs\ndepend = gtk3\ndepend = libsecret\n'
                'depend = systemd-libs\ndepend = zlib\n'
                'optdepend = gnome-keyring: Secret Service credential storage\n'
                'provides = salp\nconflict = salp\n'
            )
            tar = work / 'salp.tar'
            with tarfile.open(tar, 'w', format=tarfile.GNU_FORMAT) as archive:
                def owner(info):
                    info.uid = info.gid = 0
                    info.uname = info.gname = 'root'
                    return info
                for child in sorted(root.iterdir()):
                    archive.add(child, arcname=child.name, filter=owner)
            run('zstd', '--force', '-T0', tar, '-o', output / 'salp-linux-x64-nightly.pkg.tar.zst')
            tar.unlink()
    if 'flatpak' in formats:
        root = work / 'flatpak'
        if root.exists():
            shutil.rmtree(root)
        # This is a prebuilt bundle; the installed runtime also serves as the
        # build environment, so no separate multi-gigabyte SDK is required.
        run('flatpak', 'build-init', root, APP_ID, 'org.gnome.Platform', 'org.gnome.Platform', '49')
        stage(bundle, root / 'files', '')
        run('flatpak', 'build-finish', root, '--command=salp',
            '--share=network', '--share=ipc', '--socket=wayland', '--socket=fallback-x11',
            '--socket=ssh-auth', '--device=all', '--talk-name=org.freedesktop.secrets',
            '--filesystem=home')
        repo = work / 'flatpak-repo'
        run('flatpak', 'build-export', '--disable-sandbox', repo, root, 'nightly')
        run('flatpak', 'build-bundle', repo, output / 'salp-linux-x64-nightly.flatpak',
            APP_ID, 'nightly', '--runtime-repo=https://flathub.org/repo/flathub.flatpakrepo')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=APP / 'build/linux/x64/release/bundle')
    parser.add_argument('--output', type=Path, default=REPO / '.ci/dist')
    parser.add_argument('--version', required=True)
    parser.add_argument('--formats', nargs='+', choices=('deb', 'pacman', 'flatpak'),
                        default=['deb', 'pacman', 'flatpak'])
    parser.add_argument('--prepare', action='store_true')
    args = parser.parse_args()
    if args.prepare:
        prepare_bundle(args.bundle)
    package(args.bundle, args.output, args.version, args.formats)
