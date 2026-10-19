#!/usr/bin/env python3
"""Publish a KRemote release to the public companion repository.

The source repository is private, so an installed app cannot read its release
API without a token. Everything the app *does* read lives in the public
`emircan/kremote-releases` repository:

  releases/tag/<tag>                       the release page + assets
  raw/branch/main/appcast-<channel>.json    what UpdateChecker fetches

Usage:
  publish-release.py --tag v1.8.0-beta.1 --version 1.8.0-beta.1 \
      --channel beta --notes RELEASE_NOTES.md \
      --dmg KRemote-1.8.0-beta.1.dmg --zip KRemote-1.8.0-beta.1.zip

Idempotent: an existing release for the tag is reused and existing assets are
replaced, so a re-run after a partial failure converges instead of duplicating.
"""

import argparse
import base64
import datetime
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

SERVER = os.environ.get("FORGEJO_SERVER", "https://forgejo.kavas.dev")
REPO = os.environ.get("RELEASES_REPO", "emircan/kremote-releases")
API = f"{SERVER}/api/v1/repos/{REPO}"


def log(message):
    print(message, flush=True)


class Client:
    def __init__(self, token):
        self.token = token

    def request(self, method, path, *, body=None, data=None, headers=None,
                raw=False, allow=(200, 201, 202)):
        url = path if path.startswith("http") else API + path
        hdrs = {"Authorization": f"token {self.token}"}
        if body is not None:
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req) as response:
                payload = response.read()
                return response.status, (payload if raw else _decode(payload))
        except urllib.error.HTTPError as error:
            payload = error.read()
            if error.code in allow:
                return error.code, (payload if raw else _decode(payload))
            raise RuntimeError(f"{method} {url} -> {error.code}: {payload[:400]!r}") from None


def _decode(payload) -> Any:
    if not payload:
        return None
    try:
        return json.loads(payload)
    except ValueError:
        return payload.decode(errors="replace")


def multipart(field, filename, content):
    """A minimal multipart/form-data body for the single-file upload endpoint."""
    boundary = "----KRemoteBoundary" + base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=")
    parts = [
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode(),
        b"Content-Type: application/octet-stream\r\n\r\n",
        content,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def ensure_release(client, tag, prerelease, notes):
    status, existing = client.request("GET", f"/releases/tags/{tag}", allow=(200, 404))
    if status == 200 and isinstance(existing, dict) and existing.get("id"):
        release_id = existing["id"]
        log(f"release {tag} exists (id={release_id})")
        # Keep the body in sync with the repo's notes, and the flag correct.
        client.request("PATCH", f"/releases/{release_id}", body={
            "name": f"KRemote {tag}",
            "body": notes,
            "prerelease": prerelease,
        })
        return release_id, existing

    body = {
        "tag_name": tag,
        "name": f"KRemote {tag}",
        "body": notes,
        "prerelease": prerelease,
        "target_commitish": "main",
    }
    status, created = client.request("POST", "/releases", body=body)
    log(f"created release {tag} (id={created['id']})")
    return created["id"], created


def upload_asset(client, release, tag, path):
    name = os.path.basename(path)
    if not os.path.isfile(path):
        raise SystemExit(f"missing asset: {path}")
    size = os.path.getsize(path)
    if size == 0:
        raise SystemExit(f"asset is empty: {path}")

    # Replace a stale upload of the same name so a re-run does not 409.
    for asset in release.get("assets") or []:
        if asset.get("name") == name:
            client.request("DELETE", f"/releases/{release['id']}/assets/{asset['id']}", allow=(204, 200, 404))
            log(f"removed stale asset {name}")

    with open(path, "rb") as handle:
        content = handle.read()
    body, content_type = multipart("attachment", name, content)
    client.request(
        "POST",
        f"/releases/{release['id']}/assets?name={name}",
        data=body,
        headers={"Content-Type": content_type},
    )
    log(f"uploaded {name} ({size / 1048576:.1f} MiB)")


def write_appcast(client, channel, version, tag, prerelease, notes, base):
    document = {
        "version": version,
        "tag": tag,
        "name": f"KRemote {version}",
        "notes": notes,
        "page": f"{SERVER}/{REPO}/releases/tag/{tag}",
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "prerelease": prerelease,
        "channel": channel,
        "assets": {
            "dmg": f"{base}/KRemote-{version}.dmg",
            "zip": f"{base}/KRemote-{version}.zip",
        },
    }
    path = f"appcast-{channel}.json"
    encoded = base64.b64encode((json.dumps(document, indent=2) + "\n").encode()).decode()

    status, existing = client.request("GET", f"/contents/{path}", allow=(200, 404))
    sha = existing.get("sha") if status == 200 and isinstance(existing, dict) else None
    payload = {"content": encoded, "message": f"release: {tag}", "branch": "main"}
    if sha:
        payload["sha"] = sha
        client.request("PUT", f"/contents/{path}", body=payload)
    else:
        client.request("POST", f"/contents/{path}", body=payload)
    log(f"appcast {path} updated")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", required=True, choices=["stable", "beta"])
    parser.add_argument("--notes", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--zip", required=True)
    args = parser.parse_args()

    token = os.environ.get("FORGEJO_TOKEN", "")
    if not token:
        raise SystemExit("FORGEJO_TOKEN is not set")

    with open(args.notes, encoding="utf-8") as handle:
        notes = handle.read()

    prerelease = args.channel == "beta"
    client = Client(token)
    release_id, release = ensure_release(client, args.tag, prerelease, notes)
    release: dict = dict(release or {})
    release["id"] = release_id

    upload_asset(client, release, args.tag, args.dmg)
    upload_asset(client, release, args.tag, args.zip)

    base = f"{SERVER}/{REPO}/releases/download/{args.tag}"
    if args.channel == "stable":
        write_appcast(client, "stable", args.version, args.tag, False, notes, base)
        # Beta users should also be offered the finished release.
        write_appcast(client, "beta", args.version, args.tag, False, notes, base)
    else:
        write_appcast(client, "beta", args.version, args.tag, True, notes, base)

    log(f"published {args.tag} on the {args.channel} channel")


if __name__ == "__main__":
    sys.exit(main())
