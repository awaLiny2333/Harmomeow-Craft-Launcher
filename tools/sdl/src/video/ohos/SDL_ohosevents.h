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

#ifndef SDL_ohosevents_h_
#define SDL_ohosevents_h_

#include "../SDL_sysvideo.h"

/* Input is delivered by the ArkTS bridge in a later phase; for now the pump is
 * a defined no-op so SDL_PumpEvents() has a valid backend entry point. */
extern void OHOS_PumpEvents(SDL_VideoDevice *_this);
extern int OHOS_WaitEventTimeout(SDL_VideoDevice *_this, Sint64 timeoutNS);

/*
 * Diagnostic motion tracing (DELIBERATELY always-on in this build).
 *
 * There are several independent writers of the bridge virtual cursor
 * (env->cursorX/Y) and of SDL motion, and a left-click view nudge has no
 * single confirmed origin. These helpers emit rate-limited, deduplicated
 * `fprintf(stderr, ...)` lines (SDL_Log is invisible on this platform, see
 * tools/sdl/README.md section 6) so the next on-device log names the source.
 *
 * Defined in SDL_ohosevents.c, shared with SDL_ohosmouse.c. Remove together
 * with the call sites once the origin is pinned down.
 */
extern void OHOS_TraceMotion(const char *src, float dx, float dy, int grabbing, int relActive,
                             double cursorX, double cursorY, double lastX, double lastY);
extern void OHOS_TraceButton(const char *phase, int btn, int grabbing);
extern void OHOS_TraceWarpIgnored(float x, float y, int grabbing, int relmode);
extern void OHOS_TraceGrabMode(int enabled, int grabbing);

#endif // SDL_ohosevents_h_
