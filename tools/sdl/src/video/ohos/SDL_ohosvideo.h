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

#ifndef SDL_ohosvideo_h_
#define SDL_ohosvideo_h_

#include "../SDL_sysvideo.h"

/*
 * OpenHarmony / OHOS video driver.
 *
 * The window itself is owned by the ArkTS side: it hands us an OHNativeWindow*
 * through the Meowcraft shared state block (see OHOS_GetBridgeNativeWindow()).
 * SDL therefore treats the window as external and never creates, shows or
 * destroys the platform window; it only wraps it and builds an EGL surface on
 * top of it.
 */

struct SDL_VideoData
{
    void *native_window; // OHNativeWindow* mirrored from the Meowcraft bridge (may be NULL)
    int default_width;   // desktop/window width hint, 0 when unknown
    int default_height;  // desktop/window height hint, 0 when unknown
};

/*
 * Meowcraft bridge accessors. MEOWCRAFT_ENVIRON holds the address of the frozen
 * meow_environ state block as a hexadecimal string; field offsets are part of
 * that ABI (window at 0x000, width at 0x271dc, height at 0x271e0).
 */
extern void *OHOS_GetBridgeNativeWindow(void);
extern void OHOS_GetBridgeWindowSize(int *w, int *h);

#endif // SDL_ohosvideo_h_
