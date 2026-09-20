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

#include "../../events/SDL_events_c.h"
#include "../../events/SDL_keyboard_c.h"
#include "../../events/SDL_mouse_c.h"

#include "SDL_ohosvideo.h"
#include "SDL_ohoswindow.h"
#include "SDL_ohosevents.h"
#include "ohos_meow_environ.h"

extern uintptr_t OHOS_GetBridgeBase(void);

/*
 * Input comes in through the Meowcraft ArkTS bridge, which feeds an SPSC ring
 * inside the shared state block (MEOWCRAFT_ENVIRON). The ArkTS side already
 * converts key/button codes to GLFW's numbering (identical to the GLFW path),
 * so here we drain that ring and translate each entry into SDL events via the
 * internal SDL_Send* helpers, so SDL's own keyboard/mouse state stays correct.
 */

/* GLFW key -> SDL scancode. GLFW uses its own logical numbering; SDL scancodes
 * are USB-HID usage codes (physical keys). Ranges are arithmetic on the enum. */
static SDL_Scancode OHOS_GlfwToScancode(int key)
{
    if (key >= 65 && key <= 90) { /* A..Z */
        return (SDL_Scancode)(SDL_SCANCODE_A + (key - 65));
    }
    if (key >= 49 && key <= 57) { /* '1'..'9' */
        return (SDL_Scancode)(SDL_SCANCODE_1 + (key - 49));
    }
    if (key >= 290 && key <= 301) { /* F1..F12 */
        return (SDL_Scancode)(SDL_SCANCODE_F1 + (key - 290));
    }
    if (key >= 302 && key <= 313) { /* F13..F24 */
        return (SDL_Scancode)(SDL_SCANCODE_F13 + (key - 302));
    }
    if (key >= 321 && key <= 329) { /* KP_1..KP_9 */
        return (SDL_Scancode)(SDL_SCANCODE_KP_1 + (key - 321));
    }
    switch (key) {
    case 32:  return SDL_SCANCODE_SPACE;
    case 39:  return SDL_SCANCODE_APOSTROPHE;
    case 44:  return SDL_SCANCODE_COMMA;
    case 45:  return SDL_SCANCODE_MINUS;
    case 46:  return SDL_SCANCODE_PERIOD;
    case 47:  return SDL_SCANCODE_SLASH;
    case 48:  return SDL_SCANCODE_0;
    case 59:  return SDL_SCANCODE_SEMICOLON;
    case 61:  return SDL_SCANCODE_EQUALS;
    case 91:  return SDL_SCANCODE_LEFTBRACKET;
    case 92:  return SDL_SCANCODE_BACKSLASH;
    case 93:  return SDL_SCANCODE_RIGHTBRACKET;
    case 96:  return SDL_SCANCODE_GRAVE;
    case 256: return SDL_SCANCODE_ESCAPE;
    case 257: return SDL_SCANCODE_RETURN;
    case 258: return SDL_SCANCODE_TAB;
    case 259: return SDL_SCANCODE_BACKSPACE;
    case 260: return SDL_SCANCODE_INSERT;
    case 261: return SDL_SCANCODE_DELETE;
    case 262: return SDL_SCANCODE_RIGHT;
    case 263: return SDL_SCANCODE_LEFT;
    case 264: return SDL_SCANCODE_DOWN;
    case 265: return SDL_SCANCODE_UP;
    case 266: return SDL_SCANCODE_PAGEUP;
    case 267: return SDL_SCANCODE_PAGEDOWN;
    case 268: return SDL_SCANCODE_HOME;
    case 269: return SDL_SCANCODE_END;
    case 280: return SDL_SCANCODE_CAPSLOCK;
    case 281: return SDL_SCANCODE_SCROLLLOCK;
    case 282: return SDL_SCANCODE_NUMLOCKCLEAR;
    case 283: return SDL_SCANCODE_PRINTSCREEN;
    case 284: return SDL_SCANCODE_PAUSE;
    case 320: return SDL_SCANCODE_KP_0;
    case 330: return SDL_SCANCODE_KP_PERIOD;
    case 331: return SDL_SCANCODE_KP_DIVIDE;
    case 332: return SDL_SCANCODE_KP_MULTIPLY;
    case 333: return SDL_SCANCODE_KP_MINUS;
    case 334: return SDL_SCANCODE_KP_PLUS;
    case 335: return SDL_SCANCODE_KP_ENTER;
    case 336: return SDL_SCANCODE_KP_EQUALS;
    case 340: return SDL_SCANCODE_LSHIFT;
    case 341: return SDL_SCANCODE_LCTRL;
    case 342: return SDL_SCANCODE_LALT;
    case 343: return SDL_SCANCODE_LGUI;
    case 344: return SDL_SCANCODE_RSHIFT;
    case 345: return SDL_SCANCODE_RCTRL;
    case 346: return SDL_SCANCODE_RALT;
    case 347: return SDL_SCANCODE_RGUI;
    case 348: return SDL_SCANCODE_APPLICATION;
    default:  return SDL_SCANCODE_UNKNOWN;
    }
}

/* GLFW button (0=left,1=right,2=middle) -> SDL button (1=left,2=middle,3=right). */
static Uint8 OHOS_GlfwToSdlButton(int button)
{
    switch (button) {
    case 0:  return SDL_BUTTON_LEFT;
    case 1:  return SDL_BUTTON_RIGHT;
    case 2:  return SDL_BUTTON_MIDDLE;
    case 3:  return SDL_BUTTON_X1;
    case 4:  return SDL_BUTTON_X2;
    default: return 0;
    }
}

static SDL_Window *OHOS_EventWindow(void)
{
    SDL_Window *w = SDL_GetKeyboardFocus();
    if (!w) {
        w = SDL_GetMouseFocus();
    }
    return w;
}

/* Emit one committed character as SDL_EVENT_TEXT_INPUT. */
static void OHOS_SendChar(Uint64 ts, Uint32 cp)
{
    char buf[8];
    char *end;

    (void)ts;
    if (cp == 0) {
        return;
    }
    /* SDL_UCS4ToUTF8 writes the bytes and returns a pointer PAST them; it does
     * NOT append a NUL. Without this terminator SDL_SendKeyboardText() would
     * read uninitialised stack bytes (visible as U+FFFD + stray '[' / ']'). */
    end = SDL_UCS4ToUTF8(cp, buf);
    if (end) {
        *end = '\0';
    } else {
        buf[0] = '\0';
    }
    SDL_SendKeyboardText(buf);
}

void OHOS_PumpEvents(SDL_VideoDevice *_this)
{
    struct meow_environ_s *env;
    uintptr_t base;
    SDL_Window *win;
    Uint64 ts;
    size_t queued, index, target, n;
    static int relActive = 0;
    static double relLastX = 0.0, relLastY = 0.0;
    static int lastCharModsCp = -1;
    int grabbing;

    base = OHOS_GetBridgeBase();
    if (!base) {
        return;
    }
    env = (struct meow_environ_s *)base;
    win = OHOS_EventWindow();
    ts = SDL_GetTicksNS();

    /* Follow the ArkTS/XComponent surface size (resize support). */
    OHOS_SyncSurfaceSize(_this);

    /* Window focus. Minecraft 26.3 pauses itself (after 500 ms) when its window reports
     * lost focus, and it only learns that from SDL_EVENT_WINDOW_FOCUS_LOST/GAINED
     * (Window.handleEvent cases 526/527 -> Minecraft.pauseIfInactive). ArkTS publishes the
     * windowStageEvent ACTIVE/INACTIVE state into env->windowUnfocused, and calling
     * SDL_SetKeyboardFocus() is all we need: SDL core emits the matching window event
     * itself (src/events/SDL_keyboard.c).
     *
     * The zero value means focused, so an older HSP that never writes the field leaves the
     * game exactly as it behaved before this feature.
     *
     * On loss we remember which window had focus: the driver owns several SDL windows over
     * the one native surface (MC opens a probe, the real one and a throwaway), so restoring
     * blindly from the window list could hand SDL's keyboard focus to the wrong one.
     * SDL_ResetKeyboard() drops keys held while the user switched away. */
    {
        static int lastUnfocused = 0;
        static SDL_Window *lastFocusWindow = NULL;
        int unfocused = env->windowUnfocused ? 1 : 0;

        if (unfocused != lastUnfocused) {
            lastUnfocused = unfocused;
            if (unfocused) {
                lastFocusWindow = SDL_GetKeyboardFocus();
                SDL_ResetKeyboard();
                SDL_SetKeyboardFocus(NULL);
            } else {
                SDL_Window *focus = lastFocusWindow ? lastFocusWindow : (win ? win : _this->windows);
                if (focus) {
                    SDL_SetKeyboardFocus(focus);
                }
            }
        }
    }

    grabbing = env->grabbing ? 1 : 0;

    if (grabbing) {
        /* Mouse-look: MC reads SDL_MouseMotionEvent.xrel/yrel. The bridge keeps
         * a virtual cursor (env->cursorX/Y, fed by NDK raw deltas); difference
         * consecutive samples and deliver them as relative motion. */
        if (!relActive) {
            relActive = 1;
            relLastX = env->cursorX;
            relLastY = env->cursorY;
        } else {
            double dx = env->cursorX - relLastX;
            double dy = env->cursorY - relLastY;
            relLastX = env->cursorX;
            relLastY = env->cursorY;
            if (win && (dx != 0.0 || dy != 0.0)) {
                SDL_SendMouseMotion(ts, win, 0, true, (float)dx, (float)dy);
            }
        }
    } else {
        relActive = 0;
        /* Pointer motion is a latest-value slot, not a ring entry. */
        if (env->cursorX != env->cLastX || env->cursorY != env->cLastY) {
            env->cLastX = env->cursorX;
            env->cLastY = env->cursorY;
            if (win) {
                SDL_SendMouseMotion(ts, win, 0, false, (float)env->cursorX, (float)env->cursorY);
            }
        }
    }

    queued = atomic_load_explicit(&env->eventCounter, memory_order_acquire);
    index = env->outEventIndex;
    target = (index + queued) % MEOW_RING_CAPACITY;

    for (n = 0; n < queued; n++) {
        MeowInputEvent ev = env->events[index];

        switch (ev.type) {
        case MEOW_EV_KEY: {
            SDL_Scancode sc = OHOS_GlfwToScancode(ev.i1);
            if (sc != SDL_SCANCODE_UNKNOWN) {
                /* action: 0 = release, 1 = press, 2 = repeat (GLFW numbering). */
                SDL_SendKeyboardKey(ts, 0, 0, sc, ev.i3 != 0);
            }
            break;
        }
        case MEOW_EV_CHAR_MODS:
            /* The bridge emits a committed character as BOTH CHAR_MODS and CHAR
             * (the GLFW pump consumes whichever callback the game registered).
             * On the SDL path they would become two TEXT_INPUT, so collapse the
             * pair: remember this codepoint and drop the following identical CHAR. */
            lastCharModsCp = ev.i1;
            OHOS_SendChar(ts, (Uint32)ev.i1);
            break;
        case MEOW_EV_CHAR:
            if (ev.i1 == lastCharModsCp) {
                lastCharModsCp = -1;
                break;
            }
            OHOS_SendChar(ts, (Uint32)ev.i1);
            break;
        case MEOW_EV_MOUSE_BUTTON: {
            Uint8 b = OHOS_GlfwToSdlButton(ev.i1);
            if (win && b) {
                SDL_SendMouseButton(ts, win, 0, b, ev.i2 != 0);
            }
            break;
        }
        case MEOW_EV_SCROLL: {
            if (win) {
                SDL_SendMouseWheel(ts, win, 0, (float)ev.i1, (float)ev.i2, SDL_MOUSEWHEEL_NORMAL);
            }
            break;
        }
        default:
            break;
        }

        index = (index + 1) % MEOW_RING_CAPACITY;
    }

    env->outEventIndex = target;
    atomic_fetch_sub_explicit(&env->eventCounter, queued, memory_order_acquire);
}

int OHOS_WaitEventTimeout(SDL_VideoDevice *_this, Sint64 timeoutNS)
{
    /* We have no blocking event source: drain the ring here, then sleep briefly
     * so the caller's wait/poll loop re-pumps instead of spinning. Returns 0
     * ("no event yet"); SDL core re-pumps on the next iteration. */
    OHOS_PumpEvents(_this);
    if (timeoutNS < 0) {
        SDL_DelayNS(SDL_MS_TO_NS(1));
    } else if (timeoutNS > 0) {
        SDL_DelayNS(timeoutNS);
    }
    return 0;
}

#endif // SDL_VIDEO_DRIVER_OHOS
