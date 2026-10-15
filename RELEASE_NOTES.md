## KRemote v1.7.1

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP no longer crashes on connect (regression in v1.7.0).** Switching to
`freerdp_client_context_new` moved the point at which the session's context is
created: `ClientNew` now runs *inside* that call, whereas the old low-level path
let the bridge bind its client into the context afterwards. A channel event
(channel-connected) could therefore fire while `context->client` was still null,
and the clipboard handler dereferenced it — a write to a small offset past address
zero.

The client is now bound inside `ClientNew`, before the context is returned, so it
is never observably unbound; the channel handler also degrades to a no-op rather
than dereferencing a null client. Frame throughput is unchanged: 31 fps measured
against the same host.

All of v1.7.0 down to v1.6.0 is included.







