#!/usr/bin/env bash
#
# Builds FreeRDP from source as a SMALL, PERMISSIVELY-LICENSED static-ish set of
# dylibs that the release bundle can embed — so end users never need Homebrew.
#
# Why not `brew install freerdp`? Homebrew's bottle hard-depends on ffmpeg, whose
# bottle is GPL-3.0-or-later. Embedding it would make KRemote (MIT) effectively
# GPL-3.0. This build disables ffmpeg and uses OpenH264 (BSD-2-Clause) for H.264
# instead, so everything embedded is permissive:
#
#   FreeRDP / WinPR        Apache-2.0
#   OpenSSL                Apache-2.0
#   OpenH264               BSD-2-Clause
#   jansson / uriparser    MIT / BSD-3-Clause
#   libjpeg-turbo          IJG AND Zlib AND BSD-3-Clause
#
# What is intentionally OFF, and why it shrinks the bundle:
#   - X11 / Wayland / SDL  -> no libX*/sdl3 dependency at all (we draw in AppKit)
#   - FFMPEG               -> GPL-3.0; AVC444 is unavailable without it, AVC420
#                             still works through OpenH264
#   - PCSC / URBDRC        -> drops libfido2, libcbor and LGPL libusb; smartcard
#                             and USB redirection are not features we expose
#   - KRB5                 -> keeps the dependency set small; NLA still works via
#                             NTLM over OpenSSL
#
# Output: $PREFIX/{lib,include} plus $PREFIX/lib/pkgconfig, ready to link.
#
# Usage: scripts/build-freerdp.sh [install-prefix]
set -euo pipefail

FREERDP_VERSION="${FREERDP_VERSION:-3.32.2}"
PREFIX="${1:-$HOME/hermes-build/freerdp-install}"
WORK="${FREERDP_BUILD_WORK:-$HOME/hermes-build/freerdp-build}"
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

export PATH="$BREW_PREFIX/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1

# Build tools (build-time only; the app does not need them).
for tool in cmake ninja pkg-config git; do
    command -v "$tool" >/dev/null || {
        echo "Missing build tool: $tool. Install with: brew install cmake ninja pkgconf" >&2
        exit 1
    }
done
# Runtime dependencies we link against.
for dep in openssl@4 openh264 jansson uriparser jpeg-turbo; do
    [ -d "$BREW_PREFIX/opt/$dep" ] || {
        echo "Missing dependency: $dep. Install with: brew install $dep" >&2
        exit 1
    }
done

mkdir -p "$WORK"
cd "$WORK"

# Mirrored on the self-hosted Forgejo: no GitHub dependency in the build. Forgejo
# unpacks the archive as `freerdp/` (GitHub's endpoint used `FreeRDP-<version>/`),
# so the extracted directory is located by name rather than assumed.
FREERDP_MIRROR="${FREERDP_MIRROR:-https://forgejo.kavas.dev/emircan/FreeRDP}"
SRC="$WORK/FreeRDP-src-$FREERDP_VERSION"
if [ ! -d "$SRC" ]; then
    echo "==> Fetching FreeRDP $FREERDP_VERSION from $FREERDP_MIRROR"
    rm -rf "$SRC" "$WORK/.unpack"
    mkdir -p "$WORK/.unpack"
    curl -fsSL -o "$WORK/freerdp-$FREERDP_VERSION.tar.gz" \
        "$FREERDP_MIRROR/archive/refs/tags/$FREERDP_VERSION.tar.gz"
    tar xzf "$WORK/freerdp-$FREERDP_VERSION.tar.gz" -C "$WORK/.unpack"
    # The archive holds exactly one top-level directory, whatever it is called.
    inner="$(find "$WORK/.unpack" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -n "$inner" ] || { echo "Archive had no top-level directory" >&2; exit 1; }
    mv "$inner" "$SRC"
    rm -rf "$WORK/.unpack"
fi

BUILD="$WORK/build"
mkdir -p "$BUILD"

export PKG_CONFIG_PATH="$BREW_PREFIX/opt/openssl@4/lib/pkgconfig:$BREW_PREFIX/opt/openh264/lib/pkgconfig:$BREW_PREFIX/opt/jansson/lib/pkgconfig:$BREW_PREFIX/opt/uriparser/lib/pkgconfig:$BREW_PREFIX/opt/jpeg-turbo/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

echo "==> Configuring"
cmake -GNinja -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_VERBOSE_WINPR_ASSERT=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_CLIENT=ON \
    -DWITH_CLIENT_COMMON=ON \
    -DWITH_CLIENT_MAC=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_WEBVIEW=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_DSP_FFMPEG=OFF \
    -DWITH_OPENH264=ON \
    -DWITH_OPENH264_LOADING=OFF \
    -DWITH_JPEG=ON \
    -DWITH_PNG=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_MACAUDIO=ON \
    -DWITH_ALSA=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_GSM=OFF \
    -DWITH_SOXR=OFF \
    -DWITH_REMOTEFX=ON \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_TSMF=OFF \
    -DCHANNEL_RDPEAR=OFF \
    -DWITH_INTERNAL_RC4=ON \
    -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_MD5=ON \
    -DUWAC_INITIAL_CUSTOM_WORKFLOWS=OFF \
    -DCMAKE_IGNORE_PATH="$BREW_PREFIX"

echo "==> Building"
cmake --build "$BUILD" --parallel

echo "==> Installing to $PREFIX"
cmake --install "$BUILD"

echo
echo "==> Installed libraries:"
ls -1 "$PREFIX/lib" | grep -E '\.dylib$' || true
echo
echo "Done. Point KRemote at it with FREERDP_ROOT=$PREFIX"
