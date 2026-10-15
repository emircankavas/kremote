## KRemote v1.7.6

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### New

**Session tabs now live in the window's title bar**, on the same line as the
window controls and the session buttons, instead of taking a row of their own
above the session — the Chrome model. Each tab is width-capped so a long title
cannot push its neighbours out of view, and the strip scrolls when there are more
tabs than fit.

### Fixes

**An RDP session that ends now closes its tab.** The pane used to keep the tab
open unless the disconnect came back with no reason, but a server that drops the
connection (logoff, desktop closed, transport lost) reports an error code, so the
tab stayed open on a dead session. Any ended session now closes its tab. A
connection that could not be *established* is treated differently: that keeps the
tab so its reason can be read.

**"Reconnect" now appears when a connection fails**, not only after it drops. A
failed attempt is exactly when a retry is wanted, and it is the one ended state
that leaves the tab on screen.

All of v1.7.5 back to v1.6.0 is included.












