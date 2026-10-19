# KRemote 1.8.0 — beta channel + SFTP

Status: planned (epic card `t_e979b639`). This document is the single source of
truth for the 1.8.0 cycle. Every child card is written so it can be read
standalone against this file.

- Repo: `D:/projects/kremote` — Swift 6 / SwiftUI / XcodeGen, macOS 15+, Forgejo CI
  on the Mac mini self-hosted runner.
- Shipped baseline: **v1.7.11** (`main`, `MARKETING_VERSION: 1.7.11`,
  `CURRENT_PROJECT_VERSION: 29`).
- Hosting: source of truth is `forgejo.kavas.dev`. **There is no GitHub anywhere** —
  source, CI, releases, SwiftPM dependencies (swift-crypto, SwiftTerm) and the
  FreeRDP mirror all live on Forgejo. Do not add a `github.com` URL, workflow or
  release step.

## 1. Branch and version rules

| Ref | Meaning | Who writes |
| --- | --- | --- |
| `main` | Shipped line. Always equals the latest stable release tag. Only fast-forwards from `beta` after the promotion gate. | Emircan (approval) |
| `beta` | Long-lived integration branch for the next minor. All 1.8.0 work lands here first. | every worker |
| `v1.7.11` | Last stable tag. **Frozen** — no commit may be pushed to a tag. | nobody |
| `v1.8.0-beta.N` | Pre-release tag on `beta` (`N` = 1, 2, 3…). Published as a Forgejo **pre-release**. | release workflow |
| `v1.8.0` | Stable tag, created from `main` only after the promotion gate. | Emircan |

Rules:

1. `main` is never pushed to directly during this cycle. A fix for a shipped-build
   bug is cherry-picked `beta` → `main`, tagged as a patch (`v1.7.12`) and merged
   back into `beta`. Stable users never see 1.8.0 work before it is approved.
2. Every merge into `beta` must pass CI (`.forgejo/workflows/ci.yml`). CI must
   therefore also trigger on `beta` (today it only triggers on `main`).
3. Pre-releases are built and published by `.forgejo/workflows/release.yml` from
   `beta` tags. Stable releases are built from `main` tags. One workflow, one
   branch check: a `v*-beta.*` tag must be an ancestor of `beta`; a plain `v*`
   tag must be an ancestor of `main`.
4. Each beta iteration bumps `CURRENT_PROJECT_VERSION` (build number) by 1. The
   build number, not the marketing version, is what the updater compares second.
5. **Promotion gate** (`beta` → `main`), all four required:
   - CI green on the exact `beta` HEAD being promoted,
   - the newest `v1.8.0-beta.N` has been installed and smoke-tested on the Mac
     mini (launch, SSH session, SFTP session, update check on the Beta channel),
   - `RELEASE_NOTES.md` covers the whole cycle,
   - explicit approval from Emircan recorded as a comment on the epic card.
6. After promotion: tag `v1.8.0` on `main`, publish as a **stable** release,
   fast-forward or merge `main` back into `beta` so the branches never diverge.

## 2. Release channels (in-app)

Beta is a **channel setting inside the one app**, not a second bundle.

- `UpdateChannel` is `.stable` / `.beta`, persisted in `UserDefaults` under
  `updateChannel`, default `.stable` on a fresh install. Users pick it in
  Software Update (`UpdateView`, segmented picker).
- Appcasts live in the **public** repo `emircan/kremote-releases` on `main`
  (the installed app must check for updates with no token):
  - `appcast-stable.json` — written only by stable releases,
  - `appcast-beta.json` — written by pre-releases,
  - a beta appcast must **also** advertise the newest stable release, so a beta
    user is offered the stable build once it ships (the app takes the max of the
    two channels only in this direction; never the reverse).
- A missing appcast (404) means "nothing published yet" and is not an error.
- Version comparison: `1.8.0-beta.2 < 1.8.0-beta.10 < 1.8.0` (build number breaks
  ties). A stable user must never be offered a `-beta` build.
- Artifacts (`.dmg`, `.zip`) are attached to releases in `emircan/kremote-releases`,
  never to the private source repo.
- Release notes: `RELEASE_NOTES.md` in the source repo is the curated body;
  pre-releases are marked as pre-release in Forgejo and carry an explicit
  "beta — install at your own risk, switch the channel back to Stable to leave"
  footer.

**Current state (do not redo):** the working tree of `main` already contains
uncommitted beta-channel work — `UpdateChannel`, two-appcast fetching and the
`UpdateView` picker. That work is the starting point; it must be committed on
`beta` first, not re-implemented.

## 3. SFTP scope

### Transport (decided)

- SFTP runs over the **system `ssh`** with `-s sftp`; the SFTP v3 protocol is
  spoken in-process. No SSH library is added to the project.
- Reason: `~/.ssh/config`, keys, ssh-agent, ProxyJump and ControlMaster keep
  working, exactly as the existing `SSHPtySession` does for terminals.
- The codec and client live in `Packages/KRemoteCore` (CI-testable without a
  server, via an injectable transport). UI lives in `Sources/KRemote`.

### Entry points

1. A **SFTP toolbar button** (top right) in a connected SSH session, opening SFTP
   for that session's node.
2. **Right-click any connection in the sidebar → Connect ▸ SFTP**, opening SFTP
   without needing an open terminal.

### Window

- One **separate window per connection** (not a tab, not a sheet). Re-opening
  SFTP for a connection already showing focuses that window instead of creating
  a second one.
- Finder-like: **icon view and list view** (toolbar segmented control, persisted
  per user), path/breadcrumb bar, sidebar of shortcuts (`~`, `/`, `/tmp`, mount
  roots), sortable columns in list view (name, size, modified, permissions, owner).
- Reveal/refresh, go to path (⌘G), up (⌘↑), hidden files toggle (⌘⇧.).

### Transfers and file operations

- Download and upload with progress, throughput and cancel; queue window shows
  queued/running/failed items with a retry action. Files are written to a
  `.part` temp name and renamed on success.
- New folder, rename, duplicate-on-remote (copy = download+upload), delete
  (recursive with a confirmation showing the item count), chmod and chown via a
  permissions sheet, refresh.
- **Out of scope for 1.8.0:** SCP/FTP/WebDAV, SFTP-over-RDP, server-to-server
  copy, symlink creation, resumable transfers, Finder drag-and-drop, sync/folder
  mirroring, bookmark/path history beyond back/forward.

### sudo elevation (decided)

- If an operation fails with `SSH_FX_PERMISSION_DENIED` (read or write) and the
  node has a stored password plus the "sudo" flag, the client retries **the same
  operation** over a second SSH channel that runs the sftp subsystem under sudo:
  `ssh -T <host> "sudo -S -p '' <sftp-server path>"`, with the stored password
  written to stdin.
- The plain `-s sftp` channel stays connected and is used for everything the
  login user can already do; only the retried operation goes through the
  elevated channel. Elevation is per operation, never a global mode toggle.
- If elevation also fails (wrong password, no sudoers entry, no sftp-server
  binary) surface one alert with the server's stderr and leave the item in the
  failed state. Never loop, never prompt repeatedly.
- The password is read from the existing `SecretStore`; it is never logged and
  never shown in a UI field after the first entry.

### Non-goals

- No notarization, no second app bundle, no change to the RDP path, no changes to
  the conffile/Keychain formats.

## 4. Child cards

| # | Card | Id | Owner | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Beta branch + CI/release pipeline for pre-releases and appcasts | `t_d1ff5a39` | devops-engineer | — |
| 2 | Finish the in-app channel plumbing (version ordering, stable-fallback, UI) | `t_ddeae4c6` | desktop-developer | 1 |
| 3 | `SFTPClient` + SFTP v3 codec in KRemoteCore (injectable transport, unit-tested) | `t_579d549f` | apple-developer | — |
| 4 | SFTP window: entry points, icon/list views, navigation | `t_83eb0501` | desktop-developer | 3 |
| 5 | SFTP transfers, file operations, permissions sheet | `t_6ffd9dd0` | desktop-developer | 4 |
| 6 | sudo elevation fallback | `t_a4276b3a` | apple-developer | 3 |

Cards 4 and 5 are sequential on the same window; card 6 can land in parallel
with 5. Nothing is merged to `main` in this cycle without the promotion gate in
§1.

## 5. Assumptions (validate on the Mac mini, do not design around them)

- The target servers run OpenSSH and expose `sftp-server` at
  `/usr/lib/openssh/sftp-server` or on `PATH`; SFTP v3 is the negotiated version.
- `sudo` may be configured with `requiretty`; the elevation path uses `ssh -T`
  (no PTY) because `sudo -S` reads the password from stdin. If a server rejects
  that, the card 6 worker records it and the feature degrades to the error alert
  — it does not fall back to driving a PTY.
- The self-hosted runner can push to `emircan/kremote-releases` with the existing
  `FORGEJO_TOKEN` secret.
