## KRemote v1.7.8

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**The RDP desktop now matches the pane on the first connection (smart size).**
The previous release made the bridge replay a size request once the Display
Control channel came up, but the request itself was still being lost: the panel
is created before SwiftUI has laid it out, so the connection starts at the
1280×800 fallback, and the view's own `layout()` runs while the session object is
still nil and is not triggered again until the window is resized by hand. The
pane now sends its real size once the layout pass has settled, so the desktop
takes the panel's size from the start. Verified against a live host with a
standalone probe: 1280×720 → 1600×900 arrives as 1600×900.

### Changes

**Tabs are now to the *right* of the app title**, as asked — the title is drawn as
the leading toolbar item and the tab strip follows it immediately.

All of v1.7.7 back to v1.6.0 is included.














