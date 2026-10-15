## KRemote v1.7.7

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**"Smart size" now applies on the first connection.** The pane lays out and asks
for the window's size before the session's Display Control channel exists, and a
size request sent before that channel is up was silently dropped — so the desktop
stayed at whatever size the connection was made with until the window happened to
be resized again. The request is now remembered and replayed the moment the
channel connects, so the remote desktop matches the pane from the start.

### Changes

**Tabs show the connection name only.** They used to prefer the title the remote
shell pushed (an OSC escape), so two tabs of the same host could read differently
from the connection the user actually opened. The connection's name is what is
shown now. When the same connection is open more than once, each tab gets a
trailing number — "web 1", "web 2" — so they can be told apart; a lone tab keeps
a clean, unnumbered name.

**Tabs moved to the left of the title bar**, immediately after the window controls
and the app title, instead of sitting centred.

All of v1.7.6 back to v1.6.0 is included.













