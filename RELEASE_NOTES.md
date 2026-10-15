## KRemote v1.7.9

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**Smart size now really does apply on the first connection.** Verified against a
live host: connecting at 1280×800 with the pane's 2400×1400 requested immediately
afterwards now yields 2400×1400 frames.

The Display Control resize was being sent, and accepted by the API, but the
server simply had not applied it — it honours a monitor layout only once the
session has settled, and it gives no acknowledgement. A single request (and even
one with a fixed delay behind it) therefore did nothing. The bridge now uses the
frame size as the signal: while a newer size is pending and frames keep arriving
at the old one, it re-sends the request, at most four times a second and for a
bounded number of attempts, so a server that refuses a size is not spammed.

### Also in this release

**The tab strip no longer sits in the sidebar's title area.** A leading toolbar
item on a `NavigationSplitView` belongs to the *sidebar column*, so the tabs were
drawn inside that region and right-clicking one offered the system toolbar's own
customisation menu ("Icon only", "Icon and text"). The title and tabs are now a
plain row above the sessions, in the detail area: "KRemote" on the left with the
tabs immediately to its right, and no system menu.

All of v1.7.8 back to v1.6.0 is included.















