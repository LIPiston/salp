"""Keep Android-only native libraries out of Linux packages."""
import tempfile
import unittest
from pathlib import Path

from package_linux import stage


class LinuxStageTest(unittest.TestCase):
    def write_bundle(self, folder):
        bundle = folder / 'bundle'
        (bundle / 'lib').mkdir(parents=True)
        (bundle / 'salp').write_text('#!/bin/sh\n')
        (bundle / 'salp').chmod(0o755)
        (bundle / 'lib/libapp.so').write_bytes(b'linux')
        (bundle / 'lib/libjni_helper.so').write_bytes(b'linux')
        (bundle / 'lib/libapp.so.1').symlink_to('libapp.so')
        (bundle / 'lib/libdartjni.so').write_bytes(b'android')
        return bundle

    def assert_staged(self, bundle, root, prefix):
        target = stage(bundle, root, prefix)
        self.assertFalse((target / 'lib/libdartjni.so').exists())
        self.assertTrue((target / 'lib/libapp.so').is_file())
        self.assertTrue((target / 'lib/libjni_helper.so').is_file())
        link = target / 'lib/libapp.so.1'
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.readlink(), Path('libapp.so'))
        self.assertTrue(link.resolve().is_file())
        self.assertTrue((target / 'salp').is_file())
        self.assertEqual((bundle / 'lib/libdartjni.so').read_bytes(), b'android')

    def test_stages_deb_and_pacman_payload_without_android_jni(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            self.assert_staged(self.write_bundle(folder), folder / 'root', 'usr')

    def test_stages_flatpak_payload_without_android_jni(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            self.assert_staged(self.write_bundle(folder), folder / 'root', '')


if __name__ == '__main__':
    unittest.main()
