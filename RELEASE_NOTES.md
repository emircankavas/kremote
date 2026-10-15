## KRemote v1.7.0

Native macOS remote connection manager — RDP and SSH sessions side by side, a
connection tree with folder credential inheritance and mRemoteNG
`confCons.xml` import.

### Fixes

**RDP is fast now — measured 31 fps against a real host, up from under 1.**
The cause was structural, not a setting. This bridge built its session with the
low-level `freerdp_new()` + `freerdp_context_new()` pair, which leaves the client
framework out of the loop: `LoadChannels`, the codec lists and the session
teardown all had to be re-implemented by hand, and the result negotiated a modern
graphics pipeline but then received almost no frames at all — 0.1–0.6 fps with the
server sending AVC420/AVC444 into the void.

It now uses `freerdp_client_context_new` with a client-common context
(`rdpClientContext`, which that path requires), exactly as the reference embedded
clients do, and:

- `PreConnect` is empty — the framework wires the channels from the settings flags
  (`SupportGraphicsPipeline`, `RedirectClipboard`, `SupportDisplayControl`) instead
  of the bridge adding them by name, which also removes a double-listing risk.
- The session loop waits on FreeRDP's own event handles
  (`freerdp_get_event_handles` + `WaitForMultipleObjects`) rather than polling on a
  fixed 50 ms sleep, so an arriving batch is serviced immediately.
- `DesktopScaleFactor` / `DeviceScaleFactor` are set to a wire-legal 100 in both
  slots (FreeRDP 3.27 reads them crossed when building the monitor definition),
  and TCP keepalive is relaxed to 60 s / 4 × 15 s.

Measured with a headless harness driving real input against a Windows host:
**31 fps at 2560×1440 and at 1280×720** (RDP's own target is ~30), with
`rdpgfx`/`disp`/`rspsnd`/`ainput` loading automatically. Before the change the
same harness saw 1 frame in ~8 s.

**Copying a file into a session works** (v1.6.5), via winpr's clipboard and the
`FileGroupDescriptorW` format.

**Passwords saved before v1.5.0 are migrated automatically** (v1.6.0).

### Known limitation

Copying a file *out* of a session is not supported: FreeRDP implements that
direction only under FUSE, and a macOS client also needs a File Provider
extension. That is a separate feature.

### Notes

A lightweight fps/codec counter still writes to
`~/Library/Application Support/KRemote/perf.log` every few seconds; it will come
out once the pacing is confirmed on more hosts.






