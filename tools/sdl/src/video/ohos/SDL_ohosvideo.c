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

/*
 * OpenHarmony / OHOS video driver.
 *
 * SDL does not own the platform window on OHOS: ArkTS creates an XComponent
 * surface and publishes the matching OHNativeWindow* to native code. This
 * driver bridges that external window into SDL and layers the standard EGL/GL
 * path on top of it (see SDL_ohosgl.c / SDL_ohoswindow.c).
 */

#include "../SDL_sysvideo.h"
#include "SDL_ohosvideo.h"
#include "SDL_ohosevents.h"
#include "SDL_ohoswindow.h"
#include "SDL_ohosmouse.h"
#include "SDL_ohosvulkan.h"
#include "SDL_ohosclipboard.h"
#ifdef SDL_VIDEO_OPENGL_EGL
#include "SDL_ohosgl.h"
#endif

#define OHOSVID_DRIVER_NAME "ohos"

#define OHOS_DEFAULT_WIDTH  1280
#define OHOS_DEFAULT_HEIGHT 720
#define OHOS_DEFAULT_REFRESH 60.0f

/* Offsets into the frozen Meowcraft state block (see meowcraftbridge_environ.h). */
#define OHOS_MEOW_ENV_NAME    "MEOWCRAFT_ENVIRON"
#define OHOS_MEOW_WINDOW_OFF  0x000
#define OHOS_MEOW_WIDTH_OFF   0x271dc
#define OHOS_MEOW_HEIGHT_OFF  0x271e0

static bool OHOS_VideoInit(SDL_VideoDevice *_this);
static void OHOS_VideoQuit(SDL_VideoDevice *_this);
static bool OHOS_SetDisplayMode(SDL_VideoDevice *_this, SDL_VideoDisplay *display, SDL_DisplayMode *mode);
static bool OHOS_GetDisplayBounds(SDL_VideoDevice *_this, SDL_VideoDisplay *display, SDL_Rect *rect);

uintptr_t OHOS_GetBridgeBase(void)
{
    const char *published = SDL_getenv(OHOS_MEOW_ENV_NAME);

    if (!published || !*published) {
        return 0;
    }
    return (uintptr_t)SDL_strtoull(published, NULL, 16);
}

void *OHOS_GetBridgeNativeWindow(void)
{
    uintptr_t base = OHOS_GetBridgeBase();
    void *window = NULL;

    if (!base) {
        return NULL;
    }
    SDL_memcpy(&window, (const void *)(base + OHOS_MEOW_WINDOW_OFF), sizeof(window));
    return window;
}

void OHOS_GetBridgeWindowSize(int *w, int *h)
{
    uintptr_t base = OHOS_GetBridgeBase();
    int width = 0;
    int height = 0;

    if (base) {
        SDL_memcpy(&width, (const void *)(base + OHOS_MEOW_WIDTH_OFF), sizeof(width));
        SDL_memcpy(&height, (const void *)(base + OHOS_MEOW_HEIGHT_OFF), sizeof(height));
    }
    if (w) {
        *w = (width > 0) ? width : 0;
    }
    if (h) {
        *h = (height > 0) ? height : 0;
    }
}

static void OHOS_DeleteDevice(SDL_VideoDevice *device)
{
    SDL_free(device->internal);
    SDL_free(device);
}

static SDL_VideoDevice *OHOS_CreateDevice(void)
{
    SDL_VideoDevice *device;
    SDL_VideoData *data;
    int bridge_w = 0, bridge_h = 0;

    device = (SDL_VideoDevice *)SDL_calloc(1, sizeof(SDL_VideoDevice));
    if (!device) {
        return NULL;
    }
    data = (SDL_VideoData *)SDL_calloc(1, sizeof(SDL_VideoData));
    if (!data) {
        SDL_free(device);
        return NULL;
    }

    OHOS_GetBridgeWindowSize(&bridge_w, &bridge_h);
    data->native_window = OHOS_GetBridgeNativeWindow();
    data->default_width = (bridge_w > 0) ? bridge_w : OHOS_DEFAULT_WIDTH;
    data->default_height = (bridge_h > 0) ? bridge_h : OHOS_DEFAULT_HEIGHT;

    device->internal = data;

    device->VideoInit = OHOS_VideoInit;
    device->VideoQuit = OHOS_VideoQuit;
    device->SetDisplayMode = OHOS_SetDisplayMode;
    device->GetDisplayBounds = OHOS_GetDisplayBounds;
    device->PumpEvents = OHOS_PumpEvents;
    device->WaitEventTimeout = OHOS_WaitEventTimeout;

    device->CreateSDLWindow = OHOS_CreateWindow;
    device->DestroyWindow = OHOS_DestroyWindow;
    device->SetWindowSize = OHOS_SetWindowSize;
    device->GetWindowSizeInPixels = OHOS_GetWindowSizeInPixels;
    device->ShowWindow = OHOS_ShowWindow;
    device->HideWindow = OHOS_HideWindow;
    device->SetWindowFullscreen = OHOS_SetWindowFullscreen;

    /* We do not let SDL resize the window to the display mode; the real size comes
     * from ArkTS (maximize/recover) via OHOS_SyncSurfaceSize. Telling SDL we send
     * the fullscreen dimensions stops it injecting a spurious RESIZED. */
    device->device_caps |= VIDEO_DEVICE_CAPS_SENDS_FULLSCREEN_DIMENSIONS;

    device->free = OHOS_DeleteDevice;

#ifdef SDL_VIDEO_OPENGL_EGL
    device->GL_LoadLibrary = OHOS_GL_LoadLibrary;
    device->GL_GetProcAddress = OHOS_GL_GetProcAddress;
    device->GL_UnloadLibrary = OHOS_GL_UnloadLibrary;
    device->GL_CreateContext = OHOS_GL_CreateContext;
    device->GL_MakeCurrent = OHOS_GL_MakeCurrent;
    device->GL_GetEGLSurface = OHOS_GL_GetEGLSurface;
    device->GL_SetSwapInterval = OHOS_GL_SetSwapInterval;
    device->GL_GetSwapInterval = OHOS_GL_GetSwapInterval;
    device->GL_SwapWindow = OHOS_GL_SwapWindow;
    device->GL_DestroyContext = OHOS_GL_DestroyContext;
#endif

    /* Without these entries SDL_Vulkan_LoadLibrary() fails with
     * "No dynamic Vulkan support in current SDL video driver (ohos)", which is what
     * makes Minecraft's Vulkan backend refuse to come up (SDL_video.c:6261). */
#ifdef SDL_VIDEO_VULKAN
    device->Vulkan_LoadLibrary = OHOS_Vulkan_LoadLibrary;
    device->Vulkan_UnloadLibrary = OHOS_Vulkan_UnloadLibrary;
    device->Vulkan_GetInstanceExtensions = OHOS_Vulkan_GetInstanceExtensions;
    device->Vulkan_CreateSurface = OHOS_Vulkan_CreateSurface;
    device->Vulkan_DestroySurface = OHOS_Vulkan_DestroySurface;
#endif

    /* Write-only clipboard: MC 26.3 copies text (server/social links) through SDLClipboard. */
    device->SetClipboardText = OHOS_SetClipboardText;

    return device;
}

VideoBootStrap OHOS_bootstrap = {
    OHOSVID_DRIVER_NAME, "SDL OpenHarmony (OHOS) video driver",
    OHOS_CreateDevice,
    NULL, // no ShowMessageBox implementation
    false
};

static bool OHOS_VideoInit(SDL_VideoDevice *_this)
{
    SDL_VideoData *data = _this->internal;
    SDL_DisplayMode mode;
    SDL_DisplayID displayID;
    SDL_VideoDisplay *display;

    SDL_zero(mode);
    mode.format = SDL_PIXELFORMAT_XRGB8888;
    mode.w = (data && data->default_width > 0) ? data->default_width : OHOS_DEFAULT_WIDTH;
    mode.h = (data && data->default_height > 0) ? data->default_height : OHOS_DEFAULT_HEIGHT;
    mode.refresh_rate = OHOS_DEFAULT_REFRESH;

    displayID = SDL_AddBasicVideoDisplay(&mode);
    if (displayID == 0) {
        return false;
    }

    display = SDL_GetVideoDisplay(displayID);
    if (display) {
        display->natural_orientation = SDL_ORIENTATION_LANDSCAPE;
        display->current_orientation = SDL_ORIENTATION_LANDSCAPE;
        display->content_scale = 1.0f;
    }

    /* Install the mouse hooks (relative mode / warp) on SDL's SDL_Mouse. */
    OHOS_InitMouse();

    return true;
}

static void OHOS_VideoQuit(SDL_VideoDevice *_this)
{
    (void)_this;
}

static bool OHOS_SetDisplayMode(SDL_VideoDevice *_this, SDL_VideoDisplay *display, SDL_DisplayMode *mode)
{
    (void)_this;
    (void)display;
    (void)mode;
    return true;
}

static bool OHOS_GetDisplayBounds(SDL_VideoDevice *_this, SDL_VideoDisplay *display, SDL_Rect *rect)
{
    (void)_this;
    if (!display || !rect) {
        return false;
    }
    rect->x = 0;
    rect->y = 0;
    rect->w = display->desktop_mode.w;
    rect->h = display->desktop_mode.h;
    return true;
}

#endif // SDL_VIDEO_DRIVER_OHOS
