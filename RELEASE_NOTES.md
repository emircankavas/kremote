## KRemote v1.7.5

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**A newly created connection shows its address immediately.** Saving an edit left
the sidebar row reading "not configured" until the app was relaunched. The row
took its resolved settings as an input value, and a `ConnectionNode` is a
reference type — editing one mutates it in place, changing no observable
`AppModel` property except `roots` (which is reassigned on save). A row that
read none of that state was reused unchanged by SwiftUI, so its subtitle kept the
value it had when the row was first built. The row now resolves its settings
inside its own body, which is what subscribes it to the save, and the subtitle
updates at once.

The editor sheet also reloads its fields from the node's id rather than a
once-set flag, so a reused sheet can never show the previous node's values.

All of v1.7.4 back to v1.6.0 is included.











