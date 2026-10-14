#!/usr/bin/env bash
#
# Embeds the RDP libraries into KRemote.app so end users need nothing installed.
#
# Walks the app binary's dependency tree, copies every non-system dylib into
# Contents/Frameworks/, rewrites each one's install name to @rpath/<name> and
# repoints every reference at it, then re-signs. After this the app only needs
# what macOS itself provides.
#
# Run AFTER xcodebuild, BEFORE packaging the .dmg:
#   scripts/embed-freerdp.sh build/Build/Products/Release/KRemote.app
#
# Usage: embed-freerdp.sh <path-to-KRemote.app> [signing-identity]
set -euo pipefail

APP="${1:?usage: embed-freerdp.sh <KRemote.app> [signing-identity]}"
IDENTITY="${2:--}"

# Where to look for the libraries, in order. FREERDP_ROOT must come FIRST: the
# permissively-licensed build lives there, while Homebrew's FreeRDP links GPL
# ffmpeg and pulls in X11 — embedding that copy would change the app's licence
# and bloat it by tens of megabytes. The builds share install names, so the
# first hit wins.
FREERDP_ROOT="${FREERDP_ROOT:-$HOME/hermes-build/freerdp-install}"

export KR_APP="$APP" KR_IDENTITY="$IDENTITY" KR_FREERDP_ROOT="$FREERDP_ROOT"

/usr/bin/python3 <<'PY'
import os
import shutil
import subprocess
import sys

app = os.environ["KR_APP"]
identity = os.environ["KR_IDENTITY"]
search = [os.environ["KR_FREERDP_ROOT"], "/opt/homebrew", "/usr/local"]

bin_path = os.path.join(app, "Contents", "MacOS", "KRemote")
frameworks = os.path.join(app, "Contents", "Frameworks")

if not os.access(bin_path, os.X_OK):
    sys.exit(f"error: no executable at {bin_path}")

# ffmpeg and X11 must never end up in the bundle: ffmpeg makes the app GPL-3.0,
# and X11 means the wrong FreeRDP build was picked up.
FORBIDDEN = ["libavcodec", "libavutil", "libavformat", "libavfilter",
             "libswscale", "libswresample", "libx264", "libx265",
             "libX11", "libXext", "libXau", "libXdmcp", "libdav1d"]


def run(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def dependencies(lib):
    """Direct dependency paths of a Mach-O file."""
    if lib == bin_path:
        lines = run("otool", "-l", lib).splitlines()
        deps = []
        for i, line in enumerate(lines):
            if "LC_LOAD_DYLIB" in line or "LC_LOAD_WEAK_DYLIB" in line:
                for j in range(i, min(i + 5, len(lines))):
                    s = lines[j].strip()
                    if s.startswith("name "):
                        deps.append(s.split(" ", 1)[1].split(" ")[0])
                        break
        return deps
    return [l.strip().split(" ")[0] for l in run("otool", "-L", lib).splitlines()[1:] if l.strip()]


def is_system(path):
    return path.startswith("/usr/lib/") or path.startswith("/System/")


def resolve(dep, origin):
    """Turn an @rpath/@loader_path entry into a real file path, or None."""
    if not dep.startswith(("@rpath/", "@loader_path/")):
        return os.path.realpath(dep) if os.path.exists(dep) else None
    name = dep.split("/", 1)[1]
    candidates = []
    if not origin.startswith("@"):
        candidates.append(os.path.join(os.path.dirname(os.path.realpath(origin)), name))
    for prefix in search:
        candidates.append(os.path.join(prefix, "lib", name))
        opt = os.path.join(prefix, "opt")
        if os.path.isdir(opt):
            for entry in sorted(os.listdir(opt)):
                candidates.append(os.path.join(opt, entry, "lib", name))
    for candidate in candidates:
        if os.path.exists(candidate):
            return os.path.realpath(candidate)
    return None


# MARK: Collect

print(f"==> Collecting dependencies of {os.path.basename(bin_path)}")

# canonical path -> the bare name it will have inside the bundle
bundled = {}
queue = [bin_path]
visited = set()

while queue:
    lib = queue.pop()
    if lib in visited:
        continue
    visited.add(lib)
    for dep in dependencies(lib):
        if is_system(dep):
            continue
        real = resolve(dep, lib)
        if real is None:
            if dep.startswith("@"):
                print(f"    warning: could not resolve {dep} (from {os.path.basename(lib)})", file=sys.stderr)
            continue
        # Deduplicate on the real file: libopenh264.8.dylib is a symlink to
        # libopenh264.2.6.0.dylib and must not be copied twice.
        if real not in bundled:
            bundled[real] = os.path.basename(real)
            queue.append(real)

if not bundled:
    print("    (nothing to embed)")
    sys.exit(0)

os.makedirs(frameworks, exist_ok=True)


# MARK: Copy

print("==> Copying into Contents/Frameworks/")
for real, name in sorted(bundled.items(), key=lambda kv: kv[1]):
    print(f"    {name}")
    target = os.path.join(frameworks, name)
    shutil.copyfile(real, target)
    os.chmod(target, 0o755)
    run("install_name_tool", "-id", f"@rpath/{name}", target)


# MARK: Rewrite references

print("==> Rewriting references")


def rewrite(target):
    """Repoint every reference to a bundled library at @rpath/<name>."""
    for dep in dependencies(target):
        if is_system(dep):
            continue
        real = resolve(dep, target)
        if real is None:
            continue
        name = bundled.get(real)
        if name is None:
            continue
        wanted = f"@rpath/{name}"
        if dep != wanted:
            run("install_name_tool", "-change", dep, wanted, target)


for name in bundled.values():
    rewrite(os.path.join(frameworks, name))
rewrite(bin_path)


# MARK: Sign

print("==> Re-signing")
for name in bundled.values():
    run("codesign", "--force", "--sign", identity, os.path.join(frameworks, name))
run("codesign", "--force", "--deep", "--sign", identity, app)


# MARK: Verify

print("==> Verifying the bundle is self-contained")
problems = []

for target in [bin_path] + [os.path.join(frameworks, n) for n in bundled.values()]:
    for dep in dependencies(target):
        if dep.startswith(("/opt/homebrew", "/usr/local")):
            problems.append(f"{os.path.basename(target)} still references {dep}")

for forbidden in FORBIDDEN:
    for entry in os.listdir(frameworks):
        if entry.startswith(forbidden) and entry.endswith(".dylib"):
            problems.append(f"forbidden library embedded: {entry} (GPL-3.0 or X11 — wrong FreeRDP build)")

if problems:
    for problem in problems:
        print(f"    {problem}", file=sys.stderr)
    sys.exit("error: bundle is not clean")

size = sum(os.path.getsize(os.path.join(frameworks, n)) for n in bundled.values())
print(f"    OK — self-contained and permissive ({size / 1024 / 1024:.1f} MB of libraries)")
print()
print(f"Done. {len(bundled)} libraries embedded into {frameworks}")
PY
