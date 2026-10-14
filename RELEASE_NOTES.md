## KRemote v1.6.2

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP plays smoothly instead of hitching.** The graphics pipeline delivers frames
faster than any display can present them, and three things were turning that
into stutter:

- Every frame was converted and assigned to the layer on the main thread as it
  arrived, so a burst of frames queued up and the picture would run behind and
  then jump. Frames now coalesce: only the newest is drawn, so the view shows the
  current desktop rather than a backlog.
- CoreAnimation's implicit animation on `contents` faded between frames. That is
  both wrong for a live desktop and extra main-thread work — the assignment is
  now made without animation.
- `layout()` fires on every relayout and each call sent a Display Control resize
  to the server, which answers with a `ResetGraphics` that tears down and rebuilds
  the graphics surfaces. Identical sizes are now ignored.

All of v1.6.1's and v1.6.0's work is included: the crash fix, the app icon, file
paste into a session, the one-time Keychain migration, and the graphics pipeline.

