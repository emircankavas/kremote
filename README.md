# KRemote

A native macOS multi-protocol remote connection client, with a connection tree,
folders with attribute inheritance, tabbed sessions and direct import of
`confCons.xml` files produced by [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG).

**Status:** early — Faz 1 (connection tree, persistence, editor). No protocol is implemented yet.

## Data & secrets

- The tree is stored as JSON at
  `~/Library/Application Support/KRemote/tree.json`.
- Passwords live in the **macOS Keychain** (one generic-password item per node).
  They are never written to the JSON file — the node's `password` field is
  deliberately excluded from `CodingKeys`, and a unit test asserts it stays out.
- Per-node values are *directly set*; a blank field (or port `0`) means
  **inherit from the parent folder**, resolved by `EffectiveConnection`.

## Layout

```
Sources/KRemoteCore/   tree model, inheritance, JSON store, Keychain  (unit-tested)
Sources/KRemote/       SwiftUI app: sidebar, tabs, editor sheet
Tests/KRemoteCoreTests/
```

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
