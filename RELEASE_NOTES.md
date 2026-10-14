## KRemote v1.6.3

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**Every RDP frame was being delivered twice.** The graphics pipeline's own
`gdi_OutputUpdate` already calls `EndPaint` after blitting each surface, and the
frame was *also* being handed over from the pipeline's `UpdateSurfaces` override.
So each frame was copied, converted and drawn two times per arrival. The override
now only runs the pipeline's blit; frames leave through the single `EndPaint`
path.

**File paste into a session actually works now.** The previous hand-written file
handling was wrong in ways a server notices immediately:

- The file format was advertised under a bare numeric id. Windows only offers a
  file paste when the format is named (`FileGroupDescriptorW`), so the format was
  never recognised as files.
- `CB_LOCK_CLIPDATA` / `CB_UNLOCK_CLIPDATA` were answered by nobody. The server
  asks for a lock before it reads a file; with no reply it simply waits, which is
  why a paste hung and then did nothing.

Both are now delegated to FreeRDP's own file-clipboard helper
(`cliprdr_file_context`), which is what the reference clients use: it takes the
clipboard's file list as a URI list, owns the file handles, and answers the lock
and file-contents messages itself. The capability set now carries the long
format-name and file-clip flags that leave means the server offers a paste, and
the file list is serialised with the flags the server actually negotiated.

All of v1.6.2, v1.6.1 and v1.6.0 is included.


