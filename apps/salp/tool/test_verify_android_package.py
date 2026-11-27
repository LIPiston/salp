"""Catch missing native dependencies and mislabeled APK architectures."""
import tempfile
import unittest
import zipfile
from pathlib import Path

from verify_android_package import verify


class AndroidPackageTest(unittest.TestCase):
    def apk(self, folder, abi, machine, omit=None):
        apk = Path(folder) / 'app.apk'
        # Minimal ELF64 header: class=64-bit, little endian, e_machine at 18.
        elf = b'\x7fELF\x02\x01' + bytes(12) + machine.to_bytes(2, 'little') + bytes(44)
        with zipfile.ZipFile(apk, 'w') as archive:
            for name in ('libapp.so', 'libflutter.so', 'libsalp_rdp.so',
                         'libfreerdp3.so', 'libwinpr3.so'):
                if name != omit:
                    archive.writestr(f'lib/{abi}/{name}', elf)
        return apk

    def test_accepts_complete_native_dependencies_for_each_cpu(self):
        with tempfile.TemporaryDirectory() as folder:
            for abi, machine in [('arm64-v8a', 183), ('x86_64', 62)]:
                result = verify(self.apk(folder, abi, machine), abi)
                self.assertEqual(result['abi'], abi)

    def test_rejects_apk_without_rdp_dependency(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = self.apk(folder, 'x86_64', 62, omit='libwinpr3.so')
            with self.assertRaisesRegex(ValueError, 'libwinpr3'):
                verify(apk, 'x86_64')

    def test_rejects_arm_libraries_in_x86_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = self.apk(folder, 'x86_64', 183)
            with self.assertRaisesRegex(ValueError, 'ELF'):
                verify(apk, 'x86_64')

    def test_rejects_wrong_abi_split(self):
        with tempfile.TemporaryDirectory() as folder:
            apk = self.apk(folder, 'arm64-v8a', 183)
            with self.assertRaisesRegex(ValueError, 'ABI'):
                verify(apk, 'x86_64')


if __name__ == '__main__':
    unittest.main()
