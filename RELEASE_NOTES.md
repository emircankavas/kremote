## KRemote v1.6.4

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP is much faster.** The graphics pipeline was on, but the codec that makes it
fast was not: `GfxProgressive` (RemoteFX / progressive) is off by default and was
never enabled, so the server had little choice but to send plain bitmaps. It is
now on, along with `GfxProgressiveV2`, `GfxAVC444`, `SoftwareGdi`,
`SupportDynamicChannels` and `DynamicResolutionUpdate` — the set the reference
embedded clients use. This is the difference against a client like mRemoteNXT that
feels fluid on the same host.

**Copying a file into a session works now.** Three pieces of FreeRDP's
file-clipboard protocol were missing, each enough on its own to stop a paste:

- `cliprdr_file_context_set_locally_available` was never called, so the helper's
  capability flags were zero and the file format was never offered at all.
- The server's capability flags were never recorded
  (`cliprdr_file_context_remote_set_flags`), so the helper believed the far end
  had no file support.
- `notify_new_client_format_list` / `notify_new_server_format_list` were never
  called, so its file state was never refreshed.

The file format is also advertised as a *named* format (`FileGroupDescriptorW`),
which is what a server keys a file paste off, and the list is only offered when
the negotiated capability actually allows it — not gated on `has_local_support`,
which is about FUSE and pasting files out of the session.

All of v1.6.3, v1.6.2, v1.6.1 and v1.6.0 is included.



