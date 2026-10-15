## KRemote v1.6.6

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP frame handling was costing the main thread a lot per frame.** The desktop
image was assembled on the main actor and tagged in a way CoreAnimation will not
take directly:

- Every frame allocated and copied the whole desktop on the main thread. It is now
  built on FreeRDP's thread; only the finished image crosses to the UI.
- The pixels were tagged device-RGB with alpha skipped. Core Animation takes a
  CGImage's bytes as-is only for sRGB + premultiplied alpha; anything else makes
  it re-render through CoreGraphics on the main thread *for every frame* — the
  same cost the reference macOS client measured and avoided. The image is now
  sRGB + premultiplied (with the alpha byte forced opaque during the copy).

**Copying a file into a session works** (from v1.6.5 — the file list now goes
through a winpr clipboard and is advertised under its real name,
`FileGroupDescriptorW`).

### Known limitation

Copying a file *out* of a session is not supported yet. FreeRDP routes incoming
files through a FUSE mount, and this build has no FUSE; a macOS client also needs
a File Provider extension to hand the files to the Finder. That is a separate
feature, not a setting.

All of v1.6.5 down to v1.6.0 is included.





