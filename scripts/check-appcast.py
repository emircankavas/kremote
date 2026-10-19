#!/usr/bin/env python3
"""Fail loudly if the published appcast is not what the app expects.

Run by the release workflow after publishing, so a green run means the app will
actually see the release — not merely that a build succeeded.
"""

import json
import sys


def main() -> int:
    path, want = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)

    problems = []
    if doc.get("version") != want:
        problems.append(f"version is {doc.get('version')!r}, expected {want!r}")
    assets = doc.get("assets") or {}
    for kind in ("zip", "dmg"):
        url = assets.get(kind)
        if not isinstance(url, str) or not url.startswith("http"):
            problems.append(f"assets.{kind} is missing or not a URL: {url!r}")
    if not doc.get("notes"):
        problems.append("notes are empty, so the update window would show nothing")
    if not isinstance(doc.get("prerelease"), bool):
        problems.append("prerelease is not a boolean")

    if problems:
        for problem in problems:
            print(f"::error::appcast {problem}")
        return 1
    print(f"appcast OK: {doc['version']} (prerelease={doc['prerelease']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
