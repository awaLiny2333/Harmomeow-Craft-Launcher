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

#include <stdio.h>

#include "../SDL_sysurl.h"

/*
 * Opening links on OHOS, for this fork.
 *
 * MC >= 26.3 opens links through SDLMisc.SDL_OpenURL -> SDL_OpenURL -> SDL_SYS_OpenURL.
 * Upstream picks src/misc/<platform>/SDL_sysurl.c; without this file our build (which the
 * toolchain relabels as Linux) takes src/misc/unix/SDL_sysurl.c, i.e. fork+exec
 * "xdg-open" -- a program that does not exist on OHOS, so clicking a link did nothing.
 *
 * OHOS has no native "open this URL" entry point. The platform-correct way is an implicit
 * Want (action ohos.want.action.viewData + uri) issued by an Ability, which only the
 * ArkTS side can do -- upstream's HarmonyOS port does the same thing by calling back into
 * ArkTS. So this writes the request to a file and lets the app pick it up (the same
 * native->ArkTS channel shape the launcher already uses for fullscreen).
 *
 * Request file: $HOME/meow-open-url.txt, written via a temp file + rename so the reader
 * never sees a half-written URL. HOME is the app files dir: the bridge sets it
 * (meowjrebridge.cpp) before the JVM starts, and the ArkTS side computes the same path
 * from its UIAbilityContext. MEOWCRAFT_HOME is only a JVM -D property (never an
 * environment variable), so it is not used here.
 */

#define OHOS_URL_FILE "meow-open-url.txt"

bool SDL_SYS_OpenURL(const char *url)
{
    const char *home = SDL_getenv("HOME");
    char path[512];
    char temp[512];
    size_t length;
    FILE *file;

    if (!url) {
        return SDL_InvalidParamError("url");
    }
    if (!home || !*home) {
        return SDL_SetError("ohos: HOME is not set, cannot hand the URL over");
    }
    if (SDL_snprintf(path, sizeof(path), "%s/%s", home, OHOS_URL_FILE) < 0 ||
        SDL_snprintf(temp, sizeof(temp), "%s.tmp", path) < 0) {
        return SDL_SetError("ohos: request path too long");
    }

    length = SDL_strlen(url);
    file = fopen(temp, "wb");
    if (file == NULL) {
        SDL_SetError("ohos: cannot write %s", temp);
        fprintf(stderr, "MeowSDL: open-url failed: %s\n", SDL_GetError());
        return false;
    }
    if (fwrite(url, 1, length, file) != length) {
        fclose(file);
        SDL_SetError("ohos: cannot write %s", temp);
        fprintf(stderr, "MeowSDL: open-url failed: %s\n", SDL_GetError());
        return false;
    }
    if (fclose(file) != 0) {
        SDL_SetError("ohos: cannot flush %s", temp);
        fprintf(stderr, "MeowSDL: open-url failed: %s\n", SDL_GetError());
        return false;
    }
    if (rename(temp, path) != 0) {
        remove(temp);
        SDL_SetError("ohos: cannot publish %s", path);
        fprintf(stderr, "MeowSDL: open-url failed: %s\n", SDL_GetError());
        return false;
    }
    /* stderr, not SDL_Log: the application silences SDL's logging, while the launcher
     * forwards the game process stderr (visible as [jre_stderr]). */
    fprintf(stderr, "MeowSDL: open-url request written (%d bytes)\n", (int)length);
    return true;
}

#endif // SDL_VIDEO_DRIVER_OHOS
