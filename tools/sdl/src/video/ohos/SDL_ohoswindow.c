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

#include <native_window/external_window.h>

#include "../SDL_sysvideo.h"
#include "../../events/SDL_keyboard_c.h"
#include "../../events/SDL_mouse_c.h"
#include "../../events/SDL_windowevents_c.h"

#include "SDL_ohosvideo.h"
#include "SDL_ohoswindow.h"
#include "ohos_meow_environ.h"

extern uintptr_t OHOS_GetBridgeBase(void);

/*
 * Resolve the OHNativeWindow* for a new window:
 *   1. the explicit create-time SDL property (tools that embed SDL can pass it), or
 *   2. the Meowcraft bridge's shared state (MEOWCRAFT_ENVIRON), where ArkTS
 *      publishes the window it created from the XComponent surface id.
 */
static void *OHOS_ResolveNativeWindow(SDL_PropertiesID create_props)
{
    void *native = NULL;

    if (create_props) {
        native = SDL_GetPointerProperty(create_props, SDL_PROP_WINDOW_CREATE_OHOS_NATIVE_WINDOW_POINTER, NULL);
    }
    if (!native) {
        native = OHOS_GetBridgeNativeWindow();
    }
    return native;
}

/* Pin the producer buffer geometry to the real client size. Without this the
 * OHNativeWindow keeps whatever geometry was set when the surface id was first
 * bound, so the EGL window surface size can disagree with the XComponent. */
static void OHOS_ApplyBufferGeometry(void *native, int w, int h)
{
    if (native && w > 0 && h > 0) {
        OH_NativeWindow_NativeWindowHandleOpt((OHNativeWindow *)native, SET_BUFFER_GEOMETRY, w, h);
    }
}

bool OHOS_CreateWindow(SDL_VideoDevice *_this, SDL_Window *window, SDL_PropertiesID create_props)
{
    SDL_VideoData *videodata = _this->internal;
    SDL_WindowData *data;
    int bridge_w = 0, bridge_h = 0;

    data = (SDL_WindowData *)SDL_calloc(1, sizeof(SDL_WindowData));
    if (!data) {
        return false;
    }

    data->sdl_window = window;
    data->native_window = OHOS_ResolveNativeWindow(create_props);
#ifdef SDL_VIDEO_OPENGL_EGL
    data->egl_surface = EGL_NO_SURFACE;
#endif

    /*
     * The surface geometry is authoritative on the ArkTS side. Mirror it when
     * known so SDL's window size matches the XComponent surface, otherwise fall
     * back to the requested size and finally to a sane desktop default.
     */
    OHOS_GetBridgeWindowSize(&bridge_w, &bridge_h);
    if (bridge_w > 0 && bridge_h > 0) {
        window->w = bridge_w;
        window->h = bridge_h;
    } else {
        if (window->w <= 0) {
            window->w = (videodata && videodata->default_width > 0) ? videodata->default_width : 1280;
        }
        if (window->h <= 0) {
            window->h = (videodata && videodata->default_height > 0) ? videodata->default_height : 720;
        }
    }

    if (window->x == SDL_WINDOWPOS_UNDEFINED) {
        window->x = 0;
    }
    if (window->y == SDL_WINDOWPOS_UNDEFINED) {
        window->y = 0;
    }

    /* The native window belongs to ArkTS: SDL must never own or destroy it. */
    window->flags |= SDL_WINDOW_EXTERNAL;

    /* Our external window is always shown (ArkTS owns it). SDL never clears
     * SDL_WINDOW_HIDDEN itself, and a hidden window short-circuits
     * SDL_SetWindowFullscreen / SetWindowSize / … before reaching the driver. */
    window->flags &= ~SDL_WINDOW_HIDDEN;

    if (data->native_window) {
        SDL_SetPointerProperty(SDL_GetWindowProperties(window),
                               SDL_PROP_WINDOW_OHOS_NATIVE_WINDOW_POINTER,
                               data->native_window);
    }

    window->internal = data;

    /* Single full-screen surface: make it the focus target for later input. */
    SDL_SetMouseFocus(window);
    SDL_SetKeyboardFocus(window);

    return true;
}

void OHOS_DestroyWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    SDL_WindowData *data = window ? window->internal : NULL;

    if (data) {
#ifdef SDL_VIDEO_OPENGL_EGL
        /*
         * The EGL surface is SHARED across all SDL windows (a single external
         * OHNativeWindow serves the whole app). Do NOT destroy it here: MC 26.3
         * creates probe/test windows and destroys them, which would otherwise
         * blank the real game window's surface. It is released at GL unload.
         */
        data->egl_surface = EGL_NO_SURFACE;
#endif
        SDL_free(data);
        window->internal = NULL;
    }
}

void OHOS_SetWindowSize(SDL_VideoDevice *_this, SDL_Window *window)
{
    /* External window: ArkTS owns the size. Ignore Minecraft's request (it asks
     * for its own default, e.g. 1280x720, which does not match the client area);
     * OHOS_SyncSurfaceSize() drives the real size from the bridge every frame. */
    (void)_this;
    (void)window;
}

void OHOS_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h)
{
    (void)_this;
    if (w) {
        *w = window ? window->w : 0;
    }
    if (h) {
        *h = window ? window->h : 0;
    }
}

/* ArkTS owns the external window's visibility, but SDL still needs to learn the
 * window is shown: SDL_WINDOW_HIDDEN gates SDL_SetWindowFullscreen (and
 * SetWindowSize/Position/Raise…). Real drivers clear/set the flag here; without
 * it F11 never reaches our SetWindowFullscreen. */
void OHOS_ShowWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    (void)_this;
    if (window) {
        window->flags &= ~SDL_WINDOW_HIDDEN;
    }
}

void OHOS_HideWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    (void)_this;
    if (window) {
        window->flags |= SDL_WINDOW_HIDDEN;
    }
}

/* MC's SDL_SetWindowFullscreen arrives here. We never resize an external window;
 * instead we forward the request to the ArkTS window owner (the same
 * maximize()/recover() chain the GLFW path used) and report success so SDL core
 * sets SDL_WINDOW_FULLSCREEN and posts ENTER/LEAVE_FULLSCREEN. The real pixel
 * size then arrives via OHOS_SyncSurfaceSize. */
SDL_FullscreenResult OHOS_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *window,
                                              SDL_VideoDisplay *display, SDL_FullscreenOp fullscreen)
{
    struct meow_environ_s *env = (struct meow_environ_s *)OHOS_GetBridgeBase();
    int want = (fullscreen == SDL_FULLSCREEN_OP_ENTER) ? 1 : 0;

    (void)_this;
    (void)window;
    (void)display;

    /* The bridge and this driver share the meow_environ block (MEOWCRAFT_ENVIRON),
     * so we raise the request by writing its fs* fields directly -- no dlsym, which
     * does not resolve across linker namespaces. ArkTS polls it via
     * takeFullscreenRequest and drives maximize()/recover(). */
    if (env != NULL && want != env->fsActive) {
        env->fsActive = want;
        env->fsX = 0;
        env->fsY = 0;
        env->fsW = 0;
        env->fsH = 0;
        env->fsRequest = want ? 1 : 2;
    }
    return SDL_FULLSCREEN_SUCCEEDED;
}

#ifdef SDL_VIDEO_OPENGL_EGL
/*
 * One external OHNativeWindow serves the whole app, so every SDL window shares a
 * single EGL surface. MC 26.3 opens several SDL windows (a hidden probe window,
 * the real game window, and a throwaway test window it destroys); binding each
 * to its own eglCreateWindowSurface on the same native window, and tearing the
 * surface down when any window went away, left nothing presented -> black screen.
 */
static EGLSurface ohos_shared_egl_surface = EGL_NO_SURFACE;

EGLSurface OHOS_EnsureEGLSurface(SDL_VideoDevice *_this, SDL_Window *window)
{
    SDL_WindowData *data = window ? window->internal : NULL;

    if (!data) {
        return EGL_NO_SURFACE;
    }
    if (ohos_shared_egl_surface != EGL_NO_SURFACE) {
        data->egl_surface = ohos_shared_egl_surface;
        return ohos_shared_egl_surface;
    }
    if (!data->native_window) {
        /* The bridge may publish the window after SDL window creation. */
        data->native_window = OHOS_GetBridgeNativeWindow();
        if (data->native_window) {
            SDL_SetPointerProperty(SDL_GetWindowProperties(window),
                                   SDL_PROP_WINDOW_OHOS_NATIVE_WINDOW_POINTER,
                                   data->native_window);
        }
    }
    if (!data->native_window || !_this->egl_data) {
        return EGL_NO_SURFACE;
    }

    OHOS_ApplyBufferGeometry(data->native_window, window->w, window->h);

    ohos_shared_egl_surface = SDL_EGL_CreateSurface(_this, window, (NativeWindowType)data->native_window);
    data->egl_surface = ohos_shared_egl_surface;
    if (ohos_shared_egl_surface == EGL_NO_SURFACE) {
        SDL_LogWarn(SDL_LOG_CATEGORY_VIDEO, "ohos: SDL_EGL_CreateSurface failed");
    }
    return ohos_shared_egl_surface;
}

void OHOS_DestroySharedEGLSurface(SDL_VideoDevice *_this)
{
    if (ohos_shared_egl_surface != EGL_NO_SURFACE) {
        SDL_EGL_DestroySurface(_this, ohos_shared_egl_surface);
        ohos_shared_egl_surface = EGL_NO_SURFACE;
    }
}
#endif // SDL_VIDEO_OPENGL_EGL

void OHOS_SyncSurfaceSize(SDL_VideoDevice *_this)
{
    SDL_Window *window;
    SDL_WindowData *data;
    void *native = NULL;
    int bw = 0, bh = 0;
    bool changed = false;

    OHOS_GetBridgeWindowSize(&bw, &bh);
    if (bw <= 0 || bh <= 0) {
        return;
    }

    for (window = _this->windows; window; window = window->next) {
        if (window->is_destroying) {
            continue;
        }
        if (!native) {
            data = window->internal;
            native = data ? data->native_window : NULL;
        }
        if (window->w == bw && window->h == bh) {
            continue;
        }
        /* Notify BEFORE updating window->w/h: SDL drops a RESIZED event whose
         * size equals window->w, so the still-stale value is what makes it post.
         * Minecraft updates its window height only from this event (SDL path). */
        SDL_SendWindowEvent(window, SDL_EVENT_WINDOW_RESIZED, bw, bh);
        SDL_SendWindowEvent(window, SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, bw, bh);
        window->w = bw;
        window->h = bh;
        window->pending.w = bw;
        window->pending.h = bh;
        changed = true;
    }

    /* Only on a REAL size change: re-pin the native window buffer geometry. We do
     * NOT destroy/recreate the EGL surface here: this runs inside the render
     * thread's event pump, and tearing the current surface down mid-frame made
     * the picture freeze. */
    if (!changed) {
        return;
    }
    OHOS_ApplyBufferGeometry(native, bw, bh);
}

#endif // SDL_VIDEO_DRIVER_OHOS
