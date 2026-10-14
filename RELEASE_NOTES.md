## KRemote v1.6.0

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### What's new

**An app icon.** KRemote finally has one — the blue-to-purple gradient with the
"K" running into a terminal window.

**Copy files from the Mac into a session.** With text working, files now work in
the direction that gets used most: copy a file in Finder while an RDP session is
focused, then paste it on the remote desktop. The clipboard channel advertises
the file format (`CF_HDROP`) and streams the bytes the server asks for, in
chunks. Several files at once work. Copying files *out* of a session is not
supported yet — FreeRDP routes that through a FUSE mount that macOS builds do
not have, and nothing is claimed rather than promising a paste that would do
nothing.

**Passwords saved before v1.5.0 are carried over automatically.** The old
per-connection Keychain items are read once, moved into the encrypted store and
deleted. After that the app keeps a single Keychain entry, so updating the app no
longer re-prompts for every connection.

**RDP frames come through the RDP8 graphics pipeline again — this time with the
drawing hook it needs.** The pipeline (progressive / RemoteFX, H.264 through the
bundled OpenH264) is what makes a real desktop feel smooth rather than a
slideshow, and it was switched on in 1.5.2 without any way to receive the frames:
rdpgfx does not call the plain GDI `EndPaint`, it hands finished surfaces to an
`UpdateSurfaces` callback. That callback is now chained onto FreeRDP's own
GFX→GDI translation, so surfaces are decoded and drawn first and the finished
buffer is then handed to the app.

### Fixes

- RDP: the GFX drawing hook takes care not to replace the pipeline's own
  `UpdateSurfaces`; calling it first is what puts a picture on screen at all.
- RDP: the clipboard and Display Control channels keep working from v1.5.2 (the
  channel manager is loaded through `instance->LoadChannels`).

### Notes

- Building from source still needs Homebrew's build dependencies (cmake, ninja,
  pkgconf, openssl, openh264, jansson, uriparser, jpeg-turbo) and XcodeGen; the
  FreeRDP libraries are built without ffmpeg and embedded in the app, so end
  users install nothing.
- The pipeline can only be exercised against a server that offers it; the local
  FreeRDP shadow server does not, so smoothness and file paste both want a real
  Windows host to confirm.
