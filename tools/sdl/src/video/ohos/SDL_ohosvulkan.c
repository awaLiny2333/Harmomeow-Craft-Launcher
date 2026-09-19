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

#if defined(SDL_VIDEO_VULKAN) && defined(SDL_VIDEO_DRIVER_OHOS)

#include <dlfcn.h>
#include <stdarg.h>

#include "../SDL_vulkan_internal.h"

#include "SDL_ohoswindow.h"

#include "SDL_ohosvulkan.h"

/*
 * Logging. SDL_Log* is not usable as this fork's self-proof channel: SDL logging is
 * silenced here (neither SDL core nor this driver produced a single line in hilog or
 * in a game-dir log file, even at WARN), so anything written with SDL_LogInfo is
 * invisible exactly where it matters. hilog is what libmeowcraftbridge.so uses and
 * what the launcher exports, and unlike stderr it survives a process death (see
 * meowbt.c). Own tag, so SDL-driver lines stay distinguishable from the bridge's.
 *
 * Two channels, on purpose:
 *
 * - stderr is the primary one. It is what provably reaches the exported log (the
 *   launcher forwards the game process's stderr -- libjvm and libgraphics messages
 *   arrive that way), and it is unbuffered, so a line cannot be lost. SDL's own
 *   logging is NOT an option: the application silences it (neither SDL core nor this
 *   driver produced a single line in hilog or in a game-dir log file, even at WARN).
 * - hilog is a best-effort copy, resolved at run time. It survives a process death
 *   (see meowbt.c), but on this platform the lookup can fail, so it must never be the
 *   only channel. Linking it is not an option either: that adds a DT_NEEDED entry and
 *   trips build_sdl_meow.sh's dependency allowlist, a deliberate check in a script
 *   meant to stay app-agnostic.
 *
 * Messages are formatted here with plain printf specifiers and handed to hilog as
 * "%{public}s", so every field stays readable instead of being redacted to <private>.
 */
#define OHOS_SDL_DOMAIN 0xD003
#define OHOS_SDL_TAG "MeowSDL"

typedef int (*OHOS_LogPrintFn)(int logType, int logLevel, unsigned int domain, const char *tag, const char *fmt, ...);

#define OHOS_HILOG_APP 0
#define OHOS_HILOG_INFO 4
#define OHOS_HILOG_WARN 5
#define OHOS_HILOG_ERROR 6

static void OHOS_SDL_Log(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

static void OHOS_SDL_Log(int level, const char *fmt, ...)
{
    static OHOS_LogPrintFn hilog = NULL;
    static bool hilog_tried = false;
    char buf[512];
    va_list ap;

    if (!hilog_tried) {
        void *lib = dlopen("libhilog_ndk.z.so", RTLD_NOW | RTLD_LOCAL);

        hilog_tried = true;
        if (lib) {
            hilog = (OHOS_LogPrintFn)dlsym(lib, "OH_LOG_Print");
        }
    }

    va_start(ap, fmt);
    SDL_vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    fprintf(stderr, "MeowSDL: %s\n", buf);

    if (hilog) {
        hilog(OHOS_HILOG_APP, level, OHOS_SDL_DOMAIN, OHOS_SDL_TAG, "%{public}s", buf);
    }
}

#define OHOS_SDL_LOGI(...) OHOS_SDL_Log(OHOS_HILOG_INFO, __VA_ARGS__)
#define OHOS_SDL_LOGW(...) OHOS_SDL_Log(OHOS_HILOG_WARN, __VA_ARGS__)
#define OHOS_SDL_LOGE(...) OHOS_SDL_Log(OHOS_HILOG_ERROR, __VA_ARGS__)

/*
 * OHOS Vulkan support for this fork's `ohos` video driver.
 *
 * Local fork code, not an upstream contribution. SDL's platform backends are the
 * model (src/video/android/SDL_androidvulkan.c); the SDL-core contract is exactly
 * theirs, so the entries installed on SDL_VideoDevice by OHOS_CreateDevice() back
 * SDL_Vulkan_{LoadLibrary,UnloadLibrary,GetInstanceExtensions,CreateSurface,
 * DestroySurface}. Two of the six public functions have no vtable entry of their own:
 * SDL_Vulkan_GetVkGetInstanceProcAddr hands back the pointer this file stores in
 * vulkan_config -- that pointer is the whole reason the loader is chosen here -- and
 * Vulkan_GetPresentationSupport is deliberately left unset, so SDL reports "always
 * supported", the same simplification the GLFW bridge makes
 * (glfwGetPhysicalDevicePresentationSupport always returns 1).
 *
 * Two deviations from those ports, both forced by this platform:
 *
 * 1. SDL 3.4.14's bundled Khronos headers predate the OHOS surface extension (no
 *    vulkan_ohos.h, no VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS), so the WSI
 *    symbols are declared locally. Their values equal the ones the HarmonyOS port
 *    later added upstream (vulkan_core.h:1402 -> 1000685000, vulkan_ohos.h:95 ->
 *    "VK_OHOS_surface") and the ones libmeowcraftbridge.so already uses on the
 *    GLFW path.
 *
 * 2. SDL does not own the window here: ArkTS owns the OHNativeWindow and publishes it
 *    to native code, so this driver just hands that handle to vkCreateSurfaceOHOS. It
 *    deliberately does NOT reproduce the bridge's pre-surface window policy (producer
 *    buffer geometry pinning + file-driven usage/format): the bridge and ArkTS already
 *    set both when the surface id is published, and the surface plus swapchain come up
 *    correctly without it (measured 2026-09-19). Keeping the driver free of a
 *    libmeowcraftbridge.so dependency also avoids a silent-degradation path -- the
 *    bare-name dlopen such a call needs does not resolve.
 *
 * Loader choice: a path passed by the application always wins -- that is what keeps
 * vkGetInstanceProcAddr identical to the pointer LWJGL resolved, the same identity
 * contract SDL_GL_GetProcAddress satisfies for GL. Otherwise SDL_HINT_VULKAN_LIBRARY
 * is consulted (SDL_GetHint falls back to the environment, so e.g.
 * SDL_VULKAN_LIBRARY=libmeowvulkan.so switches loader with no rebuild); otherwise
 * the system loader is used.
 */

/* --- OHOS WSI, absent from SDL 3.4.14's bundled Khronos headers -------------- */

#define OHOS_VK_SURFACE_EXTENSION_NAME "VK_OHOS_surface"
#define OHOS_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS 1000685000

typedef struct OHOS_VkSurfaceCreateInfo {
    VkStructureType sType;
    const void *pNext;
    uint32_t flags;
    void *window; /* OHNativeWindow * */
} OHOS_VkSurfaceCreateInfo;

typedef VkResult (*PFN_OHOS_vkCreateSurfaceOHOS)(VkInstance instance,
                                                const OHOS_VkSurfaceCreateInfo *pCreateInfo,
                                                const VkAllocationCallbacks *pAllocator,
                                                VkSurfaceKHR *pSurface);

bool OHOS_Vulkan_LoadLibrary(SDL_VideoDevice *_this, const char *path)
{
    VkExtensionProperties *extensions = NULL;
    Uint32 extensionCount = 0;
    bool hasSurfaceExtension = false;
    bool hasOHOSSurfaceExtension = false;
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = NULL;
    const char *source = "application";

    if (_this->vulkan_config.loader_handle) {
        return SDL_SetError("Vulkan already loaded");
    }

    if (!path) {
        path = SDL_GetHint(SDL_HINT_VULKAN_LIBRARY);
        source = "SDL_HINT_VULKAN_LIBRARY";
    }
    if (!path) {
        path = "libvulkan.so";
        source = "system default";
    }

    _this->vulkan_config.loader_handle = SDL_LoadObject(path);
    if (!_this->vulkan_config.loader_handle) {
        OHOS_SDL_LOGE("Vulkan loader '%s' (source=%s) failed: %s",
                      path, source, SDL_GetError());
        return false;
    }

    SDL_strlcpy(_this->vulkan_config.loader_path, path, sizeof(_this->vulkan_config.loader_path));
    OHOS_SDL_LOGI("Vulkan loader '%s' loaded (source=%s)", path, source);

    vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)SDL_LoadFunction(_this->vulkan_config.loader_handle, "vkGetInstanceProcAddr");
    if (!vkGetInstanceProcAddr) {
        goto fail;
    }

    _this->vulkan_config.vkGetInstanceProcAddr = (void *)vkGetInstanceProcAddr;
    _this->vulkan_config.vkEnumerateInstanceExtensionProperties = (void *)((PFN_vkGetInstanceProcAddr)_this->vulkan_config.vkGetInstanceProcAddr)(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
    if (!_this->vulkan_config.vkEnumerateInstanceExtensionProperties) {
        goto fail;
    }

    extensions = SDL_Vulkan_CreateInstanceExtensionsList((PFN_vkEnumerateInstanceExtensionProperties)_this->vulkan_config.vkEnumerateInstanceExtensionProperties, &extensionCount);
    if (!extensions) {
        goto fail;
    }

    for (Uint32 i = 0; i < extensionCount; i++) {
        if (SDL_strcmp(VK_KHR_SURFACE_EXTENSION_NAME, extensions[i].extensionName) == 0) {
            hasSurfaceExtension = true;
        } else if (SDL_strcmp(OHOS_VK_SURFACE_EXTENSION_NAME, extensions[i].extensionName) == 0) {
            hasOHOSSurfaceExtension = true;
        }
    }

    SDL_free(extensions);

    if (!hasSurfaceExtension) {
        SDL_SetError("Installed Vulkan doesn't implement the " VK_KHR_SURFACE_EXTENSION_NAME " extension");
        goto fail;
    } else if (!hasOHOSSurfaceExtension) {
        SDL_SetError("Installed Vulkan doesn't implement the " OHOS_VK_SURFACE_EXTENSION_NAME " extension");
        goto fail;
    }

    OHOS_SDL_LOGI("Vulkan instance surface extensions available (%u enumerated)",
                  (unsigned)extensionCount);
    return true;

fail:
    OHOS_SDL_LOGE("Vulkan loader '%s' unusable: %s", path, SDL_GetError());
    SDL_UnloadObject(_this->vulkan_config.loader_handle);
    _this->vulkan_config.loader_handle = NULL;
    return false;
}

void OHOS_Vulkan_UnloadLibrary(SDL_VideoDevice *_this)
{
    if (_this->vulkan_config.loader_handle) {
        SDL_UnloadObject(_this->vulkan_config.loader_handle);
        _this->vulkan_config.loader_handle = NULL;
    }
}

char const * const *OHOS_Vulkan_GetInstanceExtensions(SDL_VideoDevice *_this, Uint32 *count)
{
    static const char *const extensionsForOHOS[] = {
        VK_KHR_SURFACE_EXTENSION_NAME, OHOS_VK_SURFACE_EXTENSION_NAME
    };
    (void)_this;
    if (count) {
        *count = SDL_arraysize(extensionsForOHOS);
    }
    OHOS_SDL_LOGI("GetInstanceExtensions -> {VK_KHR_surface, VK_OHOS_surface}");
    return extensionsForOHOS;
}

bool OHOS_Vulkan_CreateSurface(SDL_VideoDevice *_this,
                               SDL_Window *window,
                               VkInstance instance,
                               const struct VkAllocationCallbacks *allocator,
                               VkSurfaceKHR *surface)
{
    SDL_WindowData *windowData = window ? window->internal : NULL;
    PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)_this->vulkan_config.vkGetInstanceProcAddr;
    PFN_OHOS_vkCreateSurfaceOHOS vkCreateSurfaceOHOS;
    OHOS_VkSurfaceCreateInfo createInfo;
    VkResult result;

    if (!_this->vulkan_config.loader_handle) {
        return SDL_SetError("Vulkan is not loaded");
    }

    if (!windowData || !windowData->native_window) {
        return SDL_SetError("ohos: no external OHNativeWindow on this window");
    }

    vkCreateSurfaceOHOS = (PFN_OHOS_vkCreateSurfaceOHOS)vkGetInstanceProcAddr(instance, "vkCreateSurfaceOHOS");
    if (!vkCreateSurfaceOHOS) {
        return SDL_SetError(OHOS_VK_SURFACE_EXTENSION_NAME " extension is not enabled in the Vulkan instance");
    }

    /* Deliberately no window policy here. The bridge's own glfwCreateWindowSurface pins
     * the producer buffer geometry and applies its file-driven usage/format policy
     * before creating the surface, but on this path the bridge and ArkTS have already
     * set both by the time the surface id is published, and the surface plus swapchain
     * come up correctly without it (measured 2026-09-19: swapchain created, 70-80 FPS).
     * Not reaching into libmeowcraftbridge.so also removes a silent-degradation path --
     * the bare-name dlopen it would need does not resolve, because the bridge is loaded
     * by absolute path. */

    SDL_zero(createInfo);
    createInfo.sType = (VkStructureType)OHOS_VK_STRUCTURE_TYPE_SURFACE_CREATE_INFO_OHOS;
    createInfo.pNext = NULL;
    createInfo.flags = 0;
    createInfo.window = windowData->native_window;

    result = vkCreateSurfaceOHOS(instance, &createInfo, allocator, surface);
    if (result != VK_SUCCESS) {
        if (result == VK_ERROR_NATIVE_WINDOW_IN_USE_KHR) {
            return SDL_SetError("vkCreateSurfaceOHOS failed: %s, was the window created with SDL_WINDOW_VULKAN?", SDL_Vulkan_GetResultString(result));
        } else {
            return SDL_SetError("vkCreateSurfaceOHOS failed: %s", SDL_Vulkan_GetResultString(result));
        }
    }

    OHOS_SDL_LOGI("vkCreateSurfaceOHOS ok (external window attached)");
    return true;
}

void OHOS_Vulkan_DestroySurface(SDL_VideoDevice *_this,
                                VkInstance instance,
                                VkSurfaceKHR surface,
                                const struct VkAllocationCallbacks *allocator)
{
    if (_this->vulkan_config.loader_handle) {
        SDL_Vulkan_DestroySurface_Internal(_this->vulkan_config.vkGetInstanceProcAddr, instance, surface, allocator);
    }
}

#endif // SDL_VIDEO_VULKAN && SDL_VIDEO_DRIVER_OHOS
