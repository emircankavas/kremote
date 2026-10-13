# KRemote

A native macOS multi-protocol remote connection client, with a connection tree,
folders with attribute inheritance, tabbed sessions and direct import of
`confCons.xml` files produced by [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG).

**Status:** early — Faz 4 (editor & UX). SSH is the only implemented protocol.

## Editor & UX

- **Connection editor** (⌘E, or right-click ▸ Edit): name, host, port, username,
  protocol, **identity file** (`ssh -i`), Keychain password and an optional
  **remote command**. Every field inherits from the parent folder when left blank;
  the resolved value shows as the field's placeholder.
- **Search** the tree from the sidebar field — matches name, host, username and
  protocol, showing each hit's folder path.
- **Drag & drop** to move connections and folders between folders (cycles refused).
- **Tabs stay live**: switching tabs does not drop a session — every open session
  keeps its ssh process. Right-click a connection for **Open in New Tab**.
- **Reconnect** button appears when a session drops; the tab title follows the
  remote shell's `OSC 0/2` title when it sets one.
- Typing `exit` (or any clean shell exit) **closes the tab**; a failed connection
  keeps the tab open so the reason stays visible.
- **Folders carry defaults for their children**: username, protocol, port,
  identity file, password and remote command. A field left blank is inherited;
  if nothing in the chain sets a port, the protocol decides it (443 for HTTPS,
  3389 for RDP, 22 for SSH…). Host is meaningfully per-connection, so it stays on
  the connection (a blank host inherits the folder's, but that is rarely useful).
- Only **SSH** connections can be opened; imported RDP/HTTPS/Telnet/VNC rows are
  stored and shown but open an "unsupported protocol" notice.



## SSH sessions

Double-click a connection (or right-click ▸ Open) to open a tab with a live
interactive shell.

- Transport: the **system `ssh` (OpenSSH) run on a PTY** (`forkpty`), not a
  Swift SSH library. Terminal: SwiftTerm's `TerminalView`.
- This is deliberate. OpenSSH already speaks every method a corporate server
  may demand — `~/.ssh/config`, key files, `ssh-agent`, GSSAPI/Kerberos SSO,
  keyboard-interactive, ProxyJump, ControlMaster. Pure-Swift stacks (NIOSSH /
  Citadel) implement only publickey + password and cannot reach the rest, which
  fails against hosts that rely on them. mRemoteNXT and Royal TSX both do it
  this way.
- Authentication therefore behaves exactly like your Terminal.app: keys, agent
  and config "just work". If no key succeeds, a stored password is typed into
  the PTY when ssh prompts (never into argv — argv is visible in `ps`).
- Host-key trust is OpenSSH's own `~/.ssh/known_hosts`
  (`StrictHostKeyChecking=accept-new`).


## mRemoteNG import

`File ▸ Import mRemoteNG confCons.xml…` (⇧⌘I) reads an mRemoteNG connection file
into the tree, appending the imported folders and connections to the root, and
pushes each decrypted password straight into the Keychain.

- Schema 2.6, `EncryptionEngine="AES"` / `BlockCipherMode="GCM"`.
- Passwords: `PBKDF2-HMAC-SHA1(passphrase, salt, KdfIterations)` → AES-256-GCM,
  blob layout `salt(16) ‖ nonce(16) ‖ ciphertext ‖ tag(16)`, salt as AAD.
- Default passphrase `mR3m` is tried first; if the file was saved with a custom
  master password the app prompts for it. `Protected` is opened to verify the
  passphrase before any node is touched.
- `FullFileEncryption="true"` and non-GCM ciphers are rejected with a clear error.
- `ConfConsSerializer` writes the tree back out as a readable confCons.xml
  (the importer round-trips it; only the attributes needed to rebuild the tree
  are emitted).

The format is implemented independently from observation of real files and the
publicly documented scheme; no mRemoteNG code or assets are used.

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
Packages/KRemoteCore/  local SwiftPM package: tree model, inheritance, JSON store,
                       Keychain, mRemoteNG crypto/import, Citadel SSH session  (unit-tested)
Sources/KRemote/       SwiftUI app: sidebar, tabs, editor sheet, SwiftTerm host
```

## Scope

- **v1:** SSH sessions, connection tree, `confCons.xml` import, Keychain-stored secrets.
- **Later:** SFTP, Telnet, port forwarding, HTTP/HTTPS, VNC, RDP.

## Stack

- Swift 6 + SwiftUI, macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) — terminal emulation
- SSH is the system `ssh`; no SSH library is linked.
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
