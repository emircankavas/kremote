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
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/utils/cliprdr_utils.h>
#include <winpr/user.h>   /* CF_UNICODETEXT / CF_TEXT */
#include <winpr/clipboard.h> /* wClipboard: file list <-> FILEDESCRIPTORW */
#include <winpr/shell.h>  /* FILEDESCRIPTORW */
#include <winpr/file.h>   /* FILE_ATTRIBUTE_* */

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
    CliprdrClientContext* cliprdr;
    RdpgfxClientContext* gfx;
    /// The `UpdateSurfaces` that `gdi_graphics_pipeline_init` installed. It is
    /// what blits decoded surfaces into the GDI framebuffer, so our override has
    /// to call it first — replacing it outright is what leaves the screen blank.
    pcRdpgfxUpdateSurfaces gfx_base_update_surfaces;
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
    krdp_credentials_cb on_credentials;
    krdp_clipboard_cb on_clipboard;
    void* user;

    // Credential/authentication flow: the session thread asks, then waits.
    HANDLE credentials_event;
    char* pending_username;
    char* pending_domain;
    char* pending_password;
    bool credentials_aborted;

    // Clipboard: the local text we advertise, guarded because the channel and
    // the UI thread both touch it.
    CRITICAL_SECTION clipboard_lock;
    char* clipboard_text;

    // File clipboard (Mac -> remote). Each entry is one absolute local path.
    char** clipboard_files;
    int clipboard_file_count;
    /// FreeRDP's file-clipboard helper. It owns the file handles, answers the
    /// lock/unlock and FILECONTENTS messages, and claims `cliprdr->custom`.
    /// Remote -> Mac is not supported: that path needs FUSE, absent here.
    CliprdrFileContext* cliprdr_file;
    /// winpr clipboard backing the file format. Files are handed in as a
    /// `text/uri-list`; winpr stats every path (descending into folders) and
    /// produces the `FILEDESCRIPTORW` list a server pastes from. `clipboard_file_format_id`
    /// is the id `FileGroupDescriptorW` is registered under, and is what the
    /// format list must advertise — not a raw CF_HDROP.
    wClipboard* clipboard;
    UINT32 clipboard_file_format_id;

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

// MARK: - Clipboard (cliprdr)

/// Appends the UTF-8 encoding of `cp` at `out`; returns the byte count.
static size_t krdp_utf8_encode(UINT32 cp, char* out)
{
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

/// UTF-16LE (as CF_UNICODETEXT arrives) to a fresh UTF-8 string, or NULL.
static char* krdp_utf16le_to_utf8(const BYTE* data, UINT32 len)
{
    if (!data || len < 2) return NULL;
    UINT32 units = len / 2;
    // Windows terminates CF_UNICODETEXT with a NUL; drop it.
    while (units > 0 && data[(units - 1) * 2] == 0 && data[(units - 1) * 2 + 1] == 0) units--;

    char* out = malloc((size_t)units * 4 + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (UINT32 i = 0; i < units; i++) {
        UINT32 cp = (UINT32)(data[i * 2] | (data[i * 2 + 1] << 8));
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < units) {
            UINT32 lo = (UINT32)(data[(i + 1) * 2] | (data[(i + 1) * 2 + 1] << 8));
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                i++;
            }
        }
        o += krdp_utf8_encode(cp, out + o);
    }
    out[o] = '\0';
    return out;
}

/// UTF-8 to a fresh UTF-16LE buffer (with a terminating NUL), or NULL.
static BYTE* krdp_utf8_to_utf16le(const char* utf8, UINT32* out_len)
{
    if (!utf8) return NULL;
    size_t n = strlen(utf8);
    BYTE* out = malloc((n + 1) * 2 + 2);
    if (!out) return NULL;
    size_t i = 0, o = 0;
    while (i < n) {
        UINT32 cp = (unsigned char)utf8[i];
        size_t extra = 0;
        if (cp >= 0xF0) { cp &= 0x07; extra = 3; }
        else if (cp >= 0xE0) { cp &= 0x0F; extra = 2; }
        else if (cp >= 0xC0) { cp &= 0x1F; extra = 1; }
        for (size_t k = 1; k <= extra && i + k < n; k++) {
            cp = (cp << 6) | ((unsigned char)utf8[i + k] & 0x3F);
        }
        i += extra + 1;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            UINT16 hi = (UINT16)(0xD800 + (cp >> 10));
            UINT16 lo = (UINT16)(0xDC00 + (cp & 0x3FF));
            out[o++] = (BYTE)(hi & 0xFF); out[o++] = (BYTE)(hi >> 8);
            out[o++] = (BYTE)(lo & 0xFF); out[o++] = (BYTE)(lo >> 8);
        } else {
            out[o++] = (BYTE)(cp & 0xFF); out[o++] = (BYTE)(cp >> 8);
        }
    }
    out[o++] = 0; out[o++] = 0;   // terminating NUL, as Windows expects
    if (out_len) *out_len = (UINT32)o;
    return out;
}

// MARK: - File clipboard (Mac -> remote)

/// The format name Windows uses for a file list. FreeRDP's clipboard layer keys
/// its file handling off this exact string (`xf_cliprdr.c` does the same), and a
/// server only offers the paste path when the name is present.
static const char krdp_file_descriptor_name[] = "FileGroupDescriptorW";

/// Our client, reached through the clipboard channel's context.
///
/// `cliprdr_file_context_init` claims `cliprdr->custom` for the file context, so
/// the client travels the other way: it is the `void*` handed to
/// `cliprdr_file_context_new`, and comes back out through
/// `cliprdr_file_context_get_context`.
static krdp_client* krdp_client_from_cliprdr(CliprdrClientContext* ctx)
{
    CliprdrFileContext* file = ctx ? (CliprdrFileContext*)ctx->custom : NULL;
    return file ? (krdp_client*)cliprdr_file_context_get_context(file) : NULL;
}

/// Builds the `CLIPRDR_FILELIST` for the files currently on the clipboard, or NULL
/// when there are none.
///
/// The conversion is winpr's job, not ours: the paths go in as a `text/uri-list`,
/// winpr stats every entry (descending into folders, which is what a server
/// expects) and produces the `FILEDESCRIPTORW` records, and FreeRDP serialises
/// those. Hand-rolling descriptors from `stat(2)` gets the relative-path and
/// folder semantics wrong, and the paste silently does nothing.
static BYTE* krdp_build_file_list(krdp_client* client, UINT32* out_len)
{
    if (!client || !client->clipboard || client->clipboard_file_count <= 0) return NULL;
    if (client->clipboard_file_format_id == 0) return NULL;

    const UINT32 uriId = ClipboardGetFormatId(client->clipboard, "text/uri-list");
    if (uriId == 0) return NULL;

    // Assemble the URI list outside the lock, then hand it in.
    size_t capacity = 16;
    for (int i = 0; i < client->clipboard_file_count; i++) {
        capacity += strlen(client->clipboard_files[i]) + 12;
    }
    char* uriList = calloc(1, capacity);
    if (!uriList) return NULL;
    for (int i = 0; i < client->clipboard_file_count; i++) {
        strcat(uriList, "file://");
        strcat(uriList, client->clipboard_files[i]);
        strcat(uriList, "\r\n");
    }

    BYTE* out = NULL;
    ClipboardLock(client->clipboard);
    if (ClipboardSetData(client->clipboard, uriId, uriList, (UINT32)strlen(uriList))) {
        UINT32 descSize = 0;
        FILEDESCRIPTORW* desc = ClipboardGetData(client->clipboard, client->clipboard_file_format_id, &descSize);
        if (desc) {
            const UINT32 count = descSize / sizeof(FILEDESCRIPTORW);
            // Mirror the flags the server negotiated; it rejects a list whose
            // format does not match what was agreed.
            const UINT32 flags = cliprdr_file_context_remote_get_flags(client->cliprdr_file);
            UINT32 outSize = 0;
            if (cliprdr_serialize_file_list_ex(flags, desc, count, &out, &outSize) == CHANNEL_RC_OK) {
                if (out_len) *out_len = outSize;
            } else {
                free(out);
                out = NULL;
            }
            free(desc);
        }
    }
    ClipboardUnlock(client->clipboard);
    free(uriList);
    return out;
}

/// Pushes the file list into FreeRDP's file context, which needs the same
/// `text/uri-list` to serve the bytes later: it walks the folders itself and
/// matches the server's list index against its own.
static void krdp_update_file_context(krdp_client* client)
{
    if (!client || !client->cliprdr_file || client->clipboard_file_count <= 0) return;

    size_t capacity = 16;
    for (int i = 0; i < client->clipboard_file_count; i++) {
        capacity += strlen(client->clipboard_files[i]) + 12;
    }
    char* list = calloc(1, capacity);
    if (!list) return;
    for (int i = 0; i < client->clipboard_file_count; i++) {
        strcat(list, "file://");
        strcat(list, client->clipboard_files[i]);   // absolute, so file:///…
        strcat(list, "\r\n");
    }
    cliprdr_file_context_update_client_data(client->cliprdr_file, list, strlen(list));
    free(list);
}

/// Announces the local clipboard's current formats. Files, when present, are
/// offered under the file-list format name; text keeps its own entry.
static UINT krdp_cliprdr_send_format_list(CliprdrClientContext* ctx, bool hasText)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);

    CLIPRDR_FORMAT formats[2];
    memset(formats, 0, sizeof(formats));
    UINT32 count = 0;
    if (hasText) {
        formats[count].formatId = CF_UNICODETEXT;
        formats[count].formatName = NULL;
        count++;
    }
    if (client && client->clipboard_file_count > 0 && client->cliprdr_file &&
        client->clipboard_file_format_id != 0 &&
        (cliprdr_file_context_current_flags(client->cliprdr_file) & CB_STREAM_FILECLIP_ENABLED)) {
        // The *registered* id for FileGroupDescriptorW, not a raw CF_HDROP: the
        // server matches the format by name, and winpr's synthesizer (below) is
        // what turns a URI list into a FILEDESCRIPTORW list under this id.
        formats[count].formatId = client->clipboard_file_format_id;
        formats[count].formatName = (char*)krdp_file_descriptor_name;
        count++;
        cliprdr_file_context_notify_new_client_format_list(client->cliprdr_file);
    }

    CLIPRDR_FORMAT_LIST list;
    memset(&list, 0, sizeof(list));
    list.common.msgType = CB_FORMAT_LIST;
    list.common.msgFlags = 0;
    list.numFormats = count;
    list.formats = formats;
    return ctx->ClientFormatList(ctx, &list);
}

static UINT krdp_cliprdr_monitor_ready(CliprdrClientContext* ctx, const CLIPRDR_MONITOR_READY* monitorReady)
{
    (void)monitorReady;
    krdp_client* client = krdp_client_from_cliprdr(ctx);

    // Announce capabilities, then whatever the local clipboard holds. Without
    // this the channel never becomes usable and nothing can be copied either way.
    CLIPRDR_GENERAL_CAPABILITY_SET general;
    memset(&general, 0, sizeof(general));
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    // Long format names are what let us name the file format; the file context
    // contributes the streaming/lock flags it actually supports. Both are needed
    // for the server to offer a file paste at all.
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    if (client && client->cliprdr_file) {
        general.generalFlags |= cliprdr_file_context_current_flags(client->cliprdr_file);
    }

    CLIPRDR_CAPABILITIES caps;
    memset(&caps, 0, sizeof(caps));
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
    ctx->ClientCapabilities(ctx, &caps);

    bool hasText = false;
    if (client) {
        EnterCriticalSection(&client->clipboard_lock);
        hasText = (client->clipboard_text != NULL);
        LeaveCriticalSection(&client->clipboard_lock);
    }
    return krdp_cliprdr_send_format_list(ctx, hasText);
}

static UINT krdp_cliprdr_server_capabilities(CliprdrClientContext* ctx, const CLIPRDR_CAPABILITIES* caps)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);
    if (!client || !client->cliprdr_file || !caps) return CHANNEL_RC_OK;

    // Record what the *server* supports before we answer: `current_flags` and the
    // file list's serialisation both read these, and until they are stored the
    // helper reports no file capability at all.
    for (UINT32 i = 0; i < caps->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET* set = &caps->capabilitySets[i];
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL &&
            set->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) {
            const CLIPRDR_GENERAL_CAPABILITY_SET* general =
                (const CLIPRDR_GENERAL_CAPABILITY_SET*)set;
            cliprdr_file_context_remote_set_flags(client->cliprdr_file, general->generalFlags);
        }
    }
    return CHANNEL_RC_OK;
}

static UINT krdp_cliprdr_server_format_list(CliprdrClientContext* ctx, const CLIPRDR_FORMAT_LIST* list)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);
    // A new remote clipboard invalidates whatever file state the helper held for
    // the previous one.
    if (client && client->cliprdr_file) {
        cliprdr_file_context_notify_new_server_format_list(client->cliprdr_file);
    }

    CLIPRDR_FORMAT_LIST_RESPONSE response;
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    ctx->ClientFormatListResponse(ctx, &response);

    // Ask for the content straight away: prefer Unicode, fall back to ANSI.
    UINT32 wanted = 0;
    for (UINT32 i = 0; list && i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT) { wanted = CF_UNICODETEXT; break; }
        if (list->formats[i].formatId == CF_TEXT && wanted == 0) wanted = CF_TEXT;
    }
    if (wanted == 0) return CHANNEL_RC_OK;

    CLIPRDR_FORMAT_DATA_REQUEST request;
    memset(&request, 0, sizeof(request));
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.common.msgFlags = 0;
    request.requestedFormatId = wanted;
    return ctx->ClientFormatDataRequest(ctx, &request);
}

static UINT krdp_cliprdr_server_format_list_response(CliprdrClientContext* ctx,
                                                     const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
    (void)ctx; (void)response;
    return CHANNEL_RC_OK;
}

/// The server asks for the local clipboard's content (the user pressed paste).
static UINT krdp_cliprdr_server_format_data_request(CliprdrClientContext* ctx,
                                                    const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);
    BYTE* data = NULL;
    UINT32 length = 0;

    if (client && request->requestedFormatId == CF_UNICODETEXT) {
        EnterCriticalSection(&client->clipboard_lock);
        if (client->clipboard_text) data = krdp_utf8_to_utf16le(client->clipboard_text, &length);
        LeaveCriticalSection(&client->clipboard_lock);
    } else if (client && client->clipboard_file_format_id != 0 &&
               request->requestedFormatId == client->clipboard_file_format_id) {
        // The packed file list answers the request for the file format; the
        // server then pulls each file's bytes through the file context, which
        // answers CB_FILECONTENTS_* on our behalf.
        data = krdp_build_file_list(client, &length);
    }

    CLIPRDR_FORMAT_DATA_RESPONSE response;
    memset(&response, 0, sizeof(response));
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (data) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = length;
        response.requestedFormatData = data;
        ctx->ClientFormatDataResponse(ctx, &response);
        free(data);
    } else {
        // Nothing to give, or a format we do not serve: fail explicitly so the
        // server does not wait for a reply that never comes.
        response.common.msgFlags = CB_RESPONSE_FAIL;
        response.common.dataLen = 0;
        response.requestedFormatData = NULL;
        ctx->ClientFormatDataResponse(ctx, &response);
    }
    return CHANNEL_RC_OK;
}

/// The content the server sent in answer to our request.
static UINT krdp_cliprdr_server_format_data_response(CliprdrClientContext* ctx,
                                                     const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);
    if (!client || !client->on_clipboard) return CHANNEL_RC_OK;

    char* utf8 = NULL;
    if ((response->common.msgFlags & CB_RESPONSE_OK) && response->requestedFormatData) {
        utf8 = krdp_utf16le_to_utf8(response->requestedFormatData, response->common.dataLen);
    }
    // An empty string is meaningful: the remote clipboard was cleared.
    client->on_clipboard(client->user, utf8 ? utf8 : "");
    free(utf8);
    return CHANNEL_RC_OK;
}

void krdp_client_set_clipboard(krdp_client* client, const char* utf8)
{
    if (!client) return;

    EnterCriticalSection(&client->clipboard_lock);
    free(client->clipboard_text);
    client->clipboard_text = (utf8 && *utf8) ? krdp_strdup(utf8) : NULL;
    bool hasText = (client->clipboard_text != NULL);
    krdp_context* ctx = client->instance ? krdp_ctx(client->instance->context) : NULL;
    CliprdrClientContext* cliprdr = (ctx && ctx->cliprdr) ? ctx->cliprdr : NULL;
    // Announcing from here (the UI thread) is how FreeRDP's own clients do it;
    // the channel takes its own lock.
    if (cliprdr) krdp_cliprdr_send_format_list(cliprdr, hasText);
    LeaveCriticalSection(&client->clipboard_lock);
}

void krdp_client_set_clipboard_files(krdp_client* client, const char* const* paths, int count)
{
    if (!client) return;

    EnterCriticalSection(&client->clipboard_lock);
    for (int i = 0; i < client->clipboard_file_count; i++) free(client->clipboard_files[i]);
    free(client->clipboard_files);
    client->clipboard_files = NULL;
    client->clipboard_file_count = 0;

    if (paths && count > 0) {
        char** copy = calloc((size_t)count, sizeof(char*));
        if (copy) {
            int kept = 0;
            for (int i = 0; i < count; i++) {
                if (paths[i]) copy[kept++] = krdp_strdup(paths[i]);
            }
            client->clipboard_files = copy;
            client->clipboard_file_count = kept;
        }
    }

    // Hand the new list to FreeRDP's file context before announcing, so the
    // handles exist by the time the server asks for bytes.
    if (client->cliprdr_file) {
        if (client->clipboard_file_count > 0) {
            krdp_update_file_context(client);
        } else {
            cliprdr_file_context_clear(client->cliprdr_file);
        }
    }

    bool hasText = (client->clipboard_text != NULL);
    krdp_context* ctx = client->instance ? krdp_ctx(client->instance->context) : NULL;
    CliprdrClientContext* cliprdr = (ctx && ctx->cliprdr) ? ctx->cliprdr : NULL;
    if (cliprdr) krdp_cliprdr_send_format_list(cliprdr, hasText);
    LeaveCriticalSection(&client->clipboard_lock);
}

// MARK: - Graphics pipeline (rdpgfx)

/// Rebuilds the GDI framebuffer at the size the server announced.
///
/// FreeRDP has no default implementation on the client side: the X11/SDL clients
/// each provide their own and it is called from `gdi_ResetGraphics` (which the
/// graphics pipeline sends on every connect and resize). Leaving it NULL crashes
/// the moment GFX starts, on the frame the server resizes us — `WINPR_ASSERT`s
/// are compiled out in release builds, so the call goes straight to address 0.
static BOOL krdp_desktop_resize(rdpContext* context)
{
    if (!context || !context->gdi) return FALSE;
    rdpGdi* gdi = context->gdi;
    const rdpSettings* settings = context->settings;
    if (!settings) return FALSE;

    // Do not let a frame be painted from the buffer we are about to replace.
    const BOOL suppress = gdi->suppressOutput;
    gdi->suppressOutput = TRUE;
    const BOOL ok = gdi_resize(gdi,
                               freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                               freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
    gdi->suppressOutput = suppress;
    return ok;
}

/// Called by the GDI graphics pipeline once a surface has been drawn into the
/// GDI framebuffer.
///
/// **This is not where frames are handed to Swift.** `gdi_OutputUpdate` (the base
/// callback below) already calls `update_end_paint` after blitting each surface,
/// and `EndPaint` is hooked in `krdp_end_paint`. Sending the buffer here as well
/// made every frame be copied and drawn twice, which is what made a busy desktop
/// stutter. This override exists only to run the base blit; the frame leaves via
/// `EndPaint`.
static UINT krdp_gfx_UpdateSurfaces(RdpgfxClientContext* context)
{
    // `gdi_graphics_pipeline_init` sets `gfx->custom` to the rdpGdi, not to our
    // typed context, so reach the base callback through the GDI's rdpContext.
    rdpGdi* gdi = context ? (rdpGdi*)context->custom : NULL;
    krdp_context* ctx = gdi ? krdp_ctx(gdi->context) : NULL;
    if (!ctx) return CHANNEL_RC_OK;

    if (ctx->gfx_base_update_surfaces) {
        return ctx->gfx_base_update_surfaces(context);
    }
    return CHANNEL_RC_OK;
}

// MARK: - Channels (Display Control -> live resize)

/// Wires up the channel contexts the app needs. FreeRDP 3 hands them out through
/// the ChannelConnected PubSub event.
static void krdp_channel_connected(void* ctx, const ChannelConnectedEventArgs* e)
{
    krdp_context* context = krdp_ctx(ctx);
    if (!context || !e || !e->name) return;

    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        context->disp = (DispClientContext*)e->pInterface;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext* cliprdr = (CliprdrClientContext*)e->pInterface;
        context->cliprdr = cliprdr;
        cliprdr->MonitorReady = krdp_cliprdr_monitor_ready;
        cliprdr->ServerCapabilities = krdp_cliprdr_server_capabilities;
        cliprdr->ServerFormatList = krdp_cliprdr_server_format_list;
        cliprdr->ServerFormatListResponse = krdp_cliprdr_server_format_list_response;
        cliprdr->ServerFormatDataRequest = krdp_cliprdr_server_format_data_request;
        cliprdr->ServerFormatDataResponse = krdp_cliprdr_server_format_data_response;
        // FreeRDP's file-clipboard helper takes over `cliprdr->custom` and installs
        // its own lock/unlock and file-contents handlers. Doing that by hand (as
        // an earlier build did) leaves CB_LOCK_CLIPDATA unanswered and the server
        // waiting, so a file paste never completes. Our client is handed in as
        // the context and read back through `krdp_client_from_cliprdr`.
        context->client->cliprdr_file = cliprdr_file_context_new(context->client);
        if (context->client->cliprdr_file) {
            cliprdr_file_context_init(context->client->cliprdr_file, cliprdr);
            // Register the file format. Without this the helper's
            // `current_flags` stays 0 and the file capability is never offered,
            // so a file copy is silently a no-op. `has_local_support` (a FUSE
            // question) does not apply to Mac -> remote, so this is set directly.
            cliprdr_file_context_set_locally_available(context->client->cliprdr_file, TRUE);
        }
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext* gfx = (RdpgfxClientContext*)e->pInterface;
        context->gfx = gfx;
        // Wire the whole GFX->GDI translation up for free: FreeRDP's own
        // `gdi_graphics_pipeline_init` installs the surface callbacks that decode
        // (including H.264) into the GDI framebuffer, and sets `context->custom`
        // to the GDI. Its `UpdateSurfaces` is saved and the pipeline's callback
        // chained on top of it, so the surfaces are drawn first and then the
        // finished buffer is handed to Swift.
        rdpGdi* gdi = context->context.gdi;
        if (gdi && gdi_graphics_pipeline_init(gdi, gfx)) {
            context->gfx_base_update_surfaces = gfx->UpdateSurfaces;
            gfx->UpdateSurfaces = krdp_gfx_UpdateSurfaces;
        }
    }
}

// MARK: - Context callbacks

/// Whether the client that built `instance` has clipboard redirection on.
static bool client_wants_clipboard(freerdp* instance)
{
    krdp_context* ctx = krdp_ctx(instance->context);
    return ctx && ctx->client && ctx->client->redirect_clipboard;
}

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

    // Ask for the channels we use by name. This runs before FreeRDP rebuilds the
    // channel manager (`utils_reload_channels` calls `LoadChannels` afterwards),
    // so what the settings list here is what actually gets created. The Clipboard
    // virtual channel is what makes copy/paste work in either direction; Display
    // Control drives resize.
    // `add_*_channel` takes the addin lookup name ("disp"), not the DVC wire name
    // ("Microsoft::Windows::RDS::DisplayControl") — passing the latter makes the
    // loader fail and takes the whole post-connect down with it.
    const char* display[] = { DISP_CHANNEL_NAME };
    if (!freerdp_client_add_dynamic_channel(context->settings, 1, display)) return FALSE;
    const char* gfx[] = { RDPGFX_CHANNEL_NAME };
    if (!freerdp_client_add_dynamic_channel(context->settings, 1, gfx)) return FALSE;
    const char* clipboard[] = { CLIPRDR_SVC_CHANNEL_NAME };
    if (client_wants_clipboard(instance) &&
        !freerdp_client_add_static_channel(context->settings, 1, clipboard)) {
        return FALSE;
    }
    return TRUE;
}

static BOOL krdp_post_connect(freerdp* instance)
{
    rdpContext* context = instance->context;

    // Create the GDI drawing surface and take over EndPaint so each completed
    // update is handed to Swift. BGRA32 matches what a CGImage wants.
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    context->update->EndPaint = krdp_end_paint;
    // Required by the graphics pipeline: `gdi_ResetGraphics` calls this to
    // rebuild the framebuffer at the size the server asks for, and there is no
    // client-side default — leaving it NULL segfaults as soon as GFX starts.
    context->update->DesktopResize = krdp_desktop_resize;

    return TRUE;
}

// MARK: - Authentication

/// Called by FreeRDP when the credentials it has are missing or were rejected.
/// It runs on the session thread, so it asks the UI (via the callback) and then
/// blocks here until the answer arrives — the same shape as any client that
/// pops a login sheet.
static BOOL krdp_authenticate_ex(freerdp* instance, char** username, char** password,
                                 char** domain, rdp_auth_reason reason)
{
    krdp_context* ctx = krdp_ctx(instance->context);
    krdp_client* client = ctx->client;
    if (!client || !client->on_credentials) return FALSE;

    // Gateway authentication is not supported; there are no stored gateway
    // credentials to offer, so let it fail rather than prompt misleadingly.
    if (reason == GW_AUTH_HTTP || reason == GW_AUTH_RDG || reason == GW_AUTH_RPC) return FALSE;

    ResetEvent(client->credentials_event);
    client->credentials_aborted = false;
    client->on_credentials(client->user,
                           *username ? *username : "",
                           *domain ? *domain : "");

    // Wait for the UI. Ten minutes is generous for a human and still bounded.
    if (WaitForSingleObject(client->credentials_event, 10 * 60 * 1000) != WAIT_OBJECT_0) {
        return FALSE;
    }
    if (client->credentials_aborted || !client->pending_password) return FALSE;

    free(*username);
    free(*domain);
    free(*password);
    *username = krdp_strdup(client->pending_username);
    *domain = krdp_strdup(client->pending_domain);
    *password = krdp_strdup(client->pending_password);

    free(client->pending_username);
    free(client->pending_domain);
    if (client->pending_password) {
        memset(client->pending_password, 0, strlen(client->pending_password));
    }
    free(client->pending_password);
    client->pending_username = client->pending_domain = client->pending_password = NULL;

    return TRUE;
}

void krdp_client_supply_credentials(krdp_client* client,
                                    const char* username,
                                    const char* domain,
                                    const char* password)
{
    if (!client || !client->credentials_event) return;
    free(client->pending_username);
    free(client->pending_domain);
    if (client->pending_password) memset(client->pending_password, 0, strlen(client->pending_password));
    free(client->pending_password);
    client->pending_username = krdp_strdup(username);
    client->pending_domain = krdp_strdup(domain);
    client->pending_password = krdp_strdup(password);
    client->credentials_aborted = false;
    SetEvent(client->credentials_event);
}

void krdp_client_cancel_credentials(krdp_client* client)
{
    if (!client || !client->credentials_event) return;
    client->credentials_aborted = true;
    SetEvent(client->credentials_event);
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
                                krdp_credentials_cb on_credentials,
                                krdp_clipboard_cb on_clipboard,
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
    InitializeCriticalSection(&client->clipboard_lock);
    // The file format lives in a winpr clipboard: paths go in as a URI list and
    // winpr produces the FILEDESCRIPTORW list a server pastes from. Registering
    // "FileGroupDescriptorW" gives us the id to advertise; a raw CF_HDROP is not
    // what a server matches on.
    client->clipboard = ClipboardCreate();
    if (client->clipboard) {
        // The id is assigned by winpr; `ClipboardGetFormatId` resolves it here and
        // the synthesizer is installed lazily by that call.
        client->clipboard_file_format_id =
            ClipboardGetFormatId(client->clipboard, "FileGroupDescriptorW");
    }

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
    client->on_credentials = on_credentials;
    client->on_clipboard = on_clipboard;
    client->user = user;

    client->instance = freerdp_new();
    if (!client->instance) { krdp_client_destroy(client); return NULL; }

    client->instance->ContextSize = sizeof(krdp_context);
    client->instance->ContextNew = krdp_context_new;
    client->instance->ContextFree = krdp_context_free;
    client->instance->PreConnect = krdp_pre_connect;
    client->instance->PostConnect = krdp_post_connect;
    client->instance->PostDisconnect = krdp_post_disconnect;
    // Ask for credentials instead of failing silently when none are stored or the
    // stored ones are rejected; the UI answers through krdp_client_supply_credentials.
    client->instance->AuthenticateEx = krdp_authenticate_ex;
    // FreeRDP rebuilds the channel manager *after* PreConnect and populates it
    // through this callback, so it must be set or no channel ever goes live.
    // (`freerdp_context_new` leaves it NULL, unlike `freerdp_client_context_new`.)
    client->instance->LoadChannels = freerdp_client_load_channels;
    client->credentials_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!client->credentials_event) { krdp_client_destroy(client); return NULL; }

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
    // RDP8 graphics pipeline: progressive / RemoteFX / H.264 through the bundled
    // OpenH264. This is the only way to get smooth frames on a real desktop, and
    // it needs a drawing hook — rdpgfx never calls the plain GDI `EndPaint`, it
    // hands finished surfaces to a `UpdateSurfaces` callback instead. FreeRDP
    // provides that translation in `gdi_graphics_pipeline_init`, which
    // `krdp_channel_connected` installs (and `krdp_gfx_UpdateSurfaces` forwards
    // to Swift). Turning this on without that wiring is what made an earlier
    // release connect but draw nothing, so the hook must stay paired with it.
    // Decode on the session thread. FreeRDP's codec thread pool races with the
    // graphics pipeline's surface handling (a data race the reference macOS
    // client hits too), and that race is what made the picture hitch even with a
    // fast codec. Single-threaded decode is ample for one desktop.
    freerdp_settings_set_uint32(s, FreeRDP_ThreadingFlags, THREADING_FLAGS_DISABLE_THREADS);
    // Keep the full codec set: H.264/AVC444 where the server negotiates GFX caps
    // >= v10, progressive/RemoteFX on older hosts (their only efficient codec).
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE);
    // RemoteFX / progressive codec. Without this the pipeline sends only plain
    // bitmaps, which is most of why a real desktop felt slow while a client that
    // enables it (mRemoteNXT, xfreerdp's defaults) feels fluid. Verified present
    // in this build's libfreerdp3 (progressive_compress/decompress).
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressiveV2, TRUE);
    // AVC444 gives a much better picture for the same bandwidth where the server
    // supports it; harmless where it does not.
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, TRUE);
    // The software GDI path is what the reference embedded clients use; leaving it
    // off makes FreeRDP try to hand the surface to a GPU path that an embedder
    // without one cannot complete.
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);
    // Let the server adapt to the link (and to our ack cadence) instead of
    // assuming a fixed high-bandwidth connection.
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
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
    // If the session thread is blocked in the credential callback, release it
    // first — otherwise the join below would wait out the credential timeout.
    if (client->credentials_event) {
        client->credentials_aborted = true;
        SetEvent(client->credentials_event);
    }
    if (client->thread) {
        WaitForSingleObject(client->thread, INFINITE);
        CloseHandle(client->thread);
        client->thread = NULL;
    }
    if (client->stop_event) {
        CloseHandle(client->stop_event);
        client->stop_event = NULL;
    }
    if (client->credentials_event) {
        CloseHandle(client->credentials_event);
        client->credentials_event = NULL;
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
    DeleteCriticalSection(&client->clipboard_lock);
    if (client->clipboard) {
        ClipboardDestroy(client->clipboard);
        client->clipboard = NULL;
    }
    free(client->clipboard_text);
    for (int i = 0; i < client->clipboard_file_count; i++) free(client->clipboard_files[i]);
    free(client->clipboard_files);
    if (client->cliprdr_file) {
        // The channel context lives on the rdpContext, not on the client.
        krdp_context* kctx = client->instance ? krdp_ctx(client->instance->context) : NULL;
        CliprdrClientContext* cliprdr = (kctx && kctx->cliprdr) ? kctx->cliprdr : NULL;
        if (cliprdr) cliprdr_file_context_uninit(client->cliprdr_file, cliprdr);
        cliprdr_file_context_free(client->cliprdr_file);
        client->cliprdr_file = NULL;
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
