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

#include "../../events/SDL_mouse_c.h"

#include "SDL_ohosvideo.h"
#include "SDL_ohosmouse.h"
#include "SDL_ohosevents.h"
#include "ohos_meow_environ.h"

extern uintptr_t OHOS_GetBridgeBase(void);

/*
 * Mouse hooks (SDL_Mouse, installed via SDL_GetMouse()). Minecraft 26.3 grabs
 * the cursor with SDL_WarpMouseInWindow() + SDL_SetWindowRelativeMouseMode(true);
 * if the driver leaves these NULL, SDL returns "Unsupported" and the game never
 * enters relative mode.
 *
 * We reuse the existing Meowcraft grab pipeline: `env->grabbing` is polled by
 * ArkTS (which then LockCursor()s and hides the pointer) and gates the NDK
 * overlay's raw deltas; OHOS_PumpEvents() differences the bridge virtual cursor
 * and forwards it as relative SDL motion.
 */

static bool OHOS_SetRelativeMouseMode(bool enabled)
{
    struct meow_environ_s *env = (struct meow_environ_s *)OHOS_GetBridgeBase();

    if (!env) {
        return false;
    }
    env->grabbing = enabled ? 1 : 0;
    env->isGrabbing = enabled ? 1u : 0u;
    OHOS_TraceGrabMode(enabled ? 1 : 0, env->grabbing);
    return true;
}

static bool OHOS_WarpMouse(SDL_Window *window, float x, float y)
{
    struct meow_environ_s *env;

    (void)window;
    /* OHOS has no OS cursor-warp API. Centre the bridge's virtual cursor (the
     * grab baseline is re-seeded by OHOS_PumpEvents when relative mode starts). */
    env = (struct meow_environ_s *)OHOS_GetBridgeBase();
    if (env) {
        /* relmode is SDL core's own state (SDL_GetRelativeMouseMode()); it is
         * logged because SDL core only forwards to this hook while it is false
         * (src/events/SDL_mouse.c: SDL_PerformWarpMouseInWindow). */
        OHOS_TraceWarp(x, y, env->grabbing, SDL_GetRelativeMouseMode() ? 1 : 0);
        env->cursorX = (double)x;
        env->cursorY = (double)y;
    }
    return true;
}

void OHOS_InitMouse(void)
{
    SDL_Mouse *mouse = SDL_GetMouse();

    if (mouse) {
        mouse->SetRelativeMouseMode = OHOS_SetRelativeMouseMode;
        mouse->WarpMouse = OHOS_WarpMouse;
    }
}

#endif // SDL_VIDEO_DRIVER_OHOS
