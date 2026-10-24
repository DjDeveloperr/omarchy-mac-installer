#!/usr/bin/env python3
"""Tests for the release artifact mirror, over an in-memory bucket and canned
GitHub and CDN answers: nothing leaves the machine."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("mirror_release_artifact", SCRIPTS / "mirror_release_artifact.py")
mirror = importlib.util.module_from_spec(spec)
sys.modules["mirror_release_artifact"] = mirror
spec.loader.exec_module(mirror)

DATA = b"engine archive bytes"
SHA = hashlib.sha256(DATA).hexdigest()
REPO = "omacom/omarchy-mac-installer"


def artifact() -> mirror.Artifact:
    return mirror.Artifact(tag="engine-v1", file_name="installer-v1.tar.gz", size=len(DATA), sha256=SHA,
                           key=f"{mirror.base_prefix()}engine/v1/installer-v1.tar.gz", content_type="application/gzip")


class FakeEndpoint:
    bucket = "omarchy-mac"

    def __init__(self, store: dict):
        self.store = store
        self.puts: list[str] = []
        self.race: bytes | None = None

    def request(self, method, key, *, headers=None, body=None, size=0, payload_sha256=None, timeout=600, query=None):
        if method == "GET":
            if key not in self.store:
                raise urllib.error.HTTPError(key, 404, "Not Found", None, io.BytesIO(b""))
            return io.BytesIO(self.store[key])
        if method == "PUT":
            self.puts.append(key)
            if self.race is not None:
                self.store[key] = self.race
                raise urllib.error.HTTPError(key, 412, "Precondition Failed", None, io.BytesIO(b""))
            assert headers["If-None-Match"] == "*" and headers["Cache-Control"] == mirror.IMMUTABLE
            data = body.read()
            assert len(data) == size and hashlib.sha256(data).hexdigest() == payload_sha256
            self.store[key] = data
            return io.BytesIO(b"")
        raise AssertionError(f"unexpected {method}")


class MirrorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.release = {"tag_name": "engine-v1", "draft": False, "assets": [
            {"name": "installer-v1.tar.gz", "state": "uploaded", "size": len(DATA), "digest": f"sha256:{SHA}",
             "browser_download_url": "https://github.com/x/releases/download/engine-v1/installer-v1.tar.gz"}]}
        self.store: dict[str, bytes] = {}
        self.served = self.store
        self.downloaded = DATA
        original = mirror.urllib.request.urlopen
        mirror.urllib.request.urlopen = self.urlopen
        self.addCleanup(setattr, mirror.urllib.request, "urlopen", original)
        sleep, mirror.time.sleep = mirror.time.sleep, lambda seconds: None
        self.addCleanup(setattr, mirror.time, "sleep", sleep)

    def urlopen(self, request, timeout=None):
        url = request.full_url
        if url.startswith("https://api.github.com/"):
            if self.release is None:
                raise urllib.error.HTTPError(url, 404, "Not Found", None, io.BytesIO(b""))
            return io.BytesIO(json.dumps(self.release).encode())
        if url.startswith("https://github.com/"):
            return io.BytesIO(self.downloaded)
        key = mirror.base_prefix() + url.removeprefix(mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"].rstrip("/") + "/")
        if key not in self.served:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, io.BytesIO(b""))
        return io.BytesIO(self.served[key])

    def run_mirror(self, endpoint=None):
        endpoint = endpoint or FakeEndpoint(self.store)
        with unittest.mock.patch("sys.stdout", io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
            return mirror.mirror(artifact(), endpoint, REPO, "token"), endpoint

    def test_a_published_matching_engine_lands_once_under_the_catalog_base(self) -> None:
        url, endpoint = self.run_mirror()
        self.assertEqual(self.store[artifact().key], DATA)
        self.assertEqual(url, mirror.catalog_release.identity()["INSTALLER_CATALOG_BASE"] + "/engine/v1/installer-v1.tar.gz")
        self.assertTrue(artifact().key.startswith(mirror.base_prefix() + "engine/"))
        self.assertTrue(url.startswith(tuple(mirror.catalog_release.artifact_bases())), "catalogs may pin it")
        _, again = self.run_mirror()
        self.assertEqual(again.puts, [], "a re-run writes nothing")

    def test_a_draft_or_missing_release_is_refused_before_any_write(self) -> None:
        self.release["draft"] = True
        with self.assertRaisesRegex(mirror.Refusal, "not a published release"):
            self.run_mirror()
        self.release = None
        with self.assertRaisesRegex(mirror.Refusal, "no published engine-v1 release"):
            self.run_mirror()
        self.assertEqual(self.store, {})

    def test_an_asset_unlike_the_lock_is_refused(self) -> None:
        for change, reason in (({"digest": "sha256:" + "0" * 64}, "has digest"), ({"size": 1}, "is 1 bytes"),
                               ({"state": "starter"}, "incomplete upload"), ({"digest": None}, "has digest None")):
            with self.subTest(reason):
                self.release["assets"][0] = {**self.release["assets"][0], **change}
                with self.assertRaisesRegex(mirror.Refusal, reason):
                    self.run_mirror()
                self.setUp()
        self.assertEqual(self.store, {})

    def test_downloaded_bytes_unlike_the_digest_are_refused(self) -> None:
        self.downloaded = b"something else"
        with self.assertRaisesRegex(mirror.Refusal, "downloaded as"):
            self.run_mirror()
        self.assertEqual(self.store, {})

    def test_other_bytes_already_stored_are_never_replaced(self) -> None:
        self.store[artifact().key] = b"older bytes"
        with self.assertRaisesRegex(mirror.Refusal, "already holds other bytes"):
            self.run_mirror()
        self.assertEqual(self.store[artifact().key], b"older bytes")

    def test_a_concurrent_write_is_read_back_after_the_412(self) -> None:
        endpoint = FakeEndpoint(self.store)
        endpoint.race = DATA
        self.run_mirror(endpoint)
        endpoint = FakeEndpoint({})
        endpoint.race = b"other"
        with self.assertRaisesRegex(mirror.Refusal, "already holds other bytes"):
            self.run_mirror(endpoint)

    def test_a_file_stored_but_not_served_fails(self) -> None:
        self.served = {}
        with self.assertRaisesRegex(mirror.Refusal, "does not serve installer-v1.tar.gz"):
            self.run_mirror()

    def test_the_engine_is_the_locks(self) -> None:
        lock = json.loads(mirror.catalog_release.SOURCE_LOCK.read_text())
        engine = mirror.pinned_engine()
        self.assertEqual((engine.tag, engine.file_name, engine.size, engine.sha256),
                         (f"engine-{lock['downstream_overlay']['version']}", lock["validation_artifact"]["filename"],
                          lock["validation_artifact"]["size_bytes"], lock["validation_artifact"]["sha256"]))
        self.assertEqual(engine.key, f"{mirror.base_prefix()}engine/{lock['downstream_overlay']['version']}/{engine.file_name}")


if __name__ == "__main__":
    unittest.main()
