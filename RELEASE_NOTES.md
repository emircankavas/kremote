## KRemote 1.9.0 beta 1

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### New: edit remote files in place

Double-click a text file in the SFTP window — or right-click ▸ **Edit** — and it opens
in an editor inside KRemote. Save writes it back over the same connection.

- **Conflicting changes are not overwritten silently.** The size and modification time
  from when the file was read travel with the buffer; if either changed, the first Save
  explains and offers **Overwrite** instead of writing.
- **Permissions are preserved**: the SFTP write creates with 0644, which would turn a
  `0600` key file world-readable on save.
- A file with a NUL byte in it is **refused** rather than truncated, and a file that is
  not valid UTF-8 says so before saving rewrites it.
- Closing with unsaved changes asks first.

### New: run a command on several servers

One command, every selected connection, results side by side. Each server runs in its
own connection, so a dead host cannot hold up the rest, and the results stay in the
order the servers were picked — a list that reshuffles as replies arrive is unreadable
when looking for the one host that differs. Filter by text, or show failures only.

### New: remote tools

A menu of read-only diagnostics for the focused session: disk, memory, busiest
processes, listening ports, routes, failed services, today's log errors, recent logins.
MobaXterm ships a Unix userland because Windows has none; macOS does, so what is
actually missing is knowing which command answers the question — and typing it
correctly. Every entry is read-only by construction, which is why these run without a
confirmation while snippets do not.

### New: transfers, file operations and a permissions sheet

The SFTP window can now do the work, not just show the listing.

- **Download** (⌘D) and **Upload** (⌘U), from a save panel, an open panel, or by
  double-clicking a file. A folder or a multi-selection asks for a destination
  folder. Nothing is overwritten silently: a clash asks once — **Replace**,
  **Keep Both** or **Skip** — and the answer covers every conflicting item in
  that batch.
- **Drag a file or folder out** to Finder or any other app. Only the drop fetches
  the bytes; dragging and letting go elsewhere transfers nothing.
- **Transfer queue** under the listing: bytes done of total, throughput, time
  left, per-item **Cancel** and **Retry**, **Retry All**, **Cancel All**, and
  **Reveal in Finder** for a download. Up to three run at once; one failing never
  cancels the rest. Cancel closes the remote handle and deletes the `.part` file,
  so a cancelled download leaves nothing behind.
- **New Folder** (⇧⌘N), **Rename** (Return on a single row), **Delete** (⌘⌫) with a
  confirmation that names the item and, for a folder, how many items go with it,
  **Show Info**, and **Refresh**.
- **Permissions sheet**: owner/group/other **rwx** checkboxes and the octal field
  stay in sync, and uid/gid start from the server's own values. It applies in one
  `SETSTAT` and refreshes the row.
- **Selection** works the way Finder does: plain click, ⌘-click to add or remove,
  ⇧-click for a range. Every operation acts on the whole selection, and the
  status bar shows the item count and the total size selected.
- A batch that partly fails reports **one** summary naming exactly what worked and
  what did not — never a modal per item.

If a file operation is refused, the alert says whether sudo was tried and, if it
was not, what to change on the connection to allow it.

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

### Fixed: parameters never reached the script

The values were bound as a separate statement — `text=…; sh script` — which defines a
*shell* variable. A shell variable is not exported, so the script ran in a child
process that could not see it: every `$text` was empty.

`text=… sh script` is what puts a value in the child's environment. The assignment is
now the prefix of the invocation rather than a statement before it.

### New: snippet parameters

A script can ask for values before it runs. Declare them in the editor — by hand, or
with **Detect from Script**, which finds the `$VARIABLES` the body mentions and adds
them — and the run dialog shows a field for each.

Parameters are **named variables**, not positional arguments: `$TARGET_HOST` explains
itself where `$3` does not. They are bound as an environment prefix on the `sh`
invocation, so they exist for the script and not for your interactive shell
afterwards — a password variable should not outlive the run.

A parameter with no default is marked *required* and Run stays disabled until it is
filled in; otherwise the script would silently receive an empty string. A parameter
marked *secret* is masked in the run dialog and in the marker line.

Values are never remembered between runs. Only the snippet's own defaults are stored:
the answer to "which server" changes, and a stale one is a command aimed at the wrong
host.

The values themselves never appear in the generated command. Each is base64-encoded
and decoded by the shell into its assignment, so a value containing a quote, a
semicolon or a newline is data the script receives rather than something the shell
interprets.

### Fixed: running a snippet closed the SSH session

The command ended with a bare `exit` to report the script's status. In the
interactive login shell a snippet is written into, `exit` does not report a status —
it terminates the shell, and the session with it. Running `whoami` disconnected the
server.

The command now runs inside a subshell, where `exit` ends only the subshell. Its
cleanup also moved to a `trap`: the old trailing `rm` was skipped when a script was
interrupted, leaving an executable copy of the script on the server.

Verified by driving the shipped command through a real pty: the session survives,
the script's output appears, and a script that exits 7 leaves `$?` at 7.

### New: snippets

A toolbar menu holds saved scripts and runs one on the focused SSH session.

The script is **sent as a file, not typed into the terminal**. Pasting a multi-line
script into a pty makes the shell run it line by line as the bytes arrive, which
mangles quotes, heredocs and `if` blocks and makes a half-finished run impossible to
abort. The body travels base64-encoded — a script can contain any byte, and quoting
it would break on the first `'` — is written to a temp file on the server, run with
`sh`, and removed by the command itself, so a failed run does not leave an executable
copy of your script behind. The script's own exit code is what the command returns.

Every run is confirmed first, with the script shown rather than its name — the name
is the part you already trust. A body that looks destructive gets a louder dialog and
an orange button.

Snippets are shared across all connections, saved in
`~/Library/Application Support/KRemote/snippets.json`, and can be created, edited and
deleted from the same menu.

### Fixed: the reason was unreachable

The badge showed nothing at all when WinRM could not answer, so there was nothing
to click and no way to find out why. It now shows `–` where the figures would be —
clickable, and opening the reason plus the two commands that fix it. No number is
invented: the placeholders are visibly empty.

Polling also continues after a failure, on a slower 30-second cadence, so enabling
WinRM during a session brings the figures to life instead of requiring the tab to be
reopened. A connection with no username says so rather than polling an account the
server would reject.

### Fixed: a refused WinRM port now says so

A host with WinRM on 5986 that a firewall drops produced a silent four-second wait
and then nothing in the badge. The connection was refused immediately — the
transport reported it as `.waiting` and that state was ignored, so the refusal was
never seen.

It now fails in milliseconds and names the port and the reason: *"Could not reach
192.168.1.137:5986 — Connection refused. Check that WinRM is listening on that port
and that the firewall allows it."* "Refused" and "timed out" mean different things —
no listener versus a dropped packet — and the message distinguishes them.

Connections also try every address a name resolves to, IPv4 and IPv6. A Windows
listener bound to `::` reports IPv6 only, and a client that dialled IPv4 exclusively
could never reach it.

### Fixed: RDP load figures on hosts that only allow WinRM over TLS

Two real faults, both verified against a Windows host on 5985 and 5986.

The HTTPS listener was never used: the option existed and nothing applied it, so a
host that only allows 5986 could not answer at all. Encrypted WinRM works now.

The port is also discovered: 5985 first, then 5986. RDP says nothing about which
listener a machine has, and asking the user for a WinRM port they may not know is
worse than trying both.

Two things that were wrong along the way, worth recording because they looked like
protocol failures and were not: WinRM binds its NTLM challenge to the TCP
connection, so a client that redials between the handshake and the answer is refused
even with a correct message; and the plaintext path must send no `Authorization`
header after the handshake, because NTLM authenticates the connection rather than
each request.

### Fixed: the CPU and memory figures were invisible

Two separate faults, both of which made the badge look like a feature that was
never built.

The badge was the first thing a narrow pane squeezed, so the numbers truncated to
`9…` — present in the layout, unreadable to a person. It now keeps its size.

And when a sample failed the badge drew a single faint icon, which is
indistinguishable from nothing. It now shows `–` in place of each figure, occupies
its space from the first moment, and clicking it explains why: no key, wrong
password, no `/proc`, or an unreachable host.

SSH sampling also gained a fallback: the shared connection authenticates once
instead of every five seconds, but if it cannot be established the sampler retries
on a plain connection before giving up. Failures are recorded in
`~/Library/Application Support/KRemote/metrics.log`.

### Changed: RDP load figures come from WinRM, not ssh

An RDP session's CPU and memory used to be sampled over ssh, which was wrong on
two counts: a Windows host usually has no ssh at all, and the account used for RDP
is rarely the one that may log in that way.

RDP now asks the host over WinRM (5985), and **if the host does not answer, nothing
is shown** — no placeholder, no error icon. RDP does not need WinRM, so a machine
with a working desktop and WinRM switched off is a normal setup rather than a fault.

WinRM speaks NTLM, which no Apple framework implements, so the client is written
here: WinRM is stateful (a shell is created, a command is started, its output is
collected), and it binds the authentication challenge to the TCP connection that
issued it, which is why the transport is a socket kept open across both legs rather
than `URLSession`.

### New: live CPU and memory in the status bar

Every connected session shows `CPU 12% · RAM 63%` next to its state. Click it for
load average, swap, uptime and the byte figures.

SSH samples over a separate command channel — two `/proc/stat` samples on Linux,
`top`/`vm_stat` on macOS — leaving the interactive terminal untouched. The samples
ride one authenticated connection (`ControlMaster`), so a password-only server is
not asked for a password every five seconds, and the connection is closed when the
session ends.

RDP carries a desktop, not counters, so an RDP session samples the same host over
ssh. A Windows box with no ssh simply shows nothing rather than an error.

Sampling runs every five seconds and stops when the pane goes away.

### Fixed: the archive channel was killing itself

Compress and Download on root-owned files still reported
"Elevating with sudo failed. — /tmp/kremote.XXXXXX" with tar warnings attached.
That message names a file only tar creates, which is the whole diagnosis: sudo
had worked and tar had started, and then the channel tore itself down.

The elevated command was being run through the transport written for the SFTP
subsystem, where any line on stderr is sudo's verdict. For a command it is not —
tar warns "Removing leading `/' from member names" while archiving perfectly.
Commands now get their own channel that keeps the same one-line password
handshake and treats stderr as diagnostics.

### Fixed: "Elevating with sudo failed" while sudo actually worked

beta 17's retry started sudo correctly and then killed it: the setup window
treated any text on stderr as a refusal, and `tar` prints
"Removing leading `/' from member names" the instant it starts. Only messages
that actually look like a sudo refusal count now, and the password-rejection
patterns are narrower so ordinary command output cannot trigger them.

### Fixed: the sudo retry for Compress and Download never ran

beta 16 was supposed to retry the archive as root when the server refused, but
`tar` reports a refusal on stderr and exits — the channel sees a closed stream,
not an error — so the retry was never reached and the download simply failed.

The refusal is now recognised in the command's output, the half-written file is
truncated before the elevated attempt, and if the elevated attempt is refused too
the message says the sudo retry did not help (rather than repeating tar's text,
which reads as "the feature is broken").

### Fixed: Compress and Download on files you can only read as root

Archiving ran as the login user, so a selection owned by root failed with
`tar: Cannot stat: Permission denied`. It now follows the same rule as the rest
of SFTP: try normally, and on a refusal retry once as root through the
connection's `sudo`. A timeout is not retried — only a refusal is, so a slow link
does not cost a second login.

### New: Compress and Download

Right-click a selection → **Compress and Download** builds a `.tar.gz` **on the
server** and downloads the archive. The compressed bytes are what cross the
network — downloading the files first and compressing locally would move the
uncompressed data and need a temporary copy on the Mac.

The archive is written to a private temporary directory on the server and is
deleted immediately after it has been sent, on failure, and if the transfer is
cut. Remote paths are single-quoted, so a filename containing `;`, quotes or `$`
is treated as a name and never as shell syntax.

### Fixed: selecting more than one file

⌘-click and ⇧-click did nothing: the rows read the modifier keys inside a SwiftUI
tap handler, where they have usually already been released, so every click looked
like a plain click and replaced the selection. The click is now taken from the
real mouse event, so ⌘-click toggles, ⇧-click extends, and a plain click replaces
— in both list and icon view. The dialogs act on the whole selection.

### New: drag out, Get Info, and ⌘⌫

- **Drag a row onto the Desktop or Finder** to download it. The drag carries the
  file promise, so the copy starts as soon as you drop it.
- **Get Info** (⌘I) shows size, permissions, owner/group and dates for the
  selection.
- **⌘⌫ deletes** the selection, with one confirmation naming the items and, for
  folders, how many things are inside.
- One selection model across both views: ⌘-click toggles, ⇧-click extends.

### Fixed: sudo could not find sftp-server

beta 11 invented an `sshd -i -s sftp` invocation to reach the built-in SFTP
server. `sshd` has no `-s` option, so the server replied with its usage text and
nothing was elevated.

The lookup now checks every distribution layout — including
`/usr/libexec/openssh/sftp-server`, which RHEL, Fedora and Alma use and the old
list missed — then `PATH`, then asks `sshd -T` for the subsystem path from the
server's own effective configuration, and finally searches `/usr` and `/opt`. All
of it runs as root inside the single `sudo`, and the whole command is checked
against `sh -n` by a unit test.

### Fixed: the sudo retry never actually ran

beta 10's elevated command was assembled by gluing shell fragments together,
which produced `then;` — a syntax error bash reports before running a single
line, so every sudo attempt failed with a shell parser message rather than any
real permission problem. The command is now one properly written shell program,
and a unit test feeds it through `sh -n` so an edit that breaks the syntax fails
the build instead of your connection.

### Fixed: sudo retry gave up on internal-sftp servers

Your server is configured with `Subsystem sftp internal-sftp` — the SFTP server is
built into `sshd`, so there is no `sftp-server` file to run, and the elevated
retry stopped with "no sftp-server binary found" even though your sudo worked.

KRemote now falls back to `sudo sshd -i -s sftp` for those hosts, which speaks the
same protocol from the sshd binary that is always installed. Servers with a real
`sftp-server` (macOS, Homebrew) keep using it.

### Fixed: sudo was not tried automatically

Automatic elevation was implemented but switched **off by default**, so a folder
you have no permission for just reported "permission denied". It is now on by
default: when an operation is refused and the connection has a saved password,
KRemote retries that one operation over a second `ssh` connection running the
sftp subsystem under `sudo`. The rest of the session stays unprivileged.

It still needs two things on your side — the password saved on the connection,
and real `sudo` rights for that user — and if either is missing you get the
original refusal plus the reason. The per-connection switch (Edit → SFTP) now
reads "Retry refused file operations with sudo" and is on unless you turn it off.

### New: download, upload and file operations

The SFTP window could only look at files. Now it can move them:

- **Download** (⌘D) — one file opens a save panel; a folder or a multi-selection
  asks for a destination folder and never overwrites silently (a clash becomes
  `name 2.ext`).
- **Upload** (⌘U) — pick files or folders and they go into the folder you are in.
- **New Folder** (⇧⌘N), **Rename**, **Delete** and a **Permissions** sheet from the
  row's context menu, plus **Show Info**.
- A transfers panel under the listing shows progress, throughput, failures and
  offers cancel/retry per item.

### Fixed: the permission error vanished

A refused folder put its message on screen for a moment and then wiped it: the
browser returned you to the previous folder and that folder's successful reload
cleared the message a runloop later. The reason now stays in a dismissible banner
above the listing you are in.

### Fixed: folders would not open

A row had two separate click handlers — one for selecting, one for opening on a
double click — and on macOS the first one consumed the click before the second
could see it. So a folder could be highlighted but never entered. Both the list
and the icon view now use a single gesture that tells a single click from a
double click.

Also: **Return / Enter** open the highlighted folder (as in Finder), and a folder
the server refuses to read now returns you to the folder you came from with the
server's message, instead of showing an empty window that looks broken.

### Fixed: KRemote quitting on open (beta 5 crash)

Opening SFTP in beta 5 terminated the whole app with a SIGTRAP. The 25-second
read timeout introduced in beta 5 could resume its continuation twice — once
when the read returned and once when the timer fired — and Swift traps on that.
The rule now lives in one place that can only resume once, and a timeout also
closes the ssh process so the thread blocked on the pipe is released. Three
tests cover the race, including fifty simultaneous finishes.

### Fixed: SFTP hanging on "Connecting…" with no error

beta 4 could sit on "Connecting to sftp://…" forever when a server accepted the
connection and then never answered — there was no timeout anywhere, so there was
nothing to show. Every wait is now bounded: the window gives up after 25 seconds
with the reason, and the connecting screen explains what it is doing and offers
**Cancel**. ssh's "Permanently added … to the list of known hosts" boilerplate is
no longer glued onto the front of error messages.

### Fixed: signing in to SFTP with a password

beta 3 could not open SFTP on a server that authenticates with a password. With
no terminal attached to an SFTP connection, `ssh` had nowhere to read the
password from and fell back to `ssh-askpass`, which macOS does not ship — so the
connection died with `ssh_askpass: exec(/usr/X11R6/bin/ssh-askpass): No such file
or directory` before the protocol even started. The saved password was also never
handed to the SFTP connection at all.

Both are fixed: the browser now signs in with the password saved on the
connection, using a private (0700, deleted when the session closes) askpass
helper, and the password never appears in the process list. The same password is
used by the `sudo` channel when elevation is needed.

If password sign-in still fails, the window shows ssh's own reason — check that
the host accepts password authentication and the saved password is current.

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

**Still not in this build:** SCP/FTP/WebDAV, resumable transfers, server-to-server
copy, symbolic-link creation, drag-and-drop *upload* (drag-out is supported),
and folder sync.

### Install

Already on 1.7.x or 1.8.0-beta.1? **Check for Updates…** → switch to **Beta** →
**Update and Relaunch**. That is the intended path, and it is what this beta
mostly exists to test.

Manual install: open `KRemote-1.8.0-beta.2.dmg`, drag **KRemote** to
Applications. The build is ad-hoc signed and not notarized, so on first launch
either right-click → **Open** → **Open**, or run `xattr -dr
com.apple.quarantine /Applications/KRemote.app` in Terminal.

### Please try

1. **Check for Updates…** on Beta: it should offer 1.8.0-beta.29 and install it.
2. Right-click a connection → **Connect ▸ SFTP**: a window opens at the home
   directory, listing files. Check the breadcrumb, ⌘↑, and the list/icon switch.
3. Open SFTP for the same connection again: it should raise the same window, not
   open a second one.
4. In an SSH session, the toolbar's folder button should browse that server.
5. Existing SSH and RDP sessions, tabs, split view and stored passwords must
   behave exactly as in 1.7.11.
