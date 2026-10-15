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
#include <freerdp/client.h>   /* freerdp_client_context_new, RDP_CLIENT_ENTRY_POINTS */
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
#include <winpr/sysinfo.h>   /* winpr_GetTickCount64 */
#include <winpr/thread.h>
#include <winpr/ssl.h>
#include <winpr/interlocked.h>
#include <errno.h>
#include <limits.h>   /* PATH_MAX */
#include <sys/stat.h> /* mkdir */
#include <stdlib.h>   /* system, getenv */

// MARK: - Remote file transfers (server -> Mac)

/// One file the server announced in its `FileGroupDescriptorW` list, with the
/// local path it is being written to. The name is sanitised on arrival: it came
/// from the server and must never escape the transfer directory.
typedef struct {
    /// Sanitised single-component name, NUL-terminated UTF-8.
    char* name;
    /// Absolute local path under the transfer directory.
    char* local_path;
    /// Declared size, or -1 when the server did not say.
    int64_t size;
    bool is_directory;
    /// Bytes written so far; a directory is created instead.
    uint64_t written;
} krdp_transfer_file;

// MARK: - Context

/// FreeRDP requires the rdpContext to be the first member of a custom context.
/// With the client-common path this must be an **rdpClientContext**, not a bare
/// rdpContext: `freerdp_client_context_new` asserts on it (`requireRdpClientContext`)
/// and refuses to run against anything smaller. FreeRDP 3 dropped the old
/// `rdpContext::custom` field, so the client pointer travels through the typed
/// context instead.
typedef struct {
    rdpClientContext common;
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
    /// The pipeline's own `SurfaceCommand`; wrapped only to count which codec the
    /// server sent, then called through.
    pcRdpgfxSurfaceCommand gfx_base_surface_command;
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
    CliprdrFileContext* cliprdr_file;
    /// winpr clipboard backing the file format. Files are handed in as a
    /// `text/uri-list`; winpr stats every path (descending into folders) and
    /// produces the `FILEDESCRIPTORW` list a server pastes from. `clipboard_file_format_id`
    /// is the id `FileGroupDescriptorW` is registered under, and is what the
    /// format list must advertise — not a raw CF_HDROP.
    wClipboard* clipboard;
    UINT32 clipboard_file_format_id;

    // File clipboard (remote -> Mac). The server announces its files as a
    // `FileGroupDescriptorW` list; we ask for each file's bytes over the same
    // clipboard channel (CB_FILECONTENTS_*) and write them to a temporary
    // directory, then hand the paths to the UI, which puts them on the pasteboard.
    // FreeRDP only wires its own file-contents handler under FUSE, so this bridge
    // installs its own `ServerFileContentsResponse` and does the writing itself.
    krdp_clipboard_files_cb on_clipboard_files;
    /// The id the server gave `FileGroupDescriptorW` in its format list; 0 when
    /// it announced no files.
    UINT32 remote_file_format_id;
    /// The format id of the request whose response is currently outstanding, so
    /// a response can be told apart (text vs. the file list).
    UINT32 pending_format_id;
    /// Lock the server put on the file list we are reading, so it stays
    /// readable after the remote clipboard changes. 0 when it offered none.
    UINT32 remote_clip_data_id;
    UINT32 next_clip_data_id;
    bool can_lock_clip_data;
    /// The transfers in flight, populated when the file list arrives.
    krdp_transfer_file* transfer_files;
    uint32_t transfer_count;
    /// Index of the file being downloaded, or -1 when idle.
    int32_t transfer_current;
    /// True while the outstanding request is a size query, whose 8-byte answer
    /// is the length rather than content.
    bool transfer_size_pending;
    /// The directory the downloaded files are written to, for this transfer.
    char* transfer_dir;

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

/// Frame counter for diagnosing smoothness. Writes an fps figure to
/// `~/Library/Application Support/KRemote/perf.log` every few seconds, so a
/// session's real throughput can be read without reproducing it elsewhere.
/// Cheap: a counter increment on the frame path and a timestamped line every
/// ~5s. Remove once frame pacing is settled.
static volatile LONG g_frame_count = 0;
static volatile LONG64 g_frame_window_start = 0;

/// Counts the GFX codec each surface command carries, so the log can say what the
/// server actually sent (uncompressed vs progressive vs H.264) rather than what
/// was negotiated.
static volatile LONG g_codec_counts[16] = {0};

static void krdp_note_codec(UINT32 codecId)
{
    if (codecId < 16) InterlockedIncrement(&g_codec_counts[codecId]);
}

static void krdp_note_frame(void)
{
    InterlockedIncrement(&g_frame_count);
    const LONG64 now = winpr_GetTickCount64();
    LONG64 start = g_frame_window_start;
    if (start == 0) { g_frame_window_start = now; return; }
    const LONG64 elapsed = now - start;
    if (elapsed < 5000) return;
    const LONG count = InterlockedExchange(&g_frame_count, 0);
    g_frame_window_start = now;

    const char* home = getenv("HOME");
    if (!home) return;
    char path[512];
    snprintf(path, sizeof(path), "%s/Library/Application Support/KRemote/perf.log", home);
    FILE* f = fopen(path, "a");
    if (!f) return;
    // Codec histogram alongside the rate: what the server actually sent.
    fprintf(f, "%.1f fps (%ld frames / %lld ms) codecs[clear=%ld rfx=%ld avc420=%ld avc444=%ld]\n",
            count * 1000.0 / (double)elapsed, (long)count, (long long)elapsed,
            (long)g_codec_counts[0], (long)g_codec_counts[3],
            (long)g_codec_counts[8], (long)g_codec_counts[9]);
    fclose(f);
}

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
        krdp_note_frame();
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

// MARK: - File clipboard (remote -> Mac)

/// Sends the contents request for the file currently being downloaded. Each
/// request's `streamId` is the file's index, so its response is matched without
/// a lookup table.
static void krdp_request_current_file(krdp_client* client, CliprdrClientContext* cliprdr);

/// Frees the transfer state and, when asked, removes the directory it wrote to.
static void krdp_clear_transfer(krdp_client* client, bool remove_files)
{
    if (!client) return;
    if (remove_files && client->transfer_dir) {
        // Only ever touches the directory this bridge created under the temp dir.
        char command[4096];
        snprintf(command, sizeof(command), "rm -rf '%s'", client->transfer_dir);
        if (system(command) != 0) { /* best effort */ }
    }
    for (uint32_t i = 0; i < client->transfer_count; i++) {
        free(client->transfer_files[i].name);
        free(client->transfer_files[i].local_path);
    }
    free(client->transfer_files);
    client->transfer_files = NULL;
    client->transfer_count = 0;
    client->transfer_current = -1;
    free(client->transfer_dir);
    client->transfer_dir = NULL;
}

/// Converts a server-supplied relative path into a safe relative path.
///
/// The name comes from the remote side, so it is untrusted: `..`, a leading `/`
/// or a drive letter must never be able to steer the write outside the transfer
/// directory (a path-traversal guard, not a nicety). The server sends the whole
/// copied tree as a flat list whose entries are relative paths
/// (`folder\\sub\\file.txt`), so the separators carry the structure and have to
/// be kept — every *component* is cleaned individually, and `.`/`..`/empty
/// components are dropped outright. Returns NULL when nothing survives.
static char* krdp_sanitise_relative_path(const uint16_t* utf16_name)
{
    if (!utf16_name) return NULL;

    // Longest input is 259 UTF-16 units; UTF-8 can be 4 bytes each, plus
    // separators, and one NUL.
    char out[260 * 4 + 2];
    size_t o = 0;
    bool last_was_separator = true;   // also drops any leading separator

    for (size_t i = 0; i < 259 && utf16_name[i]; i++) {
        uint32_t cp = utf16_name[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && utf16_name[i + 1] >= 0xDC00 &&
            utf16_name[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (utf16_name[i + 1] - 0xDC00);
            i++;
        }
        // Both separators collapse to one, so `a\\b`, `a/b` and `a//b` agree.
        if (cp == '\\' || cp == '/') {
            if (!last_was_separator) {
                out[o++] = '/';
                last_was_separator = true;
            }
            continue;
        }
        // A control character would corrupt the path; drop it rather than
        // letting it through as part of a component.
        if (cp < 0x20) continue;
        if (o + 4 >= sizeof(out)) break;
        if (cp < 0x80) {
            out[o++] = (char)cp;
        } else if (cp < 0x800) {
            out[o++] = (char)(0xC0 | (cp >> 6));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out[o++] = (char)(0xE0 | (cp >> 12));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        } else {
            out[o++] = (char)(0xF0 | (cp >> 18));
            out[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[o++] = (char)(0x80 | (cp & 0x3F));
        }
        last_was_separator = false;
    }
    out[o] = '\0';

    // Walk the components and drop any that would escape or are meaningless.
    // `..` is removed rather than kept-safely: a legitimate copy never contains
    // one, and a malicious descriptor must not be able to climb out.
    char cleaned[sizeof(out)];
    size_t c = 0;
    const char* segment = out;
    while (*segment) {
        const char* slash = strchr(segment, '/');
        const size_t length = slash ? (size_t)(slash - segment) : strlen(segment);
        if (length > 0 && !(length == 1 && segment[0] == '.') &&
            !(length == 2 && segment[0] == '.' && segment[1] == '.')) {
            if (c > 0) cleaned[c++] = '/';
            memcpy(cleaned + c, segment, length);
            c += length;
        }
        if (!slash) break;
        segment = slash + 1;
    }
    cleaned[c] = '\0';
    if (c == 0) return NULL;
    return krdp_strdup(cleaned);
}

/// Creates every directory component of `path` (like `mkdir -p`).
///
/// Only ever called with a path built from the sanitised transfer entry, so the
/// directory stays inside the transfer root. Returns true when the final
/// directory exists afterwards.
static bool krdp_make_parents(const char* path)
{
    char buffer[PATH_MAX];
    const size_t length = strlen(path);
    if (length == 0 || length >= sizeof(buffer)) return false;
    memcpy(buffer, path, length + 1);
    // Walk forward, creating each prefix. A partial failure (EEXIST) is fine.
    for (char* p = buffer + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(buffer, 0700) != 0 && errno != EEXIST) { /* keep going */ }
        *p = '/';
    }
    if (mkdir(buffer, 0700) != 0 && errno != EEXIST) return false;
    return true;
}

/// Parses the server's `FileGroupDescriptorW` payload into transfer entries and
/// starts the first download. An empty list clears any previous transfer.
static void krdp_begin_transfer(krdp_client* client, CliprdrClientContext* cliprdr,
                                const BYTE* data, UINT32 size)
{
    if (!client || !cliprdr || !data) return;

    FILEDESCRIPTORW* descriptors = NULL;
    UINT32 count = 0;
    if (cliprdr_parse_file_list(data, size, &descriptors, &count) != CHANNEL_RC_OK || count == 0) {
        free(descriptors);
        return;
    }

    // Replace whatever is in flight; the previous copy's lock is deliberately
    // left to the server (it expires with the clipboard).
    krdp_clear_transfer(client, true);

    // One directory per transfer, so a new paste never collides with the old.
    char root[PATH_MAX];
    const char* tmp = getenv("TMPDIR");
    snprintf(root, sizeof(root), "%s/kremote-paste-%llu",
             (tmp && *tmp) ? tmp : "/tmp", (unsigned long long)winpr_GetTickCount64());
    if (mkdir(root, 0700) != 0 && errno != EEXIST) {
        free(descriptors);
        return;
    }

    client->transfer_files = calloc(count, sizeof(krdp_transfer_file));
    if (!client->transfer_files) { free(descriptors); return; }
    client->transfer_dir = krdp_strdup(root);
    client->transfer_count = count;

    for (UINT32 i = 0; i < count; i++) {
        const FILEDESCRIPTORW* d = &descriptors[i];
        krdp_transfer_file* f = &client->transfer_files[i];
        // The name is a path relative to what was copied (`folder\sub\a.txt`);
        // the separators carry the tree, so they are kept, but every component
        // is sanitised so nothing can climb out of the root.
        f->name = krdp_sanitise_relative_path(d->cFileName);
        f->is_directory = (d->dwFlags & FD_ATTRIBUTES) && (d->dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
        f->size = (d->dwFlags & FD_FILESIZE)
                      ? (int64_t)(((uint64_t)d->nFileSizeHigh << 32) | d->nFileSizeLow)
                      : -1;
        if (!f->name) f->name = krdp_strdup("unnamed");
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", root, f->name);
        f->local_path = krdp_strdup(path);
        // The parent directories of a nested entry may not have arrived yet as
        // their own descriptor (a server is free to send them in any order), so
        // create them here rather than relying on order.
        char* last_slash = strrchr(f->local_path, '/');
        if (last_slash && last_slash > f->local_path + strlen(root)) {
            *last_slash = '\0';
            krdp_make_parents(f->local_path);
            *last_slash = '/';
        }
        // A directory is materialised now; a file is written as its bytes arrive.
        if (f->is_directory) mkdir(f->local_path, 0700);
    }
    free(descriptors);

    client->transfer_current = -1;
    krdp_request_current_file(client, cliprdr);
}

/// Advances to the next file and requests its first block (or its size first,
/// when the server did not declare one).
static void krdp_request_current_file(krdp_client* client, CliprdrClientContext* cliprdr)
{
    if (!client || !cliprdr) return;
    // Skip directories: they were already created and carry no bytes.
    int32_t next = client->transfer_current + 1;
    while (next < (int32_t)client->transfer_count && client->transfer_files[next].is_directory) next++;
    if (next >= (int32_t)client->transfer_count) {
        // Every file is down: hand the top-level entries to the UI — that is
        // what the user pastes (a copied folder arrives as one entry, with its
        // contents already written beneath it), and mark the transfer done.
        if (client->on_clipboard_files) {
            const char** paths = calloc(client->transfer_count + 1, sizeof(char*));
            int kept = 0;
            for (uint32_t i = 0; i < client->transfer_count; i++) {
                // A nested entry carries a '/'; its parent is the entry to offer.
                if (strchr(client->transfer_files[i].name, '/')) continue;
                paths[kept++] = client->transfer_files[i].local_path;
            }
            client->on_clipboard_files(client->user, paths, kept);
            free(paths);
        }
        client->transfer_current = -1;
        return;
    }
    client->transfer_current = next;

    // Without a declared size the first request must ask for it: MS-RDPECLIP
    // 2.2.5.3 has a size request carry position 0 and ask for exactly 8 bytes.
    const krdp_transfer_file* f = &client->transfer_files[next];
    const bool size_only = (f->size < 0 && f->written == 0);
    client->transfer_size_pending = size_only;

    CLIPRDR_FILE_CONTENTS_REQUEST request;
    memset(&request, 0, sizeof(request));
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.streamId = (UINT32)(next + 1);
    request.listIndex = (UINT32)next;
    request.dwFlags = size_only ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
    request.nPositionLow = size_only ? 0 : (UINT32)(f->written & 0xFFFFFFFFu);
    request.nPositionHigh = size_only ? 0 : (UINT32)(f->written >> 32);
    request.cbRequested = size_only ? 8 : 65536;
    request.haveClipDataId = client->remote_clip_data_id != 0;
    request.clipDataId = client->remote_clip_data_id;
    (void)cliprdr->ClientFileContentsRequest(cliprdr, &request);
}

/// Requests the next block of the file at `index` from its current offset.
static void krdp_request_next_block(krdp_client* client, CliprdrClientContext* cliprdr, int32_t index)
{
    const krdp_transfer_file* f = &client->transfer_files[index];
    client->transfer_size_pending = false;
    CLIPRDR_FILE_CONTENTS_REQUEST request;
    memset(&request, 0, sizeof(request));
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.streamId = (UINT32)(index + 1);
    request.listIndex = (UINT32)index;
    request.dwFlags = FILECONTENTS_RANGE;
    request.nPositionLow = (UINT32)(f->written & 0xFFFFFFFFu);
    request.nPositionHigh = (UINT32)(f->written >> 32);
    request.cbRequested = 65536;
    request.haveClipDataId = client->remote_clip_data_id != 0;
    request.clipDataId = client->remote_clip_data_id;
    (void)cliprdr->ClientFileContentsRequest(cliprdr, &request);
}

/// The bytes (or the size) the server sent for one file.
static UINT krdp_cliprdr_server_file_contents_response(CliprdrClientContext* ctx,
                                                       const CLIPRDR_FILE_CONTENTS_RESPONSE* response)
{
    krdp_client* client = krdp_client_from_cliprdr(ctx);
    if (!client || client->transfer_current < 0) return CHANNEL_RC_OK;

    const int32_t index = client->transfer_current;
    krdp_transfer_file* f = &client->transfer_files[index];
    const bool ok = (response->common.msgFlags & CB_RESPONSE_OK) != 0;

    if (!ok || !response->requestedData || response->cbRequested == 0) {
        // Give up on this one file and move on, so a refusal cannot wedge the rest.
        krdp_request_current_file(client, ctx);
        return CHANNEL_RC_OK;
    }

    // A size answer is 8 bytes: the file length, low half first. The size is
    // only the size — the bytes still have to be fetched.
    if (client->transfer_size_pending) {
        uint64_t size64 = 0;
        memcpy(&size64, response->requestedData, 8);
        f->size = (int64_t)size64;
        krdp_request_next_block(client, ctx, index);
        return CHANNEL_RC_OK;
    }

    // Write in append mode and track the offset, so a large file arrives in
    // blocks and none of it is held in memory.
    FILE* handle = fopen(f->local_path, f->written == 0 ? "wb" : "ab");
    if (handle) {
        fwrite(response->requestedData, 1, response->cbRequested, handle);
        fclose(handle);
        f->written += response->cbRequested;
    }

    if (f->size >= 0 && f->written >= (uint64_t)f->size) {
        krdp_request_current_file(client, ctx);   // done with this one, on to the next
    } else {
        krdp_request_next_block(client, ctx, index);
    }
    return CHANNEL_RC_OK;
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

    // Classify what the server is offering. Text wins over files: a mail item,
    // for one, arrives as both and a paste into a text field wants the text.
    bool has_text = false;
    UINT32 file_format = 0;
    for (UINT32 i = 0; list && i < list->numFormats; i++) {
        const UINT32 id = list->formats[i].formatId;
        const char* name = list->formats[i].formatName;
        if (id == CF_UNICODETEXT) has_text = true;
        else if (name && strcmp(name, "FileGroupDescriptorW") == 0) file_format = id;
    }
    if (client) {
        client->remote_file_format_id = file_format;
        // Lock the announced file list so it stays readable once the remote
        // clipboard moves on; older locks belong to an earlier copy and are
        // released when that transfer is replaced.
        if (file_format && !has_text && client->can_lock_clip_data) {
            CLIPRDR_LOCK_CLIPBOARD_DATA lock;
            memset(&lock, 0, sizeof(lock));
            lock.common.msgType = CB_LOCK_CLIPDATA;
            lock.clipDataId = ++client->next_clip_data_id;
            if (lock.clipDataId == 0) lock.clipDataId = ++client->next_clip_data_id;
            if (ctx->ClientLockClipboardData(ctx, &lock) == CHANNEL_RC_OK) {
                client->remote_clip_data_id = lock.clipDataId;
            }
        }
    }

    // Ask for the content straight away: the text if there is any, otherwise
    // the file list (names and sizes only — no bytes move until a paste).
    UINT32 wanted = 0;
    if (has_text) {
        for (UINT32 i = 0; list && i < list->numFormats; i++) {
            if (list->formats[i].formatId == CF_UNICODETEXT) { wanted = CF_UNICODETEXT; break; }
        }
    } else if (file_format) {
        wanted = file_format;
    }
    if (wanted == 0 || !client) return CHANNEL_RC_OK;

    client->pending_format_id = wanted;
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
    if (!client) return CHANNEL_RC_OK;
    const bool ok = (response->common.msgFlags & CB_RESPONSE_OK) && response->requestedFormatData;

    // A file list answers the request for the server's file format: parse it and
    // start pulling each file's bytes. Anything else is text.
    if (ok && client->remote_file_format_id != 0 &&
        client->pending_format_id == client->remote_file_format_id) {
        krdp_begin_transfer(client, ctx, response->requestedFormatData, response->common.dataLen);
    } else if (client->on_clipboard) {
        char* utf8 = NULL;
        if (ok) utf8 = krdp_utf16le_to_utf8(response->requestedFormatData, response->common.dataLen);
        // An empty string is meaningful: the remote clipboard was cleared.
        client->on_clipboard(client->user, utf8 ? utf8 : "");
        free(utf8);
    }
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

/// Wraps the pipeline's `SurfaceCommand` just to record the codec id, then runs it.
static UINT krdp_gfx_SurfaceCommand(RdpgfxClientContext* context, const RDPGFX_SURFACE_COMMAND* cmd)
{
    rdpGdi* gdi = context ? (rdpGdi*)context->custom : NULL;
    krdp_context* ctx = gdi ? krdp_ctx(gdi->context) : NULL;
    if (!ctx) return CHANNEL_RC_OK;
    if (cmd) krdp_note_codec(cmd->codecId);
    if (ctx->gfx_base_surface_command) return ctx->gfx_base_surface_command(context, cmd);
    return CHANNEL_RC_OK;
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
    // A channel can connect before the client pointer has been bound (the event
    // fires during `freerdp_connect`, and the binding happens in create). Bail
    // rather than dereference a null client — that is a write to a small offset
    // off address 0.
    krdp_client* client = context->client;
    if (!client) return;

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
        client->cliprdr_file = cliprdr_file_context_new(client);
        if (client->cliprdr_file) {
            cliprdr_file_context_init(client->cliprdr_file, cliprdr);
            // Register the file format. Without this the helper's
            // `current_flags` stays 0 and the file capability is never offered,
            // so a file copy is silently a no-op. `has_local_support` (a FUSE
            // question) does not apply to Mac -> remote, so this is set directly.
            cliprdr_file_context_set_locally_available(client->cliprdr_file, TRUE);
            // File-lock support is negotiated; the helper tells us what the
            // server will honour. Without it a file list can be read only while
            // it is the live clipboard, which is fine but races a fast re-copy.
            client->can_lock_clip_data =
                (cliprdr_file_context_remote_get_flags(client->cliprdr_file) & CB_CAN_LOCK_CLIPDATA) != 0;
        }
        // Remote -> Mac: FreeRDP wires a file-contents response handler only
        // when it is built with FUSE, so this bridge answers for itself. The
        // bytes are written to a temporary directory instead of being mounted,
        // which is what a FUSE-less macOS client has to do.
        cliprdr->ServerFileContentsResponse = krdp_cliprdr_server_file_contents_response;
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        RdpgfxClientContext* gfx = (RdpgfxClientContext*)e->pInterface;
        context->gfx = gfx;
        // Wire the whole GFX->GDI translation up for free: FreeRDP's own
        // `gdi_graphics_pipeline_init` installs the surface callbacks that decode
        // (including H.264) into the GDI framebuffer, and sets `context->custom`
        // to the GDI. Its `UpdateSurfaces` is saved and the pipeline's callback
        // chained on top of it, so the surfaces are drawn first and then the
        // finished buffer is handed to Swift.
        rdpGdi* gdi = context->common.context.gdi;
        if (gdi && gdi_graphics_pipeline_init(gdi, gfx)) {
            context->gfx_base_update_surfaces = gfx->UpdateSurfaces;
            gfx->UpdateSurfaces = krdp_gfx_UpdateSurfaces;
            context->gfx_base_surface_command = gfx->SurfaceCommand;
            gfx->SurfaceCommand = krdp_gfx_SurfaceCommand;
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

static BOOL krdp_pre_connect(freerdp* instance)
{
    // Nothing to do: with the client-common context (`freerdp_client_context_new`)
    // the channel manager is built from the settings flags, and
    // `freerdp_channels_pre_connect` loads the addins. The reference embedded
    // clients leave this empty for the same reason. (Adding the channels by hand
    // here, as this bridge used to, also risked listing one twice.)
    (void)instance;
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
        // Wait on FreeRDP's own event handles rather than polling on a fixed
        // sleep: the socket becoming readable is the thing worth waking for, and
        // a fixed 50 ms tick adds latency to every arriving batch. This is the
        // loop the reference clients run.
        while (client->running && !freerdp_shall_disconnect_context(context)) {
            HANDLE handles[64];
            const DWORD count = freerdp_get_event_handles(context, handles, 64);
            if (count == 0) break;
            HANDLE all[65];
            DWORD n = 0;
            for (DWORD i = 0; i < count; i++) all[n++] = handles[i];
            // The stop event rides along so a stop is noticed immediately instead
            // of after the timeout.
            if (client->stop_event) all[n++] = client->stop_event;
            const DWORD status = WaitForMultipleObjects(n, all, FALSE, 200);
            if (status == WAIT_FAILED) break;
            if (client->stop_event && status == WAIT_OBJECT_0 + (n - 1)) break;
            if (!freerdp_check_event_handles(context)) break;
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

// MARK: - Client entry points

/// The client being built by `krdp_client_create`, handed to `krdp_entry_new`.
///
/// `freerdp_client_context_new` runs `ClientNew` synchronously, before the create
/// call can bind the client into the returned context — and a channel event can
/// fire before that binding, leaving `context->client` null (a crash, or silently
/// skipped channel wiring). Setting this just before the call lets `ClientNew`
/// bind it immediately, so the context is never observably unbound.
static krdp_client* g_pending_client = NULL;

/// The supported embedder path (`freerdp_client_context_new`) needs a callback
/// set rather than the low-level `freerdp_new()` + `freerdp_context_new()` pair.
/// The difference is not cosmetic: the framework's own context setup is what wires
/// the channel manager (`LoadChannels`), the codec lists and the session
/// teardown, so doing it by hand (as this bridge used to) left those to be
/// re-implemented and subtly incomplete. This mirrors what the reference embedded
/// clients do.
static BOOL krdp_entry_new(freerdp* instance, rdpContext* context)
{
    // Bind the client now: `freerdp_client_context_new` runs this before it
    // returns, so this is the earliest point a channel event could need it.
    if (g_pending_client) krdp_ctx(context)->client = g_pending_client;
    instance->PreConnect = krdp_pre_connect;
    instance->PostConnect = krdp_post_connect;
    instance->PostDisconnect = krdp_post_disconnect;
    // Ask for credentials instead of failing silently when none are stored or the
    // stored ones are rejected; the UI answers via krdp_client_supply_credentials.
    instance->AuthenticateEx = krdp_authenticate_ex;
    PubSub_SubscribeChannelConnected(context->pubSub, krdp_channel_connected);
    return TRUE;
}

static BOOL krdp_entry_global_init(void) { return TRUE; }
static void krdp_entry_global_uninit(void) {}

/// The framework does not drive the session itself; the bridge's own thread does
/// (see `krdp_client_start`), so these are inert.
static int krdp_entry_client_start(rdpContext* context) { (void)context; return 0; }
static int krdp_entry_client_stop(rdpContext* context) { (void)context; return 0; }
static void krdp_entry_free(freerdp* instance, rdpContext* context) { (void)instance; (void)context; }

krdp_client* krdp_client_create(const krdp_descriptor* descriptor,
                                krdp_frame_cb on_frame,
                                krdp_state_cb on_state,
                                krdp_credentials_cb on_credentials,
                                krdp_clipboard_cb on_clipboard,
                                krdp_clipboard_files_cb on_clipboard_files,
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
    client->on_clipboard_files = on_clipboard_files;
    client->user = user;

    client->instance = NULL;
    RDP_CLIENT_ENTRY_POINTS entry;
    memset(&entry, 0, sizeof(entry));
    entry.Size = sizeof(entry);
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.ContextSize = sizeof(krdp_context);
    entry.GlobalInit = krdp_entry_global_init;
    entry.GlobalUninit = krdp_entry_global_uninit;
    entry.ClientNew = krdp_entry_new;
    entry.ClientFree = krdp_entry_free;
    entry.ClientStart = krdp_entry_client_start;
    entry.ClientStop = krdp_entry_client_stop;

    g_pending_client = client;
    rdpContext* context = freerdp_client_context_new(&entry);
    g_pending_client = NULL;
    if (!context) { krdp_client_destroy(client); return NULL; }
    client->instance = context->instance;
    // Usually already set by `krdp_entry_new`; this is the belt-and-braces path.
    if (!krdp_ctx(context)->client) krdp_ctx(context)->client = client;

    client->credentials_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!client->credentials_event) { krdp_client_destroy(client); return NULL; }

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
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, TRUE);
    // The monitor scale factors must be one of 100/140/180 on the wire, set in
    // *both* slots: FreeRDP 3.27.x reads them crossed when it builds the monitor
    // definition, and an out-of-range value makes the client core data invalid.
    freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, 100);
    freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, 100);
    // TCP keepalive: FreeRDP's defaults (5 s idle, 3 probes 2 s apart) are far
    // too tight for an interactive session and get dropped by stateful firewalls.
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveDelay, 60);
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveInterval, 15);
    freerdp_settings_set_uint32(s, FreeRDP_TcpKeepAliveRetries, 4);
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
    // Drop any half-downloaded files from a transfer.
    krdp_clear_transfer(client, true);
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
