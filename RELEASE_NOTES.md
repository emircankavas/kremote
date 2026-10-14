## KRemote v1.5.3

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### What's new

**RDP clipboard now works, both directions.** Copy on the Mac and paste inside
the session, or copy in the session and paste on the Mac. The clipboard channel
was never being created: FreeRDP rebuilds its channel manager *after*
pre-connect and populates it through an `instance->LoadChannels` callback that
this build left unset, so no virtual channel — clipboard or display — ever went
live. That callback is now installed, and the clipboard and Display Control
channels are requested by name before the rebuild. Text is converted between
UTF-16LE (what RDP speaks) and UTF-8 by hand, so non-ASCII and emoji survive.

**The RDP pane no longer shows two stacked status bars.** The outer pane bar
reads SSH connection state, which an RDP session never updates, so it sat on
"Idle" forever directly above the RDP pane's own "Connected" bar. The RDP branch
now draws its own header and status bar and the outer one is skipped for it.

**RDP shows a picture again.** v1.5.2 enabled the RDP8 graphics pipeline to make
frames smoother, but the session then connected and drew nothing at all: with
the pipeline on, the server sends its output through the `rdpgfx` channel's
`SurfaceCommand` callback, which has to blit into the drawing surface, and that
handler does not exist yet. The pipeline is now left off, so frames travel the
legacy GDI path that v1.5.0 and v1.5.1 used and the desktop is visible again.
The speed work needs `SurfaceCommand` first, and will come on its own.

### Fixes

- RDP: closing a tab while the sign-in sheet was open no longer blocks; the wait
  is released before the session thread is joined.
- RDP: a display-control channel requested under its wire name made post-connect
  fail outright; the addin lookup name is used instead.

### Notes

- Building from source still needs Homebrew's build dependencies (cmake, ninja,
  pkgconf, openssl, openh264, jansson, uriparser, jpeg-turbo) and XcodeGen; the
  FreeRDP libraries are built without ffmpeg and embedded in the app, so end
  users install nothing.
