# Third-party notices

KRemote itself is MIT (see [LICENSE](LICENSE)). The app bundles the following
libraries; all of them are permissively licensed, which is why FreeRDP is built
from source for releases instead of taking Homebrew's copy (whose ffmpeg
dependency is GPL-3.0).

## Bundled in the macOS app (`Contents/Frameworks/`)

| Library | Version | License | Source |
|---|---|---|---|
| FreeRDP (`libfreerdp3`, `libfreerdp-client3`) | 3.32.2 | Apache-2.0 | https://github.com/FreeRDP/FreeRDP |
| WinPR (`libwinpr3`) | 3.32.2 | Apache-2.0 | https://github.com/FreeRDP/FreeRDP |
| OpenSSL (`libssl`, `libcrypto`) | 4.x | Apache-2.0 | https://www.openssl.org/ |
| OpenH264 (`libopenh264`) | 2.6.0 | BSD-2-Clause | https://github.com/cisco/openh264 |
| Jansson (`libjansson`) | 2.15 | MIT | https://github.com/akheron/jansson |

FreeRDP is built with the flags in [`scripts/build-freerdp.sh`](scripts/build-freerdp.sh):

- `WITH_FFMPEG=OFF`, `WITH_SWSCALE=OFF` — ffmpeg is GPL-3.0 and is never linked.
  H.264 (AVC420) decoding is provided by OpenH264; AVC444 is unavailable without
  ffmpeg.
- `WITH_X11=OFF`, `WITH_WAYLAND=OFF`, `WITH_CLIENT_SDL=OFF` — KRemote renders in
  AppKit, so no X11 or SDL stack is pulled in.
- `WITH_PCSC=OFF`, `CHANNEL_URBDRC=OFF` — smartcard and USB redirection are not
  exposed, which removes libfido2, libcbor and USB dependencies.

## Linked via SwiftPM (built from source into the app)

| Library | License | Source |
|---|---|---|
| SwiftTerm | MIT | https://github.com/migueldeicaza/SwiftTerm |
| swift-crypto | Apache-2.0 | https://github.com/apple/swift-crypto |

## Not distributed

`confCons.xml` is a format defined by the mRemoteNG project (GPL-2.0). KRemote
implements the format independently from observation of files it produces; no
mRemoteNG code, assets or icon set is included.
