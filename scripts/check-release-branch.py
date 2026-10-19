#!/usr/bin/env python3
"""Refuse to release a tag that is on the wrong branch.

A pre-release tag (`v1.8.0-beta.1`) must be an ancestor of `beta`; a stable tag
(`v1.8.0`) must be an ancestor of `main`. Without this, a tag pushed from a
feature branch — or a stable tag cut while beta work is in flight — would
publish a build nobody agreed to ship.

Run by the release workflow. Uses only `git`, so it needs no token.
"""

import re
import subprocess
import sys

PRERELEASE = re.compile(r"-")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def is_ancestor(commit, ref):
    """True when `commit` is an ancestor of (or equal to) `ref`."""
    if git("rev-parse", "--verify", "--quiet", ref).returncode != 0:
        return False
    return git("merge-base", "--is-ancestor", commit, ref).returncode == 0


def main() -> int:
    tag = sys.argv[1] if len(sys.argv) > 1 else ""
    if not tag:
        print("::error::no tag given")
        return 1

    version = tag[1:] if tag.startswith("v") else tag
    expected = "beta" if PRERELEASE.search(version) else "main"

    head = git("rev-parse", "HEAD").stdout.strip()
    if not head:
        print("::error::not a git checkout")
        return 1

    # The tagged commit is HEAD in the workflow's checkout; require it to be
    # reachable from the branch that owns this kind of tag.
    if is_ancestor(head, f"origin/{expected}"):
        print(f"{tag} is on {expected} — OK")
        return 0

    # Fall back to a local branch of the same name (checkout may only fetch the tag).
    if is_ancestor(head, expected):
        print(f"{tag} is on {expected} — OK")
        return 0

    other = "main" if expected == "beta" else "beta"
    if is_ancestor(head, f"origin/{other}"):
        print(
            f"::error::{tag} is a {'pre-release' if expected == 'beta' else 'stable'} "
            f"tag but its commit is on {other}. Push pre-release tags from beta and "
            f"stable tags from main."
        )
        return 1

    print(f"::error::{tag} commit {head[:8]} is on neither main nor beta")
    return 1


if __name__ == "__main__":
    sys.exit(main())
