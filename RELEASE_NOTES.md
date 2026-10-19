## KRemote 1.8.0 beta 2

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### New: beta release channel

KRemote can now follow a **Beta** channel, so a new build reaches you without
touching the shipped one. Open **KRemote ▸ Check for Updates…** and pick
**Stable** or **Beta** in the window's top-right switch.

- Updates are served entirely from the self-hosted Forgejo. Nothing talks to
  GitHub any more — not the update check, not the build, not the dependencies.
- A beta install is offered the newer of the beta and stable releases, so once
  1.8.0 ships you move onto it automatically.
- A stable install never sees a `-beta` build.
- Version ordering understands pre-releases: `1.8.0-beta.2 > 1.8.0-beta.1`, and
  `1.8.0` beats every beta of itself.

### New: SFTP engine (no window yet)

The SFTP v3 client that the file browser will use is in place: connect over the
system `ssh`, list directories, download and upload, mkdir/rmdir/remove/rename,
chmod, realpath.

Verified against a live OpenSSH server end to end: connect, resolve `~`, list an
88-entry home directory, write a file, read it back, stat, chmod 600, rename,
delete. Elevation is wired as a seam: a permission failure retries the same
operation once on a privileged `sudo` transport, and never loops.

**What you cannot do yet:** there is no SFTP window, no toolbar button and no
Connect ▸ SFTP menu item. That arrives in the next beta.

### Install

Already on 1.7.x or 1.8.0-beta.1? **Check for Updates…** → switch to **Beta** →
**Update and Relaunch**. That is the intended path, and it is what this beta
mostly exists to test.

Manual install: open `KRemote-1.8.0-beta.2.dmg`, drag **KRemote** to
Applications. The build is ad-hoc signed and not notarized, so on first launch
either right-click → **Open** → **Open**, or run `xattr -dr
com.apple.quarantine /Applications/KRemote.app` in Terminal.

### Please try

1. **Check for Updates…** on Stable: it should say you are up to date (1.8.0 has
   not shipped).
2. Switch to **Beta**: it should offer 1.8.0-beta.2 and install it.
3. After relaunch, switch back to **Stable** and check again — it should not
   offer the beta again.
4. Existing SSH and RDP sessions, tabs, split view and stored passwords must
   behave exactly as in 1.7.11.
