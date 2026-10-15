## KRemote v1.7.10

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**One header row, not two.** The title and tabs had dropped a row because the
system title bar was still being drawn *and* the app's own header below it. The
window now uses a hidden title bar, so there is a single row at the top holding
the app name, the session tabs immediately to its right, and the session controls
on the far right — the traffic-light buttons float over its leading edge, which
the row insets itself to clear. Right-clicking a tab no longer offers the system
toolbar's customisation menu, since there is no system toolbar to customise.

All of v1.7.9 back to v1.6.0 is included.
















