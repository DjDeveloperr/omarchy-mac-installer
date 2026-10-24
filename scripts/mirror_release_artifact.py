#!/usr/bin/env python3
"""Copy a published release artifact from this repository's GitHub releases to
R2, written once and never replaced.

  mirror_release_artifact.py engine

`engine` is the engine Engine/source-lock.json pins (`validation_artifact`),
from its published `engine-<version>` release, to
`<catalog base>/engine/<version>/<file>` (INSTALLER_CATALOG_BASE, so
https://mac.omarchy.org/v1/engine/...). The release must be published, not a
draft, and its asset's size and GitHub-computed sha256 must be the lock's; the
downloaded bytes must match too. An object already at the key with the same
bytes is left alone (a re-run, or a bucket lock), and different bytes refuse.
The file is then read back through the public URL.

This is how the x86 side publishes a released ISO: once, next to its checksum,
never replaced. The GitHub release stays: catalogs already signed pin it.

Credentials: R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and the
bucket from R2_BUCKET (default omarchy-mac); GH_TOKEN reads the release.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_release  # noqa: E402
import r2_s3  # noqa: E402

Refusal = catalog_release.Refusal
READ_BLOCK_BYTES = 8 * 1024 * 1024
IMMUTABLE = "public, max-age=31536000, immutable"
# Cloudflare can keep a 404 for three minutes when the URL was asked for
# before the upload, so the readback waits about five.
PUBLIC_DELAYS = (5, 10, 15, 30, 30, 30, 60, 60, 60)


class Artifact:
    """One file to mirror: what it must be, where it comes from and goes."""

    def __init__(self, *, tag: str, file_name: str, size: int, sha256: str, key: str, content_type: str):
        self.tag = tag
        self.file_name = file_name
        self.size = size
        self.sha256 = sha256
        self.key = key
        self.content_type = content_type


def pinned_engine() -> Artifact:
    lock = json.loads(catalog_release.SOURCE_LOCK.read_text())
    version = lock["downstream_overlay"]["version"]
    artifact = lock["validation_artifact"]
    if not catalog_release.ENGINE_VERSION.match(version):
        raise Refusal(f"the lock names no engine version: {version}")
    return Artifact(tag=f"engine-{version}", file_name=artifact["filename"], size=artifact["size_bytes"],
                    sha256=artifact["sha256"], key=f"{base_prefix()}engine/{version}/{artifact['filename']}",
                    content_type="application/gzip")


def base_prefix() -> str:
    """The catalog base's path in the bucket, e.g. 'v1/'."""
    path = urllib.parse.urlsplit(catalog_release.identity()["INSTALLER_CATALOG_BASE"]).path.strip("/")
    if not path:
        raise Refusal("INSTALLER_CATALOG_BASE has no path to hold artifacts under")
    return path + "/"


def public_url(key: str) -> str:
    base = catalog_release.identity()["INSTALLER_CATALOG_BASE"].rstrip("/")
    return base + "/" + key[len(base_prefix()):]


def github_json(url: str, token: str) -> dict:
    request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                                   "X-GitHub-Api-Version": "2022-11-28"})
    request.add_unredirected_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read())


def release_asset(artifact: Artifact, repo: str, token: str) -> dict:
    """The published release's asset, checked against what it must be."""
    try:
        release = github_json(f"https://api.github.com/repos/{repo}/releases/tags/{urllib.parse.quote(artifact.tag)}", token)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise Refusal(f"{repo} has no published {artifact.tag} release") from None
        raise
    if release.get("draft") or release.get("tag_name") != artifact.tag:
        raise Refusal(f"{artifact.tag} is not a published release")
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == artifact.file_name]
    if len(assets) != 1:
        raise Refusal(f"{artifact.tag} has {len(assets)} assets named {artifact.file_name}, not one")
    asset = assets[0]
    if asset.get("state") != "uploaded":
        raise Refusal(f"{artifact.file_name} on {artifact.tag} is an incomplete upload ({asset.get('state')})")
    if asset.get("size") != artifact.size:
        raise Refusal(f"{artifact.file_name} on {artifact.tag} is {asset.get('size')} bytes, not {artifact.size}")
    if asset.get("digest") != f"sha256:{artifact.sha256}":
        raise Refusal(f"{artifact.file_name} on {artifact.tag} has digest {asset.get('digest')}, not sha256:{artifact.sha256}")
    return asset


def download(url: str, target: Path, artifact: Artifact) -> None:
    value = hashlib.sha256()
    size = 0
    request = urllib.request.Request(url, headers={"User-Agent": "omarchy-mac-mirror"})
    with urllib.request.urlopen(request, timeout=600) as response, target.open("wb") as stream:
        while block := response.read(READ_BLOCK_BYTES):
            value.update(block)
            size += len(block)
            stream.write(block)
    if size != artifact.size or value.hexdigest() != artifact.sha256:
        raise Refusal(f"{url} downloaded as {value.hexdigest()} ({size} bytes), not {artifact.sha256}")


def stored_sha256(endpoint: r2_s3.Endpoint, key: str) -> str | None:
    """The sha256 of the object at KEY, read from R2 itself, or None."""
    try:
        with endpoint.request("GET", key, timeout=600) as response:
            value = hashlib.sha256()
            while block := response.read(READ_BLOCK_BYTES):
                value.update(block)
            return value.hexdigest()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            error.close()
            return None
        raise Refusal(r2_s3.refusal_text(f"read {key}", error)) from None
    except r2_s3.R2Error as error:
        raise Refusal(str(error)) from None


def store(endpoint: r2_s3.Endpoint, artifact: Artifact, path: Path) -> str:
    """Write the file once. Returns 'stored' or 'already stored'."""
    def same_or_refuse(found: str) -> str:
        if found != artifact.sha256:
            raise Refusal(f"r2://{endpoint.bucket}/{artifact.key} already holds other bytes ({found}); refusing to replace it")
        return "already stored"

    found = stored_sha256(endpoint, artifact.key)
    if found is not None:
        return same_or_refuse(found)
    headers = {"Cache-Control": IMMUTABLE, "Content-Type": artifact.content_type, "If-None-Match": "*"}
    try:
        with path.open("rb") as stream, endpoint.request("PUT", artifact.key, headers=headers, body=stream,
                                                         size=artifact.size, payload_sha256=artifact.sha256) as response:
            response.read()
    except urllib.error.HTTPError as error:
        if error.code == 412:
            error.close()
            # Written meanwhile: by another run, or by this PUT before a retry.
            found = stored_sha256(endpoint, artifact.key)
            return same_or_refuse(found or "nothing")
        raise Refusal(r2_s3.refusal_text(f"store {artifact.key}", error)) from None
    except r2_s3.R2Error as error:
        raise Refusal(str(error)) from None
    return "stored"


def check_served(url: str, artifact: Artifact) -> None:
    for attempt, delay in enumerate((0, *PUBLIC_DELAYS)):
        if delay:
            time.sleep(delay)
        value = hashlib.sha256()
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "omarchy-mac-mirror"})
            with urllib.request.urlopen(request, timeout=120) as response:
                while block := response.read(READ_BLOCK_BYTES):
                    value.update(block)
        except urllib.error.HTTPError as error:
            error.close()
            found = f"HTTP {error.code}"
        except (urllib.error.URLError, OSError) as error:
            found = f"no answer ({type(getattr(error, 'reason', error)).__name__})"
        else:
            if value.hexdigest() == artifact.sha256:
                return
            found = f"sha256 {value.hexdigest()}"
        print(f"  {url}: {found} (attempt {attempt + 1})", file=sys.stderr)
    raise Refusal(f"{url} does not serve {artifact.file_name} ({artifact.sha256})")


def mirror(artifact: Artifact, endpoint: r2_s3.Endpoint, repo: str, token: str) -> str:
    asset = release_asset(artifact, repo, token)
    with tempfile.TemporaryDirectory(prefix="mac-mirror-") as directory:
        path = Path(directory) / artifact.file_name
        download(asset["browser_download_url"], path, artifact)
        outcome = store(endpoint, artifact, path)
    url = public_url(artifact.key)
    check_served(url, artifact)
    print(f"{outcome} r2://{endpoint.bucket}/{artifact.key}")
    print(f"url={url}")
    return url


def main(argv: list[str]) -> int:
    if argv != ["engine"]:
        print(__doc__.split("\n\n", 2)[1], file=sys.stderr)
        return 64
    try:
        catalog_release.check_repository()
        try:
            endpoint = r2_s3.Endpoint.parse(os.environ.get("R2_BUCKET", "") or "omarchy-mac", os.environ.get("R2_ENDPOINT", ""),
                                            os.environ.get("R2_ACCESS_KEY_ID", ""), os.environ.get("R2_SECRET_ACCESS_KEY", ""))
        except r2_s3.R2Error as error:
            raise Refusal(str(error)) from None
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", "")
        if not token:
            raise Refusal("no GitHub token (GH_TOKEN)")
        mirror(pinned_engine(), endpoint, catalog_release.stopgap_repo(), token)
    except Refusal as refusal:
        print(f"mirror: {refusal}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
