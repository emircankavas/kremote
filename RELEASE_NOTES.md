## KRemote v1.7.3

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### New

**Copy a file out of a session.** Until now only the Mac → remote direction
worked: FreeRDP assigns the handler for *incoming* file contents only when it is
built with FUSE (`#if defined(WITH_FUSE)`), and this build has no FUSE. The bridge
now installs its own file-contents handler and pulls the bytes itself, so copying
a file in Explorer and pasting it in the Finder works.

Mechanically: the server announces its clipboard files as a
`FileGroupDescriptorW` list; the bridge requests each file's size and then reads
it in 64 KB blocks over the same clipboard channel, writing straight to disk as
the blocks arrive (nothing is held in memory), and finally puts the paths on the
pasteboard as file URLs — which is what Finder pastes from. Files land in a
private directory under the system temp directory, one per transfer.

Server-supplied names are treated as untrusted and reduced to a single safe
component before they touch the disk, so a `..` or an absolute path in a
descriptor cannot steer a write outside that directory.

### Known limitation

Folders are created but not recursed into, so copying a folder copies its
top-level entry; its contents are not transferred yet. Text remains two-way.

All of v1.7.2 back to v1.6.0 is included.









