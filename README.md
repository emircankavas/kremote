# KRemote

A native macOS multi-protocol remote connection client, with a connection tree,
folders with attribute inheritance, tabbed sessions and direct import of
`confCons.xml` files produced by [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG).

**Status:** very early — Faz 0 (UI skeleton). No protocol is implemented yet.

## Scope

- **v1:** SSH sessions, connection tree, `confCons.xml` import, Keychain-stored secrets.
- **Later:** SFTP, Telnet, port forwarding, HTTP/HTTPS, VNC, RDP.

## Stack

- Swift 6 + SwiftUI, macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) — terminal emulation
- No `.xcodeproj` in git; `project.yml` is the source of truth.

## Build

```bash
brew install xcodegen
xcodegen generate
open KRemote.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project KRemote.xcodeproj -scheme KRemote \
  -configuration Debug -destination 'platform=macOS' build
```

CI (`.github/workflows/ci.yml`) builds on `macos-15` and uploads an unsigned
`.app` zip as a workflow artifact.

## License

MIT — see [LICENSE](LICENSE).

`confCons.xml` is a format defined by the mRemoteNG project (GPL-2.0). KRemote
implements the format independently from observation of files it produces, and
does not include any code or assets from mRemoteNG.
