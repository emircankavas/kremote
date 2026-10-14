#ifndef KRDPCLIENT_H
#define KRDPCLIENT_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Lifecycle states reported to `krdp_state_cb`. Mirrors the Swift enum.
typedef enum {
    KRDP_STATE_IDLE = 0,
    KRDP_STATE_CONNECTING = 1,
    KRDP_STATE_CONNECTED = 2,
    KRDP_STATE_DISCONNECTED = 3,
    KRDP_STATE_FAILED = 4
} krdp_state;

/// One decoded frame, in BGRA 32-bit order, top-down, tightly addressed.
/// The pointer is only valid for the duration of the callback.
typedef void (*krdp_frame_cb)(void* user,
                              const uint8_t* bgra,
                              int width,
                              int height,
                              int stride);

/// State changes. `message` is a short human-readable reason (may be NULL).
typedef void (*krdp_state_cb)(void* user, krdp_state state, const char* message);

typedef struct {
    const char* host;
    uint16_t port;
    const char* username;   // may be NULL
    const char* password;   // may be NULL; handed in-process, never to argv
    const char* domain;     // may be NULL
    int width;              // desktop width to request
    int height;             // desktop height to request
    int color_depth;        // 8, 16, 24 or 32
    bool ignore_certificate;
    bool redirect_clipboard;
    bool redirect_drives;
    bool redirect_printers;
    bool redirect_sound;
    bool redirect_keys;
} krdp_descriptor;

/// Opaque client handle.
typedef struct krdp_client krdp_client;

/// True when the FreeRDP library was linked into this build.
bool krdp_is_available(void);

/// FreeRDP's own version string, for diagnostics.
const char* krdp_freerdp_version(void);

/// Creates a client. Returns NULL on allocation failure or when FreeRDP is
/// missing. The descriptor's strings are copied.
krdp_client* krdp_client_create(const krdp_descriptor* descriptor,
                                krdp_frame_cb on_frame,
                                krdp_state_cb on_state,
                                void* user);

/// Connects and runs the session on an internal thread. Returns false when the
/// client could not be started (already running, or no instance).
bool krdp_client_start(krdp_client* client);

/// Stops the session and joins the thread. Safe to call more than once.
void krdp_client_stop(krdp_client* client);

/// Releases the client. Calls `krdp_client_stop` first if needed.
void krdp_client_destroy(krdp_client* client);

/// Asks the server for a new desktop size (Display Control channel).
void krdp_client_resize(krdp_client* client, int width, int height);

/// Sends a mouse event. `button` is a bitmask (1 left, 2 right, 4 middle).
void krdp_client_mouse(krdp_client* client, int x, int y, int button, bool is_down);

/// Sends a mouse move with no button.
void krdp_client_mouse_move(krdp_client* client, int x, int y);

/// Sends a vertical/horizontal wheel delta (in RDP wheel units).
void krdp_client_scroll(krdp_client* client, int delta_x, int delta_y);

/// Sends a key event. `scancode` is a PC set-1 make code; `extended` marks
/// the 0xE0-prefixed variants (arrows, right ctrl/alt, numpad enter...).
void krdp_client_key(krdp_client* client, uint16_t scancode, bool extended, bool is_down);

/// Translates a macOS virtual key code (NSEvent.keyCode) into a PC set-1
/// scancode. Returns 0 when the key has no mapping.
uint16_t krdp_scancode_from_macos(uint16_t macos_keycode, bool* out_extended);

#ifdef __cplusplus
}
#endif

#endif /* KRDPCLIENT_H */
