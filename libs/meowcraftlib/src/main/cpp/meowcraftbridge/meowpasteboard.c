/*
 * meowpasteboard.c - clipboard write via the platform pasteboard NDK.
 *
 * MC copies text from a few screens (the "copy link" buttons). On the GLFW path that
 * reaches the bridge through CallbackBridge.nativeClipboard, on the SDL path through the
 * ohos driver's SetClipboardText hook; both end up in meow_clipboard_set_text().
 *
 * The NDK is resolved at run time on purpose: linking libpasteboard.so / libudmf.so would
 * add DT_NEEDED entries, and build_sdl_meow.sh rejects unexpected ones (a deliberate guard
 * in a script that is meant to stay app-agnostic).
 *
 * Writing needs no permission. Reading would need ohos.permission.READ_PASTEBOARD (with an
 * authorisation dialog, and the recommended no-dialog route - the paste control - only
 * exists in ArkTS UI, which a game screen cannot use), so this file only writes.
 */
#include <dlfcn.h>
#include <string.h>

#include "meowlog.h"
#include "meowpasteboard.h"

typedef struct OH_Pasteboard OH_Pasteboard;
typedef struct OH_UdsPlainText OH_UdsPlainText;
typedef struct OH_UdmfRecord OH_UdmfRecord;
typedef struct OH_UdmfData OH_UdmfData;

typedef struct {
    int state; /* 0 = not resolved yet, 1 = ready, -1 = unavailable */
    OH_Pasteboard *(*create)(void);
    void (*destroy)(OH_Pasteboard *);
    int (*set_data)(OH_Pasteboard *, OH_UdmfData *);
    OH_UdsPlainText *(*uds_create)(void);
    int (*uds_set_content)(OH_UdsPlainText *, const char *);
    void (*uds_destroy)(OH_UdsPlainText *);
    OH_UdmfRecord *(*record_create)(void);
    int (*record_add_plain_text)(OH_UdmfRecord *, OH_UdsPlainText *);
    void (*record_destroy)(OH_UdmfRecord *);
    OH_UdmfData *(*data_create)(void);
    int (*data_add_record)(OH_UdmfData *, OH_UdmfRecord *);
    void (*data_destroy)(OH_UdmfData *);
} meow_pb_api;

static meow_pb_api g_pb;

/* Returns 1 when the NDK is ready, -1 when it is not (logged once). */
static int meow_pb_resolve(void) {
    void *pasteboard;
    void *udmf;

    if (g_pb.state != 0) {
        return g_pb.state;
    }

    pasteboard = dlopen("libpasteboard.so", RTLD_NOW | RTLD_LOCAL);
    udmf = dlopen("libudmf.so", RTLD_NOW | RTLD_LOCAL);
    if (pasteboard == NULL || udmf == NULL) {
        MEOWLOGW("clipboard: pasteboard NDK not loadable (%{public}s) - copy is a no-op",
                 dlerror());
        g_pb.state = -1;
        return -1;
    }

    g_pb.create = (OH_Pasteboard *(*)(void))dlsym(pasteboard, "OH_Pasteboard_Create");
    g_pb.destroy = (void (*)(OH_Pasteboard *))dlsym(pasteboard, "OH_Pasteboard_Destroy");
    g_pb.set_data = (int (*)(OH_Pasteboard *, OH_UdmfData *))dlsym(pasteboard,
                                                                   "OH_Pasteboard_SetData");
    g_pb.uds_create = (OH_UdsPlainText *(*)(void))dlsym(udmf, "OH_UdsPlainText_Create");
    g_pb.uds_set_content = (int (*)(OH_UdsPlainText *, const char *))dlsym(
        udmf, "OH_UdsPlainText_SetContent");
    g_pb.uds_destroy = (void (*)(OH_UdsPlainText *))dlsym(udmf, "OH_UdsPlainText_Destroy");
    g_pb.record_create = (OH_UdmfRecord *(*)(void))dlsym(udmf, "OH_UdmfRecord_Create");
    g_pb.record_add_plain_text = (int (*)(OH_UdmfRecord *, OH_UdsPlainText *))dlsym(
        udmf, "OH_UdmfRecord_AddPlainText");
    g_pb.record_destroy = (void (*)(OH_UdmfRecord *))dlsym(udmf, "OH_UdmfRecord_Destroy");
    g_pb.data_create = (OH_UdmfData *(*)(void))dlsym(udmf, "OH_UdmfData_Create");
    g_pb.data_add_record = (int (*)(OH_UdmfData *, OH_UdmfRecord *))dlsym(
        udmf, "OH_UdmfData_AddRecord");
    g_pb.data_destroy = (void (*)(OH_UdmfData *))dlsym(udmf, "OH_UdmfData_Destroy");

    if (g_pb.create == NULL || g_pb.destroy == NULL || g_pb.set_data == NULL ||
        g_pb.uds_create == NULL || g_pb.uds_set_content == NULL || g_pb.uds_destroy == NULL ||
        g_pb.record_create == NULL || g_pb.record_add_plain_text == NULL ||
        g_pb.record_destroy == NULL || g_pb.data_create == NULL ||
        g_pb.data_add_record == NULL || g_pb.data_destroy == NULL) {
        MEOWLOGW("clipboard: pasteboard NDK symbols missing - copy is a no-op");
        g_pb.state = -1;
        return -1;
    }

    g_pb.state = 1;
    MEOWLOGI("clipboard: pasteboard NDK ready (write only)");
    return 1;
}

int meow_clipboard_set_text(const char *utf8) {
    OH_UdsPlainText *uds;
    OH_UdmfRecord *record;
    OH_UdmfData *data;
    OH_Pasteboard *pasteboard;
    int rc;

    if (utf8 == NULL) {
        return -1;
    }
    if (meow_pb_resolve() != 1) {
        return -1;
    }

    uds = g_pb.uds_create();
    if (uds == NULL) {
        return -1;
    }
    g_pb.uds_set_content(uds, utf8);

    record = g_pb.record_create();
    if (record == NULL) {
        g_pb.uds_destroy(uds);
        return -1;
    }
    g_pb.record_add_plain_text(record, uds);

    data = g_pb.data_create();
    if (data == NULL) {
        g_pb.record_destroy(record);
        g_pb.uds_destroy(uds);
        return -1;
    }
    g_pb.data_add_record(data, record);

    pasteboard = g_pb.create();
    if (pasteboard == NULL) {
        g_pb.data_destroy(data);
        g_pb.record_destroy(record);
        g_pb.uds_destroy(uds);
        return -1;
    }

    rc = g_pb.set_data(pasteboard, data);
    MEOWLOGI("clipboard: wrote %{public}d bytes rc=%{public}d", (int)strlen(utf8), rc);

    g_pb.destroy(pasteboard);
    g_pb.data_destroy(data);
    g_pb.record_destroy(record);
    g_pb.uds_destroy(uds);
    return (rc == 0) ? 0 : -1;
}
