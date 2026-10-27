## KRemote 1.9.0 beta 10

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixed: dragging a connection into another folder now works

Dragging a sidebar row never started at all. The row advertised a plain string,
which AppKit's text services claim on a `List`, and the drop handler returned
"accepted" whether or not anything had moved. The tree now uses a private drag
type (`com.emircankavas.kremote.node`), a real `DropDelegate`, and moves the node
on drop.

- Drop on a folder to move the node inside it; drop on a connection to move the
  node beside it, which is the same folder.
- Drop on the empty area below the tree to move back to the top level — there was
  no mouse gesture for "take it out of a folder" before.
- The target row highlights while a drag hovers it, and a drop that the tree
  refuses (a folder into itself or into its own subtree) says so instead of
  silently doing nothing.

### Fixed: the RDP mouse wheel, which only worked downwards

Three faults at once:

- `Int(delta)` truncated a trackpad's fractional deltas to zero, so a gentle
  scroll sent no event at all. Deltas are now accumulated per axis until a whole
  notch is worth sending.
- The vertical sign was inverted, so a downward scroll scrolled up. macOS has
  already applied the "natural scrolling" setting to the event, so no second
  inversion belongs in the client.
- The rotation was scaled by an invented factor of 20 and the negative-rotation
  flag was set the wrong way for the wire format (one notch is 120 units). The
  bridge now encodes it exactly as FreeRDP's own macOS client does.

### New: a desktop-pixel setting for Retina screens, so RDP is readable on a MacBook

The remote desktop was requested at the pane's *backing* pixels (2x on Retina)
while the server was told its UI scale was 100%. On an external 1x monitor that
was invisible; on a MacBook it produced a 2880x1800 desktop with a normal-sized
Windows UI — correct at 2x zoom, unreadable at 1x.

**RDP ▸ Desktop pixels** now chooses:

- **Match panel (readable)**, the default: the desktop is the panel's size in
  points, so Windows' 100% UI is the same physical size it has on a normal
  monitor. Slightly soft on Retina, because the compositor upscales it 2x.
- **Native pixels (crisp)**: the desktop is the Retina grid and the server
  renders its UI at 180%, so text is sharp and still readable.

Inheritable from a folder like the other RDP settings. A custom resolution is
honoured exactly and never multiplied.

### New: Chrome-style session tabs

The tab strip moved out of the title bar into its own full-width row and behaves
like a browser's:

- Tabs share the width and shrink together as more open; below 140 pt they show
  only the icon, and the ones that still do not fit go into an overflow menu with
  a count. The old strip capped itself at 720 pt with a fixed 180 pt per tab, so
  the sixth session was simply off screen.
- A "+" at the end opens the selected connection in a new tab, or starts a new
  connection.
- Tabs can be dragged to reorder them, with a drop indicator between them.
- ⌘1…⌘9 select by position, ⇧⌘[ / ⇧⌘] step between tabs, ⌘W closes the active one.

### Also

- **RDP ▸ Reverse scroll direction** for the case where the wheel still opposes
  the user's habit after the macOS setting is taken into account.

397 core tests pass (21 new); Debug and Release builds succeed.

