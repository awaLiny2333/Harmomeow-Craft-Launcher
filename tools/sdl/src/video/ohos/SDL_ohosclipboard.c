/*
  Simple DirectMedia Layer
  Copyright (C) 1997-2026 Sam Lantinga <slouken@libsdl.org>

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.
*/
#include "SDL_internal.h"

#ifdef SDL_VIDEO_DRIVER_OHOS

#include <dlfcn.h>
#include <string.h>

#include "SDL_ohosclipboard.h"

/*
 * Clipboard write for MC 26.3, which reads/writes it through SDLClipboard
 * (SDL_SetClipboardText -> SDL_VideoDevice::SetClipboardText).
 *
 * Implemented with the platform pasteboard NDK, resolved at run time: linking
 * libpasteboard.so / libudmf.so would add DT_NEEDED entries, and build_sdl_meow.sh
 * rejects unexpected ones on purpose (that script stays app-agnostic). Same shape as the
 * bridge's meowpasteboard.c, which serves the GLFW path.
 *
 * Write-only: reading needs ohos.permission.READ_PASTEBOARD (authorisation dialog), and
 * the no-dialog alternative - the paste control - only exists in ArkTS UI.
 */

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
} OHOS_PbApi;

static OHOS_PbApi OHOS_pb;

static int OHOS_PbResolve(void)
{
    void *pasteboard;
    void *udmf;

    if (OHOS_pb.state != 0) {
        return OHOS_pb.state;
    }

    pasteboard = dlopen("libpasteboard.so", RTLD_NOW | RTLD_LOCAL);
    udmf = dlopen("libudmf.so", RTLD_NOW | RTLD_LOCAL);
    if (pasteboard == NULL || udmf == NULL) {
        OHOS_pb.state = -1;
        return -1;
    }

    OHOS_pb.create = (OH_Pasteboard *(*)(void))dlsym(pasteboard, "OH_Pasteboard_Create");
    OHOS_pb.destroy = (void (*)(OH_Pasteboard *))dlsym(pasteboard, "OH_Pasteboard_Destroy");
    OHOS_pb.set_data = (int (*)(OH_Pasteboard *, OH_UdmfData *))dlsym(pasteboard,
                                                                      "OH_Pasteboard_SetData");
    OHOS_pb.uds_create = (OH_UdsPlainText *(*)(void))dlsym(udmf, "OH_UdsPlainText_Create");
    OHOS_pb.uds_set_content = (int (*)(OH_UdsPlainText *, const char *))dlsym(
        udmf, "OH_UdsPlainText_SetContent");
    OHOS_pb.uds_destroy = (void (*)(OH_UdsPlainText *))dlsym(udmf, "OH_UdsPlainText_Destroy");
    OHOS_pb.record_create = (OH_UdmfRecord *(*)(void))dlsym(udmf, "OH_UdmfRecord_Create");
    OHOS_pb.record_add_plain_text = (int (*)(OH_UdmfRecord *, OH_UdsPlainText *))dlsym(
        udmf, "OH_UdmfRecord_AddPlainText");
    OHOS_pb.record_destroy = (void (*)(OH_UdmfRecord *))dlsym(udmf, "OH_UdmfRecord_Destroy");
    OHOS_pb.data_create = (OH_UdmfData *(*)(void))dlsym(udmf, "OH_UdmfData_Create");
    OHOS_pb.data_add_record = (int (*)(OH_UdmfData *, OH_UdmfRecord *))dlsym(
        udmf, "OH_UdmfData_AddRecord");
    OHOS_pb.data_destroy = (void (*)(OH_UdmfData *))dlsym(udmf, "OH_UdmfData_Destroy");

    if (OHOS_pb.create == NULL || OHOS_pb.destroy == NULL || OHOS_pb.set_data == NULL ||
        OHOS_pb.uds_create == NULL || OHOS_pb.uds_set_content == NULL ||
        OHOS_pb.uds_destroy == NULL || OHOS_pb.record_create == NULL ||
        OHOS_pb.record_add_plain_text == NULL || OHOS_pb.record_destroy == NULL ||
        OHOS_pb.data_create == NULL || OHOS_pb.data_add_record == NULL ||
        OHOS_pb.data_destroy == NULL) {
        OHOS_pb.state = -1;
        return -1;
    }

    OHOS_pb.state = 1;
    return 1;
}

bool OHOS_SetClipboardText(SDL_VideoDevice *_this, const char *text)
{
    OH_UdsPlainText *uds;
    OH_UdmfRecord *record;
    OH_UdmfData *data;
    OH_Pasteboard *pasteboard;
    int rc;

    (void)_this;
    if (text == NULL) {
        return SDL_InvalidParamError("text");
    }
    if (OHOS_PbResolve() != 1) {
        return SDL_SetError("ohos: the pasteboard NDK is not available");
    }

    uds = OHOS_pb.uds_create();
    if (uds == NULL) {
        return SDL_SetError("ohos: could not create a UDS plain-text instance");
    }
    OHOS_pb.uds_set_content(uds, text);

    record = OHOS_pb.record_create();
    if (record == NULL) {
        OHOS_pb.uds_destroy(uds);
        return SDL_SetError("ohos: could not create a UDMF record");
    }
    OHOS_pb.record_add_plain_text(record, uds);

    data = OHOS_pb.data_create();
    if (data == NULL) {
        OHOS_pb.record_destroy(record);
        OHOS_pb.uds_destroy(uds);
        return SDL_SetError("ohos: could not create a UDMF data instance");
    }
    OHOS_pb.data_add_record(data, record);

    pasteboard = OHOS_pb.create();
    if (pasteboard == NULL) {
        OHOS_pb.data_destroy(data);
        OHOS_pb.record_destroy(record);
        OHOS_pb.uds_destroy(uds);
        return SDL_SetError("ohos: could not create a pasteboard instance");
    }

    rc = OHOS_pb.set_data(pasteboard, data);

    OHOS_pb.destroy(pasteboard);
    OHOS_pb.data_destroy(data);
    OHOS_pb.record_destroy(record);
    OHOS_pb.uds_destroy(uds);

    if (rc != 0) {
        return SDL_SetError("ohos: OH_Pasteboard_SetData failed (%d)", rc);
    }
    return true;
}

#endif // SDL_VIDEO_DRIVER_OHOS
