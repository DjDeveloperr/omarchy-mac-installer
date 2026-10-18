#!/usr/bin/env python3
"""Exercise persistent boot defaults without chrooting or opening a device."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BUILDER = Path(__file__).resolve().parents[1] / "builder/finalize-root"


class FinalizeRootTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / "root"
        for name, contents in (
            ("etc/machine-id", ""),
            ("etc/locale.gen", "#en_US.UTF-8 UTF-8\n"),
            ("usr/share/zoneinfo/UTC", "timezone fixture\n"),
            ("usr/share/plymouth/themes/omarchy/omarchy.plymouth", "theme fixture\n"),
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        stub = self.base / "bin/chroot"
        stub.parent.mkdir()
        stub.write_text('#!/bin/bash\nexit 0\n')
        stub.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(stub.parent) + os.pathsep + os.environ["PATH"])

    def finalize(self, profile=None):
        command = ["bash", str(BUILDER), "--root", str(self.root)]
        if profile is not None:
            command += ["--hardware-profile", profile]
        return subprocess.run(command, env=self.environment, capture_output=True, text=True)

    def test_legacy_defaults_remain_unchanged(self):
        for profile in (None, "legacy"):
            with self.subTest(profile=profile):
                result = self.finalize(profile)
                self.assertEqual(result.returncode, 0, result.stderr)
                defaults = (self.root / "etc/default/grub").read_text()
                self.assertIn('GRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs"\n', defaults)
                self.assertNotIn("arm64.nowfxt", defaults)

    def test_neo_persistent_defaults_are_idempotent(self):
        result = self.finalize("neo")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.root / "etc/default/grub"
        first = path.read_bytes()
        self.assertIn(b'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs arm64.nowfxt"\n', first)
        result = self.finalize("neo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), first)
        self.assertEqual(first.count(b"arm64.nowfxt"), 1)

    def test_unknown_profile_is_rejected_before_writes(self):
        result = self.finalize("other")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown hardware profile", result.stderr)
        self.assertFalse((self.root / "etc/default/grub").exists())


if __name__ == "__main__":
    unittest.main()
