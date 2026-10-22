import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("try_omarchy_kit", ROOT / "scripts/try_omarchy_kit.py")
kit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kit)


class TryOmarchyKitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory)
        (self.directory / "Packaging").mkdir()
        shutil.copytree(ROOT / "Vendor/TryOmarchyKitClient", self.directory / "Vendor/TryOmarchyKitClient")
        shutil.copyfile(ROOT / "Packaging/try-omarchy-kit.json", self.directory / "Packaging/try-omarchy-kit.json")

    def pin(self) -> dict:
        return json.loads((self.directory / "Packaging/try-omarchy-kit.json").read_text())

    def write_pin(self, pin: dict) -> None:
        (self.directory / "Packaging/try-omarchy-kit.json").write_text(json.dumps(pin))

    def test_the_vendored_client_matches_its_pin(self) -> None:
        kit.check(ROOT)
        kit.check(self.directory)

    def test_a_changed_client_is_refused(self) -> None:
        source = self.directory / "Vendor/TryOmarchyKitClient/VMRunProtocol.swift"
        source.write_text(source.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "differs from the pinned client"):
            kit.check(self.directory)

    def test_the_pin_is_validated(self) -> None:
        good = self.pin()
        for change in (
            lambda pin: pin.update(format=2),
            lambda pin: pin["client"].update(repository="someone/fork"),
            lambda pin: pin["client"].update(revision="main"),
            lambda pin: pin.update(kit={"release": "v1.2.3", "url": "https://example.com/TryOmarchyKit.zip",
                                        "bytes": 1, "sha256": "0" * 64}),
            lambda pin: pin.update(kit={"release": "v1.2.3", "url": kit.kit_url("v1.2.3"),
                                        "bytes": True, "sha256": "0" * 64}),
        ):
            pin = copy.deepcopy(good)
            change(pin)
            self.write_pin(pin)
            with self.assertRaises(ValueError):
                kit.check(self.directory)
        pin = copy.deepcopy(good)
        pin["kit"] = {"release": "v1.2.3", "url": kit.kit_url("v1.2.3"), "bytes": 1, "sha256": "0" * 64}
        self.write_pin(pin)
        self.assertEqual(kit.check(self.directory)["kit"]["release"], "v1.2.3")

    def test_without_a_pinned_kit_there_is_nothing_to_embed(self) -> None:
        pin = self.pin()
        pin["kit"] = None
        self.write_pin(pin)
        self.assertIsNone(kit.fetch(self.directory / "cache", self.directory, {}))

    def test_a_local_kit_must_match_the_digest_beside_it(self) -> None:
        archive = self.directory / "TryOmarchyKit.zip"
        archive.write_bytes(b"kit")
        sidecar = Path(f"{archive}.sha256")
        sidecar.write_text(f"{hashlib.sha256(b'kit').hexdigest()}  TryOmarchyKit.zip\n")
        environment = {"OMARCHY_TRY_KIT_ZIP": str(archive)}
        self.assertEqual(kit.fetch(self.directory / "cache", self.directory, environment), archive.resolve())
        sidecar.write_text("0" * 64 + "  TryOmarchyKit.zip\n")
        with self.assertRaisesRegex(ValueError, "does not match"):
            kit.fetch(self.directory / "cache", self.directory, environment)

    def test_a_cached_kit_is_used_when_it_matches_the_pin(self) -> None:
        cache = self.directory / "cache"
        cache.mkdir()
        digest = hashlib.sha256(b"kit").hexdigest()
        (cache / f"{digest}.zip").write_bytes(b"kit")
        pin = self.pin()
        pin["kit"] = {"release": "v1.2.3", "url": kit.kit_url("v1.2.3"), "bytes": 3, "sha256": digest}
        self.write_pin(pin)
        self.assertEqual(kit.fetch(cache, self.directory, {}), cache / f"{digest}.zip")


if __name__ == "__main__":
    unittest.main()
