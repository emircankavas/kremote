## KRemote v1.6.5

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP should stop hitching.** FreeRDP's codec thread pool races with the graphics
pipeline's surface handling, and this build left it on. Decoding now runs on the
session thread (`THREADING_FLAGS_DISABLE_THREADS`) — the same fix the reference
macOS client needed for exactly this symptom. Single-threaded decode is ample for
one desktop.

**File paste is rebuilt on the mechanism that actually works.** The file list was
being hand-assembled from `stat(2)` and advertised under a raw `CF_HDROP` id.
A server does neither: it matches the format by *name*, and it expects the
descriptor list to be built the way Explorer builds it — folders descended, sizes
resolved, paths relative. That conversion is winpr's job, so the file list now
goes through a winpr clipboard: the paths are handed in as a `text/uri-list`,
winpr produces the `FILEDESCRIPTORW` records, and the format is registered and
advertised under its real name, `FileGroupDescriptorW`.

Alongside that, the earlier handshake gaps stay fixed: the local file capability
is registered, the server's capability flags are recorded, and the format lists
are announced/retired through the file context.

All of v1.6.4 down to v1.6.0 is included.




