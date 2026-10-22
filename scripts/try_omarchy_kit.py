#!/usr/bin/env python3
"""The Try Omarchy kit the trial runs, and the client library from the same release.

Packaging/try-omarchy-kit.json pins both (docs/try.md):

  client  the TryOmarchyKitClient sources vendored in Vendor/, by revision and digest
  kit     TryOmarchyKit.zip from that revision's GitHub release, by URL, size and
          digest, with the version and run-mode protocol its TryOmarchyKit.json
          declares, or null while no release carries a kit; the app then has no trial

  try_omarchy_kit.py check [--online]
  try_omarchy_kit.py vendor --source TRY_OMARCHY_CHECKOUT [--release vX.Y.Z]
  try_omarchy_kit.py fetch --cache DIR

`check` verifies the vendored client against the pin, and that a pinned kit
comes from the client's revision, is a release and speaks the client's
protocol. `--online` also checks the release tag and its TryOmarchyKit.json.
`fetch` prints the verified kit archive's path, or nothing when no kit is pinned.
OMARCHY_TRY_KIT_ZIP names a local archive instead, checked against the digest
in its .sha256 file beside it; developer builds use it to embed an unreleased kit.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / "Packaging/try-omarchy-kit.json"
VENDOR = ROOT / "Vendor/TryOmarchyKitClient"
REPOSITORY = "omacom/try-omarchy"
CLIENT_PATH = "macos/Sources/TryOmarchyKitClient"
KIT_NAME = "TryOmarchyKit.zip"
MANIFEST_NAME = "TryOmarchyKit.json"
PROTOCOL_SOURCE = "VMRunProtocol.swift"
DIGEST = re.compile(r"^[0-9a-f]{64}$")
RELEASE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
REVISION = re.compile(r"^[0-9a-f]{40}$")


def client_digest(directory: Path) -> str:
    """Names and contents of the client's Swift files, in name order."""
    digest = hashlib.sha256()
    files = sorted(directory.glob("*.swift"))
    if not files:
        raise ValueError(f"no client sources in {directory}")
    for path in files:
        content = path.read_bytes()
        digest.update(path.name.encode() + b"\0" + str(len(content)).encode() + b"\0" + content)
    return digest.hexdigest()


def kit_url(release: str, name: str = KIT_NAME) -> str:
    return f"https://github.com/{REPOSITORY}/releases/download/{release}/{name}"


def protocol_version(directory: Path) -> int:
    """The client's VMRunProtocol.version, which a kit's helper must speak."""
    found = re.findall(r"^    public static let version = ([1-9][0-9]*)$",
                       (directory / PROTOCOL_SOURCE).read_text(), re.M)
    if len(found) != 1:
        raise ValueError(f"cannot find VMRunProtocol.version in {directory / PROTOCOL_SOURCE}")
    return int(found[0])


def is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def kit_manifest(value: object, release: str) -> dict:
    """The fields of a release's TryOmarchyKit.json the pin records."""
    if (not isinstance(value, dict) or value.get("format") != 1 or isinstance(value.get("format"), bool)
            or not is_count(value.get("runProtocolVersion"))):
        raise ValueError(f"{release}'s {MANIFEST_NAME} is invalid")
    if value.get("version") != release:
        raise ValueError(f"{release}'s kit declares version {value.get('version')!r}, not {release}")
    return {"version": value["version"], "runProtocolVersion": value["runProtocolVersion"]}


def load_pin(path: Path = PIN) -> dict:
    pin = json.loads(path.read_text())
    if set(pin) != {"format", "client", "kit"} or pin["format"] != 1:
        raise ValueError("the kit pin has an unknown format")
    client = pin["client"]
    if (set(client) != {"repository", "revision", "path", "sha256"} or client["repository"] != REPOSITORY
            or client["path"] != CLIENT_PATH or not REVISION.match(client["revision"])
            or not DIGEST.match(client["sha256"])):
        raise ValueError("the kit pin's client is invalid")
    kit = pin["kit"]
    if kit is not None:
        if (set(kit) != {"release", "revision", "url", "bytes", "sha256", "version", "runProtocolVersion"}
                or not RELEASE.match(kit["release"]) or not REVISION.match(kit["revision"])
                or kit["url"] != kit_url(kit["release"]) or not is_count(kit["bytes"])
                or not DIGEST.match(kit["sha256"]) or not is_count(kit["runProtocolVersion"])):
            raise ValueError("the kit pin's kit is invalid")
        # A development kit is built from no release; only a release is pinned.
        if kit["version"] != kit["release"]:
            raise ValueError(f"the pinned kit's version {kit['version']!r} is not its release {kit['release']}")
    return pin


def check(root: Path = ROOT) -> dict:
    pin = load_pin(root / "Packaging/try-omarchy-kit.json")
    vendored = root / "Vendor/TryOmarchyKitClient"
    if client_digest(vendored) != pin["client"]["sha256"]:
        raise ValueError("Vendor/TryOmarchyKitClient differs from the pinned client; run vendor again")
    kit = pin["kit"]
    if kit is not None:
        if kit["revision"] != pin["client"]["revision"]:
            raise ValueError(f"the kit ({kit['release']}) and the client come from different revisions")
        if kit["runProtocolVersion"] != protocol_version(vendored):
            raise ValueError(f"the kit speaks run-mode protocol {kit['runProtocolVersion']}, "
                             f"the client {protocol_version(vendored)}")
    return pin


def tag_revision(release: str) -> str:
    """The commit the release's tag names on GitHub."""
    lines = subprocess.check_output(
        ["git", "ls-remote", f"https://github.com/{REPOSITORY}.git", f"refs/tags/{release}",
         f"refs/tags/{release}^{{}}"], text=True).split("\n")
    names = dict(reversed(line.split("\t")) for line in lines if line)
    revision = names.get(f"refs/tags/{release}^{{}}", names.get(f"refs/tags/{release}", ""))
    if not REVISION.match(revision):
        raise ValueError(f"{REPOSITORY} has no tag {release}")
    return revision


def check_online(root: Path = ROOT) -> dict:
    """check, and that the pinned release still says what the pin recorded."""
    pin = check(root)
    kit = pin["kit"]
    if kit is not None:
        if tag_revision(kit["release"]) != kit["revision"]:
            raise ValueError(f"{kit['release']} no longer names {kit['revision']}")
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / MANIFEST_NAME
            download(kit_url(kit["release"], MANIFEST_NAME), manifest)
            published = kit_manifest(json.loads(manifest.read_text()), kit["release"])
        if published != {"version": kit["version"], "runProtocolVersion": kit["runProtocolVersion"]}:
            raise ValueError(f"{kit['release']}'s {MANIFEST_NAME} differs from the pin")
    return pin


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)


def git(source: Path, *arguments: str) -> str:
    return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()


def vendor(source: Path, release: str | None, root: Path = ROOT) -> dict:
    if git(source, "status", "--porcelain", "--", CLIENT_PATH):
        raise ValueError(f"{CLIENT_PATH} has uncommitted changes in {source}")
    revision = git(source, "rev-parse", "HEAD")
    kit = None
    if release is not None:
        if not RELEASE.match(release):
            raise ValueError("the release must be vX.Y.Z")
        if git(source, "rev-parse", f"refs/tags/{release}^{{commit}}") != revision:
            raise ValueError(f"{source} is not at {release}")
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / KIT_NAME
            download(kit_url(release), archive)
            sidecar = Path(directory) / f"{KIT_NAME}.sha256"
            download(kit_url(release) + ".sha256", sidecar)
            recorded = sidecar.read_text().split()[0]
            actual = file_digest(archive)
            if recorded != actual:
                raise ValueError(f"{release}'s kit does not match its published digest")
            manifest = Path(directory) / MANIFEST_NAME
            download(kit_url(release, MANIFEST_NAME), manifest)
            declared = kit_manifest(json.loads(manifest.read_text()), release)
            if declared["runProtocolVersion"] != protocol_version(source / CLIENT_PATH):
                raise ValueError(f"{release}'s kit speaks run-mode protocol {declared['runProtocolVersion']}, "
                                 f"its client {protocol_version(source / CLIENT_PATH)}")
            kit = {"release": release, "revision": revision, "url": kit_url(release),
                   "bytes": archive.stat().st_size, "sha256": actual, **declared}
    target = root / "Vendor/TryOmarchyKitClient"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    for path in sorted((source / CLIENT_PATH).glob("*.swift")):
        shutil.copyfile(path, target / path.name)
    pin = {
        "format": 1,
        "client": {"repository": REPOSITORY, "revision": revision, "path": CLIENT_PATH,
                   "sha256": client_digest(target)},
        "kit": kit,
    }
    (root / "Packaging/try-omarchy-kit.json").write_text(json.dumps(pin, indent=2) + "\n")
    return pin


def fetch(cache: Path, root: Path = ROOT, environment: dict[str, str] = os.environ) -> Path | None:
    pin = check(root)
    local = environment.get("OMARCHY_TRY_KIT_ZIP", "")
    if local:
        archive = Path(local).resolve()
        recorded = Path(f"{archive}.sha256").read_text().split()[0]
        if not DIGEST.match(recorded) or file_digest(archive) != recorded:
            raise ValueError(f"{archive} does not match the digest beside it")
        return archive
    kit = pin["kit"]
    if kit is None:
        return None
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"{kit['sha256']}.zip"
    if not archive.is_file() or file_digest(archive) != kit["sha256"]:
        partial = cache / f"{kit['sha256']}.zip.partial"
        download(kit["url"], partial)
        if partial.stat().st_size != kit["bytes"] or file_digest(partial) != kit["sha256"]:
            partial.unlink()
            raise ValueError(f"the kit from {kit['url']} does not match its pin")
        partial.replace(archive)
    return archive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    check_command = commands.add_parser("check")
    check_command.add_argument("--online", action="store_true")
    vendor_command = commands.add_parser("vendor")
    vendor_command.add_argument("--source", type=Path, required=True)
    vendor_command.add_argument("--release")
    fetch_command = commands.add_parser("fetch")
    fetch_command.add_argument("--cache", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "check":
            pin = check_online() if arguments.online else check()
            kit = pin["kit"]
            print(f"kit pin: client {pin['client']['revision'][:12]}, "
                  + (f"kit {kit['release']}, run-mode protocol {kit['runProtocolVersion']}" if kit else "no kit"))
        elif arguments.command == "vendor":
            pin = vendor(arguments.source.resolve(), arguments.release)
            print(json.dumps(pin, indent=2))
        else:
            archive = fetch(arguments.cache)
            if archive is not None:
                print(archive)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"try_omarchy_kit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
