#!/usr/bin/env python3
"""Generate the exact command the app sends, for a set of awkward script bodies.

The point is to run these against a real macOS and a real Linux shell: a snippet
runner that mangles quotes, heredocs or non-ASCII text is worse than no feature,
because the user's script runs *differently* rather than failing.
"""
import base64
import sys


def command(body: str) -> str:
    encoded = base64.b64encode(body.encode()).decode()
    return "; ".join([
        'f="/tmp/kremote-snippet-$$.sh"',
        f"printf '%s' '{encoded}' | base64 -d > \"$f\"",
        'sh "$f"',
        'rc=$?',
        'rm -f "$f"',
        'exit $rc',
    ])


CASES = {
    "simple": "echo hello",
    "multiline-if": "if [ -d /tmp ]; then\n  echo has-tmp\nelse\n  echo no-tmp\nfi",
    "single-quotes": "echo \"it's fine\"",
    "dollar-and-backtick": "echo \"home=$HOME\"; echo \"user=$(whoami)\"",
    "heredoc": "cat <<EOF\nline one\nline two\nEOF",
    "unicode": "echo 'türkçe ✓'",
    "exit-code": "exit 7",
    "two-args": "echo \"$1-$2\"",
}

if __name__ == "__main__":
    out = []
    for name, body in CASES.items():
        out.append("### " + name)
        out.append(command(body))
    sys.stdout.write("\n".join(out) + "\n")
