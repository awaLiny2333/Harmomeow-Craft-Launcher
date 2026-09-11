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

#ifndef SDL_ohoswindow_h_
#define SDL_ohoswindow_h_

#include "../SDL_sysvideo.h"

#ifdef SDL_VIDEO_OPENGL_EGL
#include "../SDL_egl_c.h"
#endif

struct SDL_WindowData
{
    SDL_Window *sdl_window;
    void *native_window; // OHNativeWindow* owned by ArkTS, never released here
#ifdef SDL_VIDEO_OPENGL_EGL
    EGLSurface egl_surface;
#endif
};

extern bool OHOS_CreateWindow(SDL_VideoDevice *_this, SDL_Window *window, SDL_PropertiesID create_props);
extern void OHOS_DestroyWindow(SDL_VideoDevice *_this, SDL_Window *window);
extern void OHOS_SetWindowSize(SDL_VideoDevice *_this, SDL_Window *window);
extern void OHOS_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h);
extern void OHOS_ShowWindow(SDL_VideoDevice *_this, SDL_Window *window);
extern void OHOS_HideWindow(SDL_VideoDevice *_this, SDL_Window *window);

/* Fullscreen: forward MC's SDL_SetWindowFullscreen to the ArkTS maximize/recover
 * chain (via the bridge's plain-C request) and let SDL core track the flag/events. */
extern SDL_FullscreenResult OHOS_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *window,
                                                     SDL_VideoDisplay *display, SDL_FullscreenOp fullscreen);

#ifdef SDL_VIDEO_OPENGL_EGL
/* Lazily build (once) and return the process-wide shared EGL surface, which is
 * bound to the single external OHNativeWindow ArkTS owns. */
extern EGLSurface OHOS_EnsureEGLSurface(SDL_VideoDevice *_this, SDL_Window *window);
/* Release the shared EGL surface (at GL unload / video quit). */
extern void OHOS_DestroySharedEGLSurface(SDL_VideoDevice *_this);
#endif

/* Follow the ArkTS surface size: when the bridge reports a new size, update the
 * SDL windows, re-pin the native window buffer geometry and rebuild the shared
 * EGL surface. Called every PumpEvents. */
extern void OHOS_SyncSurfaceSize(SDL_VideoDevice *_this);

/* Custom window properties advertised by this driver. */
#define SDL_PROP_WINDOW_OHOS_NATIVE_WINDOW_POINTER        "SDL.window.ohos.native_window"
#define SDL_PROP_WINDOW_CREATE_OHOS_NATIVE_WINDOW_POINTER "SDL.window.create.ohos.native_window"

#endif // SDL_ohoswindow_h_
