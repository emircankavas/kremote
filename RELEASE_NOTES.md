## KRemote v1.6.1

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP no longer crashes when the graphics pipeline starts.** v1.6.0 turned the
pipeline on and wired up the frame callback, but left `update->DesktopResize`
unset. FreeRDP does not install a client-side default for it: the X11, SDL and
Qt clients each supply their own, and the graphics pipeline calls it from
`gdi_ResetGraphics` the moment it starts — with assert checks compiled out in
release builds, the call went to address 0 and the app died on the first frame.
The callback is now provided and rebuilds the framebuffer at the size the server
asks for.

Everything else from v1.6.0 is unchanged: the app icon, file paste into a
session, the one-time Keychain migration, and the graphics pipeline itself.
