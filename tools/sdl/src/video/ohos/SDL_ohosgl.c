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

#if defined(SDL_VIDEO_DRIVER_OHOS) && defined(SDL_VIDEO_OPENGL_EGL)

#include <dlfcn.h>

#include "../SDL_egl_c.h"
#include "SDL_ohosgl.h"
#include "SDL_ohoswindow.h"

/*
 * EGL provides context/surface/swap, but GL *entry-point resolution* must match
 * the module Minecraft's LWJGL side already holds: MC 26.3's renderpearl
 * GlBackend.loadLibrary() asserts
 *     GL.getFunctionProvider().getFunctionAddress("glGetError")
 *         == SDL_GL_GetProcAddress("glGetError")
 * i.e. pointer identity. LWJGL resolves GL symbols with dlsym() on the library
 * path it loaded (MC passes that exact path to SDL_GL_LoadLibrary). So we dlopen
 * that same path and serve SDL_GL_GetProcAddress() through dlsym() -- NOT through
 * eglGetProcAddress(), which returns EGL dispatch stubs and would fail the check.
 * Surfaces are built on the external OHNativeWindow* the ArkTS side owns.
 */

static void *ohos_gl_handle = NULL;

bool OHOS_GL_LoadLibrary(SDL_VideoDevice *_this, const char *path)
{
    if (!SDL_EGL_LoadLibrary(_this, path, (NativeDisplayType)0, 0)) {
        return false;
    }
    if (!ohos_gl_handle) {
        const char *lib = (path && *path) ? path : "libGLv4.so";
        ohos_gl_handle = dlopen(lib, RTLD_NOW | RTLD_GLOBAL);
        if (!ohos_gl_handle) {
            // Non-fatal: fall back to EGL proc addresses (identity check may fail).
            SDL_LogWarn(SDL_LOG_CATEGORY_VIDEO,
                        "ohos: dlopen('%s') for GL proc identity failed: %s",
                        lib, dlerror());
        }
    }
    return true;
}

SDL_FunctionPointer OHOS_GL_GetProcAddress(SDL_VideoDevice *_this, const char *proc)
{
    if (ohos_gl_handle) {
        void *p = dlsym(ohos_gl_handle, proc);
        if (p) {
            return (SDL_FunctionPointer)p;
        }
    }
    return SDL_EGL_GetProcAddressInternal(_this, proc);
}

void OHOS_GL_UnloadLibrary(SDL_VideoDevice *_this)
{
    OHOS_DestroySharedEGLSurface(_this);
    if (ohos_gl_handle) {
        dlclose(ohos_gl_handle);
        ohos_gl_handle = NULL;
    }
    SDL_EGL_UnloadLibrary(_this);
}

SDL_GLContext OHOS_GL_CreateContext(SDL_VideoDevice *_this, SDL_Window *window)
{
    EGLSurface surface = EGL_NO_SURFACE;

    if (window) {
        surface = OHOS_EnsureEGLSurface(_this, window);
    }
    return SDL_EGL_CreateContext(_this, surface);
}

bool OHOS_GL_MakeCurrent(SDL_VideoDevice *_this, SDL_Window *window, SDL_GLContext context)
{
    EGLSurface surface = EGL_NO_SURFACE;

    if (window) {
        surface = OHOS_EnsureEGLSurface(_this, window);
    }
    return SDL_EGL_MakeCurrent(_this, surface, context);
}

bool OHOS_GL_SetSwapInterval(SDL_VideoDevice *_this, int interval)
{
    return SDL_EGL_SetSwapInterval(_this, interval);
}

bool OHOS_GL_GetSwapInterval(SDL_VideoDevice *_this, int *interval)
{
    return SDL_EGL_GetSwapInterval(_this, interval);
}

bool OHOS_GL_SwapWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    // Ensure the (shared) surface: MC may present on a window whose surface was
    // never created by an earlier MakeCurrent (e.g. the real game window).
    EGLSurface surface = OHOS_EnsureEGLSurface(_this, window);

    if (surface == EGL_NO_SURFACE) {
        return SDL_SetError("ohos: no EGL surface for window");
    }
    return SDL_EGL_SwapBuffers(_this, surface);
}

bool OHOS_GL_DestroyContext(SDL_VideoDevice *_this, SDL_GLContext context)
{
    return SDL_EGL_DestroyContext(_this, context);
}

EGLSurface OHOS_GL_GetEGLSurface(SDL_VideoDevice *_this, SDL_Window *window)
{
    (void)_this;
    return window ? OHOS_EnsureEGLSurface(_this, window) : EGL_NO_SURFACE;
}

#endif // SDL_VIDEO_DRIVER_OHOS && SDL_VIDEO_OPENGL_EGL
