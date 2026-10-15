## KRemote v1.7.2

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**Dragging in a session draws a selection rectangle again.** A drag was sent as a
button-bearing mouse event on every move. RDP carries the button state separately
from the move — once pressed, the server holds it until the matching release — and
the reference client's motion path sends a plain move. Re-asserting the button on
each drag step is what stopped Explorer (and any other list) from marquee-selecting.
Drags now send plain moves; press and release are unchanged, so drag-and-drop still
works.

### Known limitation

Copying a file *out* of a session is not supported yet. FreeRDP assigns the
handler for incoming file contents only when it is built with FUSE
(`#if defined(WITH_FUSE)`), so there is no codec-side path to receive a remote file
on macOS. Supporting it means requesting the file's bytes ourselves and writing
them to disk (plus a place to put them), which is a feature of its own — text and
files *into* a session both work.








