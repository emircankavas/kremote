# KRemote

A native macOS multi-protocol remote connection client, with a connection tree,
folders with attribute inheritance, tabbed sessions and direct import of
`confCons.xml` files produced by [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG).

**Status:** early — Faz 6 (RDP). SSH is fully implemented; RDP is a first-class
protocol in the tree and editor, with the FreeRDP transport landing next.

## Protocols

- **SSH** — live sessions today (see below).
- **RDP** — modelled, editable and imported today; the FreeRDP-backed pane is the
  next step. A connection's protocol is `RDP` (or an `RDP…` variant) to opt in.
- **VNC / Telnet / HTTP(S)** — stored and shown, but no session yet.

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
- **Folders carry credentials and RDP defaults for their children**: username,
  password, identity file, plus the RDP settings a group of Windows hosts shares
  (domain, resolution, colour depth, redirections). A blank field is inherited
  from the nearest folder that sets it.
- Host, protocol, port and remote command are **per-connection** — a folder
  commonly mixes SSH, RDP and HTTPS children, so a protocol there would be wrong.
  A blank port resolves to the connection's own protocol default (443 for HTTPS,
  3389 for RDP, 22 for SSH…).
- **SSH** and **RDP** connections can be opened; imported RDP/HTTPS/Telnet/VNC
  rows are stored and shown, and the ones with no session yet open an
  "unsupported protocol" notice.
- **Toolbar buttons** (above the tabs): `#` sends `sudo -i` to the focused
  session (it prompts for the password, like any `sudo`); the split button and
  the `2 / 3 / 4` buttons open a **split view** of up to four panes. ⌘D toggles
  split view, and a **Session** menu mirrors it. Each pane picks its session from
  its header menu; the focused pane (accent border) is where the root command and
  keystrokes go.



## SSH sessions

Double-click a connection (or right-click ▸ Open) to open a tab with a live
interactive shell.

- Transport: the **system `ssh` (OpenSSH) run on a PTY** (`forkpty`), not a
  Swift SSH library. Terminal: SwiftTerm's `TerminalView`.
- The terminal runs with **Option as a normal modifier** (`optionAsMetaKey =
  false`). SwiftTerm's default treats Option as a meta key and sends ESC + the
  letter, which makes Option-based layouts unusable — on a Turkish or German
  keyboard `@`, `~`, `|`, `[`, `]`, `{`, `}`, `\` are all Option/AltGr chords and
  could not be typed at all. With the default off they compose normally, exactly
  as in Terminal.app.
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


## RDP sessions

A connection whose protocol is `RDP` opens in a **pane**, not a separate
application window — the same place an SSH terminal lives, including in a split
view.

- Transport: **FreeRDP linked as a library** (Apache-2.0), drawn into the pane by
  a small C bridge (`Sources/KRemote/KRDPClient.{h,c}`). The alternative —
  shelling out to `sdl-freerdp` — opens its own window, which would make tabs and
  panes meaningless for RDP.
- Settings come from the connection and the folders above it: **domain**,
  resolution (smart size / fit to panel / fullscreen / custom size), colour depth
  (8/16/24/32-bit) and redirections (clipboard, drives, printers, sound, key
  combinations). Unset fields inherit; the editor shows each as a three-way
  **Inherit / On / Off** so "not set here" stays visible.
- Credentials reuse the tree's username and Keychain password; the password is
  handed to FreeRDP in-process and never appears in argv, an environment variable
  or a temporary file.
- The desktop is negotiated in **pixels** (the pane's backing size), so a Retina
  pane gets a full-resolution desktop rather than a half-resolution one; clicks
  and moves are mapped from view points onto the remote pixel grid.
- The pane's status bar shows live state, target and resolved options, with
  **Reconnect** when a session drops.

### End users install nothing

The RDP libraries are **embedded in the `.app`** (`Contents/Frameworks/`), so
FreeRDP is not a runtime dependency for anyone who downloads KRemote.
`scripts/embed-freerdp.sh` copies them in, rewrites install names to `@rpath`,
re-signs, and fails the build if anything outside the bundle is still referenced.

### Why FreeRDP is built from source

Homebrew's `freerdp` bottle hard-depends on **ffmpeg, which is GPL-3.0** —
embedding it would make this MIT project effectively GPL-3.0, and it pulls in
X11, SDL, SmartCard and USB stacks the app never uses. Releases therefore build
FreeRDP with [`scripts/build-freerdp.sh`](scripts/build-freerdp.sh): OpenH264
(BSD-2) instead of ffmpeg, no X11/SDL/PCSC/USB. The result is ~10 MB and entirely
permissive — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Installing FreeRDP is a **build-machine** step, not a user one:

```bash
brew install cmake ninja pkgconf openh264 jansson uriparser jpeg-turbo openssl@4
scripts/build-freerdp.sh            # installs into ~/hermes-build/freerdp-install
```

`project.yml` finds it through `FREERDP_ROOT` (defaulting to that path).


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
- Passwords live **encrypted in `secrets.enc`**, keyed by a **single** random
  AES key held in the macOS Keychain — not one Keychain item per connection.
  That matters: the legacy Keychain validates "Always Allow" against the
  requesting binary's code signature, so a stored password's grant does not
  survive an app update. With one item per node that meant **a dialog per
  connection after every update** (the "10 prompts on each release" behaviour);
  with one item, an update can prompt at most once. (The Data Protection
  Keychain would avoid even that, but it needs a signing Team ID and a
  `keychain-access-groups` entitlement, which a self-signed build does not have.)
- Passwords are never written to the JSON file — the node's `password` field is
  deliberately excluded from `CodingKeys`, and a unit test asserts it stays out.
- Passwords are loaded **lazily**, per node, when a connection is opened or
  edited — never all at once at launch.
- Per-node values are *directly set*; a blank field (or port `0`) means
  **inherit from the parent folder**, resolved by `EffectiveConnection`.

## Layout

```
Packages/KRemoteCore/  local SwiftPM package: tree model, inheritance, JSON store,
                       Keychain, RDP settings, mRemoteNG crypto/import  (unit-tested)
Sources/KRemote/       SwiftUI app: sidebar, tabs, editor sheet, SwiftTerm host,
                       RDP pane host
```

## Scope

- **v1:** SSH sessions, connection tree, `confCons.xml` import, Keychain-stored secrets.
- **Now:** RDP modelled + editable, FreeRDP pane landing next.
- **Later:** SFTP, Telnet, port forwarding, HTTP/HTTPS, VNC.

## Stack

- Swift 6 + SwiftUI, macOS 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) — terminal emulation
- SSH is the system `ssh`; no SSH library is linked.
- RDP is [FreeRDP](https://www.freerdp.com/) (Apache-2.0), linked as a library.
- No `.xcodeproj` in git; `project.yml` is the source of truth.

## Download

Grab the latest `KRemote-<version>.dmg` from [Releases](../../releases), drag
**KRemote** to Applications, and — because the app is **not notarized** (no Apple
Developer account) — clear Gatekeeper's quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/KRemote.app
```

or right-click the app → **Open** → **Open** again. It is ad-hoc signed, which is
all an arm64 binary needs to run.

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

- `.github/workflows/ci.yml` builds on `macos-15` and uploads an unsigned `.app`
  zip as a workflow artifact (runs on every push).
- `.github/workflows/release.yml` runs on a `v*` tag: builds Release, ad-hoc
  signs, packages a `.dmg` + `.zip` and publishes a GitHub Release.

To cut a release: bump `MARKETING_VERSION` in `project.yml` and tag the commit
(`git tag v1.0.0 && git push origin v1.0.0`).

## License

MIT — see [LICENSE](LICENSE).

`confCons.xml` is a format defined by the mRemoteNG project (GPL-2.0). KRemote
implements the format independently from observation of files it produces, and
does not include any code or assets from mRemoteNG.
