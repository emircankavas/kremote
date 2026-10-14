// KRDPClient — a small C bridge between Swift and the FreeRDP client library.
//
// Design notes that matter:
//  * The session runs on its OWN thread (WinPR threads, the same primitives
//    FreeRDP uses internally). `start` returns immediately; `stop` signals the
//    thread and joins it.
//  * Frames reach Swift through GDI's `EndPaint` hook. `gdi->primary_buffer` is
//    only valid for the duration of that callback, so Swift must copy it (it
//    builds a CGImage synchronously) — the buffer is never retained here.
//  * The Display Control channel is picked up through PubSub's
//    `ChannelConnected` event, which is how FreeRDP 3 hands channel contexts to
//    an embedder. That is what makes live resize possible.
//  * The password is passed in-process via the settings object. It never reaches
//    argv, an environment variable or a temporary file.

#include "KRDPClient.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <freerdp/freerdp.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/input.h>
#include <freerdp/update.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>

#include <winpr/synch.h>
#include <winpr/thread.h>
#include <winpr/ssl.h>
#include <winpr/interlocked.h>

// MARK: - Context

/// FreeRDP requires the rdpContext to be the first member of a custom context.
/// FreeRDP 3 dropped the old `rdpContext::custom` field, so the client pointer
/// travels through the typed context instead (see `instances` below).
typedef struct {
    rdpContext context;
    struct krdp_client* client;
    int width;
    int height;
    DispClientContext* disp;
} krdp_context;

/// Looks up the typed context from any base context.
static krdp_context* krdp_ctx(void* context)
{
    return (krdp_context*)((rdpContext*)context);
}

struct krdp_client {
    // Copied configuration.
    char* host;
    uint16_t port;
    char* username;
    char* password;
    char* domain;
    int width;
    int height;
    int color_depth;
    bool ignore_certificate;
    bool redirect_clipboard;
    bool redirect_drives;
    bool redirect_printers;
    bool redirect_sound;
    bool redirect_keys;

    krdp_frame_cb on_frame;
    krdp_state_cb on_state;
    void* user;

    freerdp* instance;
    HANDLE thread;
    HANDLE stop_event;
    volatile LONG running;
};

static bool g_ssl_initialised = false;
static bool g_addins_registered = false;

// MARK: - Helpers

static char* krdp_strdup(const char* s)
{
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* copy = malloc(n);
    if (copy) memcpy(copy, s, n);
    return copy;
}

static void report_state(krdp_client* client, krdp_state state, const char* message)
{
    if (client && client->on_state) client->on_state(client->user, state, message);
}

// MARK: - Frame delivery

static BOOL krdp_end_paint(rdpContext* context)
{
    krdp_context* ctx = krdp_ctx(context);
    krdp_client* client = ctx->client;
    rdpGdi* gdi = context->gdi;
    if (!client || !gdi || !gdi->primary_buffer) return TRUE;

    client->width = (int)gdi->width;
    client->height = (int)gdi->height;
    ctx->width = (int)gdi->width;
    ctx->height = (int)gdi->height;

    if (client->on_frame) {
        client->on_frame(client->user,
                         gdi->primary_buffer,
                         (int)gdi->width,
                         (int)gdi->height,
                         (int)gdi->stride);
    }
    return TRUE;
}

// MARK: - Channels (Display Control -> live resize)

static void krdp_channel_connected(void* ctx, const ChannelConnectedEventArgs* e)
{
    krdp_context* context = krdp_ctx(ctx);
    if (!context || !e || !e->name) return;

    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        context->disp = (DispClientContext*)e->pInterface;
    }
}

// MARK: - Context callbacks

static BOOL krdp_context_new(freerdp* instance, rdpContext* context)
{
    // The client is attached by `krdp_client_create` right after this returns;
    // FreeRDP 3 has no `instance->custom` to carry it through here.
    (void)instance;
    (void)context;
    return TRUE;
}

static void krdp_context_free(freerdp* instance, rdpContext* context)
{
    (void)instance;
    (void)context;
}

static BOOL krdp_pre_connect(freerdp* instance)
{
    rdpContext* context = instance->context;
    PubSub_SubscribeChannelConnected(context->pubSub, krdp_channel_connected);
    return TRUE;
}

static BOOL krdp_post_connect(freerdp* instance)
{
    rdpContext* context = instance->context;

    // Create the GDI drawing surface and take over EndPaint so each completed
    // update is handed to Swift. BGRA32 matches what a CGImage wants.
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    context->update->EndPaint = krdp_end_paint;

    return TRUE;
}

static void krdp_post_disconnect(freerdp* instance)
{
    rdpContext* context = instance->context;
    if (context && context->gdi) gdi_free(instance);
}

// MARK: - Session thread

static DWORD WINAPI krdp_thread(LPVOID arg)
{
    krdp_client* client = (krdp_client*)arg;
    freerdp* instance = client->instance;
    rdpContext* context = instance->context;

    report_state(client, KRDP_STATE_CONNECTING, NULL);

    if (freerdp_connect(instance)) {
        report_state(client, KRDP_STATE_CONNECTED, NULL);

        // Poll for a stop request instead of blocking, so the session keeps
        // draining the socket. While connected the only definitive end is
        // FreeRDP asking to disconnect (the server dropped us, or `disconnect`
        // was called); a transient error is tolerated rather than treated as
        // fatal, so a hiccup cannot kill a live session.
        while (client->running) {
            if (WaitForSingleObject(client->stop_event, 50) == WAIT_OBJECT_0) break;
            if (freerdp_shall_disconnect_context(context)) break;
            (void)freerdp_check_event_handles(context);
        }
    } else {
        UINT32 last = freerdp_get_last_error(context);
        const char* name = freerdp_get_last_error_string(last);
        report_state(client, KRDP_STATE_FAILED, name ? name : "connection failed");
        return 0;
    }

    // Report a reason when the server dropped us, so the pane keeps the tab and
    // shows why instead of closing silently; a clean local stop passes nil.
    UINT32 last = freerdp_get_last_error(context);
    const char* name = (last != 0) ? freerdp_get_last_error_string(last) : NULL;
    freerdp_disconnect(instance);
    report_state(client, KRDP_STATE_DISCONNECTED, (name && *name) ? name : NULL);
    return 0;
}

// MARK: - Public API

bool krdp_is_available(void) { return true; }

const char* krdp_freerdp_version(void) { return FREERDP_VERSION_FULL; }

krdp_client* krdp_client_create(const krdp_descriptor* descriptor,
                                krdp_frame_cb on_frame,
                                krdp_state_cb on_state,
                                void* user)
{
    if (!descriptor || !descriptor->host) return NULL;

    if (!g_ssl_initialised) {
        winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT);
        g_ssl_initialised = true;
    }
    if (!g_addins_registered) {
        // Loads the static channel addins (GDI, Display Control, clipboard...)
        // that WITH_CLIENT_COMMON built in.
        freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);
        g_addins_registered = true;
    }

    krdp_client* client = calloc(1, sizeof(krdp_client));
    if (!client) return NULL;

    client->host = krdp_strdup(descriptor->host);
    client->username = krdp_strdup(descriptor->username);
    client->password = krdp_strdup(descriptor->password);
    client->domain = krdp_strdup(descriptor->domain);
    client->port = descriptor->port ? descriptor->port : 3389;
    client->width = descriptor->width > 0 ? descriptor->width : 1280;
    client->height = descriptor->height > 0 ? descriptor->height : 800;
    client->color_depth = descriptor->color_depth > 0 ? descriptor->color_depth : 32;
    client->ignore_certificate = descriptor->ignore_certificate;
    client->redirect_clipboard = descriptor->redirect_clipboard;
    client->redirect_drives = descriptor->redirect_drives;
    client->redirect_printers = descriptor->redirect_printers;
    client->redirect_sound = descriptor->redirect_sound;
    client->redirect_keys = descriptor->redirect_keys;
    client->on_frame = on_frame;
    client->on_state = on_state;
    client->user = user;

    client->instance = freerdp_new();
    if (!client->instance) { krdp_client_destroy(client); return NULL; }

    client->instance->ContextSize = sizeof(krdp_context);
    client->instance->ContextNew = krdp_context_new;
    client->instance->ContextFree = krdp_context_free;
    client->instance->PreConnect = krdp_pre_connect;
    client->instance->PostConnect = krdp_post_connect;
    client->instance->PostDisconnect = krdp_post_disconnect;

    if (!freerdp_context_new(client->instance)) {
        krdp_client_destroy(client);
        return NULL;
    }
    // Bind the client into its own context: FreeRDP 3 has no shared `custom`
    // field, so this typed slot is how the callbacks find their way back.
    krdp_ctx(client->instance->context)->client = client;

    rdpSettings* s = client->instance->context->settings;

    freerdp_settings_set_string(s, FreeRDP_ServerHostname, client->host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, client->port);
    if (client->username) freerdp_settings_set_string(s, FreeRDP_Username, client->username);
    if (client->password) freerdp_settings_set_string(s, FreeRDP_Password, client->password);
    if (client->domain && *client->domain) freerdp_settings_set_string(s, FreeRDP_Domain, client->domain);

    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)client->width);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)client->height);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, (UINT32)client->color_depth);
    // Let the server resize us on demand (drives the Display Control channel).
    freerdp_settings_set_bool(s, FreeRDP_DesktopResize, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, client->ignore_certificate ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, client->redirect_clipboard ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectDrives, client->redirect_drives ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectPrinters, client->redirect_printers ? TRUE : FALSE);
    // Note: there is no server-side "redirect key combinations" setting — whether
    // Alt+Tab and friends go to the remote is a client keyboard-grab decision,
    // so `redirect_keys` stays a KRemote-side flag.
    (void)client->redirect_keys;
    // `AudioPlayback` and `ConnectionType` have specific types in FreeRDP 3:
    // the first is a BOOL (enable audio playback), the second a UINT32 hint.
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, client->redirect_sound ? TRUE : FALSE);
    // Accept the server's certificate without a modal prompt; the UI surfaces it.
    freerdp_settings_set_bool(s, FreeRDP_AutoAcceptCertificate, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_Workarea, FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_ConnectionType, 0 /* CONNECTION_TYPE_AUTODETECT */);
    freerdp_settings_set_bool(s, FreeRDP_NetworkAutoDetect, TRUE);

    return client;
}

bool krdp_client_start(krdp_client* client)
{
    if (!client || !client->instance) return false;
    if (InterlockedCompareExchange(&client->running, 1, 0) != 0) return false;

    client->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!client->stop_event) { client->running = 0; return false; }

    client->thread = CreateThread(NULL, 0, krdp_thread, client, 0, NULL);
    if (!client->thread) {
        CloseHandle(client->stop_event);
        client->stop_event = NULL;
        client->running = 0;
        return false;
    }
    return true;
}

void krdp_client_stop(krdp_client* client)
{
    if (!client) return;
    if (InterlockedCompareExchange(&client->running, 0, 1) == 0) {
        // Was not running; still make sure resources are released below.
    }
    if (client->stop_event) SetEvent(client->stop_event);
    if (client->thread) {
        WaitForSingleObject(client->thread, INFINITE);
        CloseHandle(client->thread);
        client->thread = NULL;
    }
    if (client->stop_event) {
        CloseHandle(client->stop_event);
        client->stop_event = NULL;
    }
}

void krdp_client_destroy(krdp_client* client)
{
    if (!client) return;
    krdp_client_stop(client);
    if (client->instance) {
        freerdp_context_free(client->instance);
        freerdp_free(client->instance);
        client->instance = NULL;
    }
    free(client->host);
    free(client->username);
    free(client->domain);
    if (client->password) {
        // Do not leave the password in freed-but-reachable memory longer than
        // necessary.
        memset(client->password, 0, strlen(client->password));
        free(client->password);
    }
    free(client);
}

void krdp_client_resize(krdp_client* client, int width, int height)
{
    if (!client || !client->instance) return;
    rdpContext* context = client->instance->context;
    krdp_context* ctx = (krdp_context*)context;
    if (!context || !ctx->disp || width <= 0 || height <= 0) return;

    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = 1;  // DISPLAY_CONTROL_MONITOR_PRIMARY
    layout.Left = 0;
    layout.Top = 0;
    layout.Width = (UINT32)width;
    layout.Height = (UINT32)height;
    layout.PhysicalWidth = (UINT32)width;
    layout.PhysicalHeight = (UINT32)height;
    layout.Orientation = 0;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;

    ctx->disp->SendMonitorLayout(ctx->disp, 1, &layout);
}

void krdp_client_mouse(krdp_client* client, int x, int y, int button, bool is_down)
{
    if (!client || !client->instance) return;
    rdpInput* input = client->instance->context->input;
    if (!input) return;

    // RDP requires the button bit on BOTH the press and the release. Sending a
    // press with only PTR_FLAGS_DOWN (no button) is a protocol violation the
    // server answers by dropping the connection — which is exactly what a click
    // used to do. This mirrors FreeRDP's own macOS client (mf_press_mouse_button).
    UINT16 flags;
    switch (button) {
    case 1: flags = PTR_FLAGS_BUTTON1; break;
    case 2: flags = PTR_FLAGS_BUTTON2; break;
    case 4: flags = PTR_FLAGS_BUTTON3; break;
    default:
        // No button (e.g. a plain move) -> a bare move is always well-formed.
        freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
        return;
    }
    if (is_down) flags |= PTR_FLAGS_DOWN;
    // The public helper (rather than input->MouseEvent) also updates FreeRDP's
    // last-event bookkeeping, which keeps the client and server state in sync.
    freerdp_input_send_mouse_event(input, flags, (UINT16)x, (UINT16)y);
}

void krdp_client_mouse_move(krdp_client* client, int x, int y)
{
    if (!client || !client->instance) return;
    rdpInput* input = client->instance->context->input;
    if (!input) return;
    freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
}

void krdp_client_scroll(krdp_client* client, int delta_x, int delta_y)
{
    if (!client || !client->instance) return;
    rdpInput* input = client->instance->context->input;
    if (!input) return;
    if (delta_y != 0) {
        UINT16 flags = PTR_FLAGS_WHEEL;
        int amount = delta_y * 20;
        if (amount > 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        if (amount > 255) amount = 255;
        if (amount < -255) amount = -255;
        freerdp_input_send_mouse_event(input, flags, 0, (UINT16)(abs(amount) & 0xFF));
    }
    if (delta_x != 0) {
        UINT16 flags = PTR_FLAGS_HWHEEL;
        int amount = delta_x * 20;
        if (amount > 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE;
        if (amount > 255) amount = 255;
        if (amount < -255) amount = -255;
        freerdp_input_send_mouse_event(input, flags, 0, (UINT16)(abs(amount) & 0xFF));
    }
}

void krdp_client_key(krdp_client* client, uint16_t scancode, bool extended, bool is_down)
{
    if (!client || !client->instance || scancode == 0) return;
    rdpInput* input = client->instance->context->input;
    if (!input) return;
    UINT16 flags = is_down ? 0 : KBD_FLAGS_RELEASE;
    if (extended) flags |= KBD_FLAGS_EXTENDED;
    freerdp_input_send_keyboard_event(input, flags, (UINT8)scancode);
}

// MARK: - macOS -> PC scancode table

uint16_t krdp_scancode_from_macos(uint16_t macos_keycode, bool* out_extended)
{
    if (out_extended) *out_extended = false;

    switch (macos_keycode) {
    // Letters
    case 0:  return 0x1E; // A
    case 1:  return 0x1F; // S
    case 2:  return 0x20; // D
    case 3:  return 0x21; // F
    case 4:  return 0x23; // H
    case 5:  return 0x22; // G
    case 6:  return 0x2C; // Z
    case 7:  return 0x2D; // X
    case 8:  return 0x2E; // C
    case 9:  return 0x2F; // V
    case 11: return 0x30; // B
    case 12: return 0x10; // Q
    case 13: return 0x11; // W
    case 14: return 0x12; // E
    case 15: return 0x13; // R
    case 16: return 0x15; // Y
    case 17: return 0x14; // T
    case 31: return 0x18; // O
    case 32: return 0x16; // U
    case 34: return 0x17; // I
    case 35: return 0x19; // P
    case 37: return 0x26; // L
    case 38: return 0x24; // J
    case 40: return 0x25; // K
    case 45: return 0x31; // N
    case 46: return 0x32; // M
    // Digits
    case 18: return 0x02; // 1
    case 19: return 0x03; // 2
    case 20: return 0x04; // 3
    case 21: return 0x05; // 4
    case 22: return 0x07; // 6
    case 23: return 0x06; // 5
    case 25: return 0x0A; // 9
    case 26: return 0x08; // 7
    case 28: return 0x09; // 8
    case 29: return 0x0B; // 0
    // Punctuation
    case 24: return 0x0D; // =
    case 27: return 0x0C; // -
    case 30: return 0x1B; // ]
    case 33: return 0x1A; // [
    case 39: return 0x28; // '
    case 41: return 0x27; // ;
    case 42: return 0x2B; // backslash
    case 43: return 0x33; // ,
    case 44: return 0x35; // /
    case 47: return 0x34; // .
    case 50: return 0x29; // `
    // Control keys
    case 36: return 0x1C; // Return
    case 48: return 0x0F; // Tab
    case 49: return 0x39; // Space
    case 51: return 0x0E; // Delete (backspace)
    case 53: return 0x01; // Escape
    case 56: return 0x2A; // Left Shift
    case 60: return 0x36; // Right Shift
    case 57: return 0x3A; // Caps Lock
    case 59: return 0x1D; // Left Control
    case 62: if (out_extended) *out_extended = true; return 0x1D; // Right Control (extended)
    case 58: return 0x38; // Left Option -> Alt
    case 61: if (out_extended) *out_extended = true; return 0x38; // Right Option -> Alt (extended)
    case 55: if (out_extended) *out_extended = true; return 0x5B; // Left Command -> LWIN
    case 54: if (out_extended) *out_extended = true; return 0x5C; // Right Command -> RWIN
    // Function keys
    case 122: return 0x3B; // F1
    case 120: return 0x3C; // F2
    case 99:  return 0x3D; // F3
    case 118: return 0x3E; // F4
    case 96:  return 0x3F; // F5
    case 97:  return 0x40; // F6
    case 98:  return 0x41; // F7
    case 100: return 0x42; // F8
    case 101: return 0x43; // F9
    case 109: return 0x44; // F10
    case 103: return 0x57; // F11
    case 111: return 0x58; // F12
    // Navigation (all extended)
    case 123: if (out_extended) *out_extended = true; return 0x4B; // Left
    case 124: if (out_extended) *out_extended = true; return 0x4D; // Right
    case 125: if (out_extended) *out_extended = true; return 0x50; // Down
    case 126: if (out_extended) *out_extended = true; return 0x48; // Up
    case 115: if (out_extended) *out_extended = true; return 0x47; // Home
    case 119: if (out_extended) *out_extended = true; return 0x4F; // End
    case 116: if (out_extended) *out_extended = true; return 0x49; // Page Up
    case 121: if (out_extended) *out_extended = true; return 0x51; // Page Down
    case 117: if (out_extended) *out_extended = true; return 0x53; // Forward Delete
    case 114: if (out_extended) *out_extended = true; return 0x52; // Help/Insert
    default: return 0;
    }
}
