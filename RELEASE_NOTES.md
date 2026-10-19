## KRemote 1.8.0 beta 3

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

### New: an SFTP file browser

A Finder-like window for the server's files, opened two ways:

- **Toolbar button** (top right, folder-with-gear icon) in a connected SSH
  session — browses that session's server.
- **Right-click any connection → Connect ▸ SFTP** — works with no terminal open.
- **⇧⌘S** from the main window browses the selected connection.

One window per connection; asking again raises the existing one rather than
opening a second browser on the same server.

The window has back/forward (⌘[ ⌘]), enclosing folder (⌘↑), a clickable
breadcrumb, Go to Folder (⌘G), reload (⌘R), a Places sidebar, and **list and
icon views** with the toggle remembered. List view sorts by name, size, modified
or permissions and shows `-rw-r--r--`-style permissions. Icons are the real macOS
document icons. Connection state, the resolved target and the item count sit in
the status bar; errors show the server's own text, not "operation failed".

The engine underneath was verified against a live OpenSSH server end to end:
connect, resolve `~`, list an 88-entry home directory, write a file, read it back,
stat, chmod 600, rename, delete.

**Not in this build yet:** download/upload, new folder, rename, delete and the
permissions sheet (the file operations), and automatic `sudo` elevation. Those
are the next beta. Drag-and-drop upload says so explicitly rather than silently
doing nothing.

### Install

Already on 1.7.x or 1.8.0-beta.1? **Check for Updates…** → switch to **Beta** →
**Update and Relaunch**. That is the intended path, and it is what this beta
mostly exists to test.

Manual install: open `KRemote-1.8.0-beta.2.dmg`, drag **KRemote** to
Applications. The build is ad-hoc signed and not notarized, so on first launch
either right-click → **Open** → **Open**, or run `xattr -dr
com.apple.quarantine /Applications/KRemote.app` in Terminal.

### Please try

1. **Check for Updates…** on Beta: it should offer 1.8.0-beta.3 and install it.
2. Right-click a connection → **Connect ▸ SFTP**: a window opens at the home
   directory, listing files. Check the breadcrumb, ⌘↑, and the list/icon switch.
3. Open SFTP for the same connection again: it should raise the same window, not
   open a second one.
4. In an SSH session, the toolbar's folder button should browse that server.
5. Existing SSH and RDP sessions, tabs, split view and stored passwords must
   behave exactly as in 1.7.11.
