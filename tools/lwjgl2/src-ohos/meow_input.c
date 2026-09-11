/*
 * Meowcraft OHOS LWJGL2 port — LinuxEvent / LinuxKeyboard / LinuxMouse natives.
 *
 * Replaces src/native/linux/{org_lwjgl_opengl_LinuxEvent.c, org_lwjgl_opengl_LinuxKeyboard.c,
 * org_lwjgl_opengl_LinuxMouse.c} (Xlib events, XKB, XIM, XQueryPointer).
 *
 * Java treats the event buffer as opaque and only reaches it through our accessors, so the
 * layout is our own MeowPortEvent (see meow_port.h) — there is no need to reproduce the
 * Xlib XEvent ABI.
 *
 * Input source: the Meowcraft shared state block (meowcraftbridge_environ.h). Key/button/
 * scroll/char events are pushed by the ArkTS layer into the SPSC ring (MEOW_EV_*), pointer
 * motion lands in the latest-value slots cursorX/cursorY. liblwjgl.so is the *only* ring
 * consumer on this path: the bridge's GLFW pump (meowStartPumping) is never started, so we
 * must never call it either.
 */
#include "meow_port.h"
#include <time.h>

static int    g_focus_sent  = 0;
static int    g_button_mask = 0;
static int    g_last_w      = 0;   /* last surface size we reported as ConfigureNotify */
static int    g_last_h      = 0;

/*
 * Ask the next nNextEvent to emit a fresh FocusIn.
 *
 * LWJGL2's LinuxDisplay.createWindow() resets `focused = false` (LinuxDisplay.java:506-507) and
 * Display.isActive() is `focused || isLegacyFullscreen()` (:816-817). On real X11 the window
 * manager delivers FocusIn right after (re)creating the window, which is what restores it —
 * checkInput() cannot help, it returns immediately when parent == null (:1017). Because the
 * fullscreen toggle destroys+recreates the window, a port that only synthesizes FocusIn once at
 * startup leaves `focused == false` forever after a fullscreen round-trip, so MC auto-pauses on
 * entering a world AND its "Back to Game" button is immediately overridden again (dead end). */
void meow_port_request_focus(void) {
	g_focus_sent = 0;
}

static inline jlong meow_now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (jlong)ts.tv_sec * 1000 + (jlong)(ts.tv_nsec / 1000000);
}

static inline int meow_win_w(const struct meow_environ_s *st) { return (st && st->width  > 0) ? st->width  : 1280; }
static inline int meow_win_h(const struct meow_environ_s *st) { return (st && st->height > 0) ? st->height : 720;  }

/* GLFW mouse button -> X11 button number. */
static inline int meow_x_button(int glfw_button) {
	switch (glfw_button) {
	case 0: return 1;    /* left    */
	case 1: return 3;    /* right   */
	case 2: return 2;    /* middle  */
	case 3: return 8;
	case 4: return 9;
	default: return glfw_button + 1;
	}
}

static inline int meow_button_mask_of(int x_button) {
	switch (x_button) {
	case 1: return 1 << 8;    /* Button1Mask */
	case 2: return 1 << 9;    /* Button2Mask */
	case 3: return 1 << 10;   /* Button3Mask */
	case 8: return 1 << 11;
	case 9: return 1 << 12;
	default: return 0;
	}
}

/* =================================================================== LinuxEvent */

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxEvent_createEventBuffer(JNIEnv *env, jclass c) {
	(void)c;
	return meow_new_buffer(env, sizeof(MeowPortEvent));
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxEvent_getPending(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	struct meow_environ_s *st = meow_state();
	int n = 0;
	if (st != NULL) {
		n += (int)atomic_load_explicit(&st->eventCounter, memory_order_acquire);
		if (st->cursorX != st->cLastX || st->cursorY != st->cLastY)
			n += 1;                                  /* pending MotionNotify */
		if (st->width != g_last_w || st->height != g_last_h)
			n += 1;   /* pending ConfigureNotify. The very first reading only latches g_last_*
			           * (emits nothing) and a CHAR/CHAR_MODS pair is counted twice but emitted
			           * once, so getPending can transiently over-count by 1. Harmless: the
			           * consumer re-polls getPending() every iteration (processEvents loop). */
	}
	if (!g_focus_sent)
		n += 1;                                      /* one-shot FocusIn */
	return n;
}

/* Fill one MotionNotify from the latest pointer slot and consume it.
 *
 * COORDINATES: LWJGL2 flips Y itself — LinuxMouse.transformY() is
 * `nGetWindowHeight(display, window) - 1 - y` (LinuxMouse.java:195) and is applied to
 * every value that came out of nQueryPointer / nGetButtonY. So these natives must report
 * the RAW top-left-origin (X11-style) coordinates, exactly like XQueryPointer does; a flip
 * here would cancel LWJGL2's and make the pointer appear vertically mirrored. */
static int meow_fill_motion(struct meow_environ_s *st, MeowPortEvent *ev) {
	if (st == NULL || (st->cursorX == st->cLastX && st->cursorY == st->cLastY))
		return 0;
	ev->type   = MEOW_X_MotionNotify;
	ev->time   = meow_now_ms();
	ev->state  = g_button_mask;
	ev->x_root = (int)lround(st->cursorX);
	ev->y_root = (int)lround(st->cursorY);
	ev->x      = ev->x_root;
	ev->y      = ev->y_root;
	st->cLastX = st->cursorX;
	st->cLastY = st->cursorY;
	return 1;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxEvent_nNextEvent(JNIEnv *env, jclass c, jlong display, jobject event_buffer) {
	(void)c; (void)display;
	struct meow_environ_s *st = meow_state();
	MeowPortEvent *ev = (MeowPortEvent *)meow_direct(env, event_buffer, sizeof(MeowPortEvent));
	MeowInputEvent in;
	size_t idx;

	if (ev == NULL)
		return;
	memset(ev, 0, sizeof(MeowPortEvent));
	ev->window = (jlong)(uintptr_t)(st != NULL ? st->window : NULL);

	/* 1) the one-shot FocusIn: without it Display.isActive() stays false and MC would
	 *    sit in its "paused / unfocused" menu. */
	if (!g_focus_sent) {
		g_focus_sent     = 1;
		ev->type         = MEOW_X_FocusIn;
		ev->time         = meow_now_ms();
		ev->focus_mode   = 0;                       /* NotifyNormal  */
		ev->focus_detail = 3;                       /* NotifyNonlinear */
		return;
	}
	/* 1b) window/surface size changed -> ConfigureNotify, which is how LWJGL2 learns about a
	 *     resize: LinuxDisplay.processEvents' ConfigureNotify case re-reads nGetX/nGetY/
	 *     nGetWidth/nGetHeight (ours) and sets `resized`, so Display.wasResized() /
	 *     getWidth()/getHeight() follow the real OHNativeWindow size. The bridge already
	 *     mirrors the surface size into the shared block. */
	if (st != NULL && (st->width != g_last_w || st->height != g_last_h)) {
		int first_size = (g_last_w == 0 && g_last_h == 0);
		g_last_w = st->width;
		g_last_h = st->height;
		if (!first_size) {
			ev->type = MEOW_X_ConfigureNotify;
			ev->time = meow_now_ms();
			return;
		}
	}
	/* 2) pending pointer motion */
	if (meow_fill_motion(st, ev))
		return;

	/* 3) the SPSC ring */
	if (st == NULL || atomic_load_explicit(&st->eventCounter, memory_order_acquire) == 0)
		return;                                     /* leave a harmless type-0 event */

	idx = st->outEventIndex;
	in = st->events[idx];
	st->outEventIndex = (idx + 1) % MEOW_RING_CAPACITY;
	atomic_fetch_sub_explicit(&st->eventCounter, 1, memory_order_release);

	ev->time = meow_now_ms();

	switch (in.type) {
	case MEOW_EV_KEY: {
		int action = in.i3;
		ev->type    = (action == 0) ? MEOW_X_KeyRelease : MEOW_X_KeyPress;
		ev->keycode = in.i1;                        /* opaque: fed back to lookupKeysym */
		ev->keysym  = meow_glfw_keysym(in.i1);
		ev->state   = in.i4;
		ev->x = ev->y = 0;
		break;
	}
	case MEOW_EV_CHAR:
	case MEOW_EV_CHAR_MODS: {
		/* A KeyPress carrying only the typed codepoint: keysym 0 so LinuxKeyboard's
		 * key mapping yields KEY_NONE while lookupString/utf8LookupString still
		 * produce the character.
		 *
		 * NOTE: meowjrebridge's MeowSendChar pushes BOTH kinds for one character
		 * ("order matters: LWJGL char callback needs the mods variant first") — correct
		 * for the GLFW/SDL Java-callback path, but on the ring path both items reach us
		 * and LWJGL2 would type the character twice. Consume the sibling event of the
		 * other kind when it carries the same codepoint. Two separate keystrokes of the
		 * same character are always separated by KEY press/release items, so this cannot
		 * swallow a real repeat. */
		unsigned int cp = (unsigned int)in.i1;
		if (st != NULL && atomic_load_explicit(&st->eventCounter, memory_order_acquire) > 0) {
			size_t peer = st->outEventIndex;                 /* already advanced past `in` */
			MeowInputEvent sibling = st->events[peer];
			if ((sibling.type == MEOW_EV_CHAR || sibling.type == MEOW_EV_CHAR_MODS) &&
				sibling.type != in.type && (unsigned int)sibling.i1 == cp) {
				st->outEventIndex = (peer + 1) % MEOW_RING_CAPACITY;
				atomic_fetch_sub_explicit(&st->eventCounter, 1, memory_order_release);
			}
		}
		ev->type      = MEOW_X_KeyPress;
		ev->keycode   = 0;
		ev->keysym    = 0;
		ev->codepoint = cp;
		ev->has_char  = 1;
		ev->state     = in.i4;
		break;
	}
	case MEOW_EV_MOUSE_BUTTON: {
		int xb = meow_x_button(in.i1);
		if (in.i2 == 0)
			g_button_mask &= ~meow_button_mask_of(xb);
		else
			g_button_mask |= meow_button_mask_of(xb);
		ev->type   = (in.i2 == 0) ? MEOW_X_ButtonRelease : MEOW_X_ButtonPress;
		ev->button = xb;
		ev->state  = g_button_mask | (in.i4 & 0xff);
		ev->x_root = (int)lround(st->cursorX);
		ev->y_root = (int)lround(st->cursorY);      /* raw top-left; LinuxMouse flips */
		ev->x      = ev->x_root;
		ev->y      = ev->y_root;
		break;
	}
	case MEOW_EV_SCROLL: {
		/* Vertical wheel only: LWJGL2 turns X buttons 4/5 into a +/-120 wheel delta. */
		if (in.i2 == 0)
			break;
		ev->type   = MEOW_X_ButtonPress;
		ev->button = (in.i2 > 0) ? 4 : 5;
		ev->state  = g_button_mask;
		ev->x_root = (int)lround(st->cursorX);
		ev->y_root = (int)lround(st->cursorY);      /* raw top-left; LinuxMouse flips */
		ev->x      = ev->x_root;
		ev->y      = ev->y_root;
		break;
	}
	default:
		/* Cursor-enter and anything unknown: keep the event inert (type 0). */
		break;
	}
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxEvent_nSendEvent(JNIEnv *env, jclass c, jobject event_buffer, jlong display, jlong window, jboolean propagate, jlong event_mask) {
	(void)env; (void)c; (void)event_buffer; (void)display; (void)window; (void)propagate; (void)event_mask;
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxEvent_nFilterEvent(JNIEnv *env, jclass c, jobject event_buffer, jlong window) {
	(void)env; (void)c; (void)event_buffer; (void)window;
	return JNI_FALSE;    /* let LinuxKeyboard/LinuxMouse handle every event */
}

JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetType(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->type : 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetWindow(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->window : 0; }
JNIEXPORT void  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nSetWindow(JNIEnv *env, jclass c, jobject b, jlong w) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); if (e) e->window = w; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetFocusMode(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->focus_mode : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetFocusDetail(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->focus_detail : 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetClientMessageType(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->client_type : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetClientData(JNIEnv *env, jclass c, jobject b, jint i) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return (e && i >= 0 && i < 5) ? e->client_data[i] : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetClientFormat(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->client_format : 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonTime(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->time : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonState(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->state : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonType(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->type : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonButton(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->button : 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonRoot(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->root : 1; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonXRoot(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->x_root : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonYRoot(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->y_root : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonX(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->x : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetButtonY(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->y : 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetKeyAddress(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return (jlong)(intptr_t)e; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetKeyTime(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? (jint)e->time : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetKeyType(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->type : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetKeyKeyCode(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->keycode : 0; }
JNIEXPORT jint  JNICALL Java_org_lwjgl_opengl_LinuxEvent_nGetKeyState(JNIEnv *env, jclass c, jobject b) { (void)c; MeowPortEvent *e = (MeowPortEvent *)meow_direct(env, b, sizeof(MeowPortEvent)); return e ? e->state : 0; }

/* =================================================================== LinuxKeyboard */

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_getModifierMapping(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 0;    /* no modifier map: LinuxKeyboard then leaves every mask at 0 */
}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_freeModifierMapping(JNIEnv *env, jclass c, jlong map) { (void)env; (void)c; (void)map; }
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_getMaxKeyPerMod(JNIEnv *env, jclass c, jlong map) { (void)env; (void)c; (void)map; return 0; }
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_lookupModifierMap(JNIEnv *env, jclass c, jlong map, jint index) { (void)env; (void)c; (void)map; (void)index; return 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_keycodeToKeySym(JNIEnv *env, jclass c, jlong display, jint keycode) { (void)env; (void)c; (void)display; (void)keycode; return 0; }

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_nSetDetectableKeyRepeat(JNIEnv *env, jclass c, jlong display, jboolean enabled) {
	(void)env; (void)c; (void)display; (void)enabled;
	return JNI_TRUE;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_openIM(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 0x494d0001L;      /* non-zero: enables the UTF-8 lookupString path */
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_createIC(JNIEnv *env, jclass c, jlong display, jlong xim) {
	(void)env; (void)c; (void)display;
	return (xim != 0) ? 0x49430001L : 0;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_setupIMEventMask(JNIEnv *env, jclass c, jlong display, jlong window, jlong xic) { (void)env; (void)c; (void)display; (void)window; (void)xic; }

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_allocateComposeStatus(JNIEnv *env, jclass c) {
	(void)c;
	return meow_new_buffer(env, 64);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_destroyIC(JNIEnv *env, jclass c, jlong xic) { (void)env; (void)c; (void)xic; }
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_closeIM(JNIEnv *env, jclass c, jlong xim) { (void)env; (void)c; (void)xim; }

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_lookupKeysym(JNIEnv *env, jclass c, jlong event_address, jint index) {
	(void)env; (void)c;
	MeowPortEvent *e = (MeowPortEvent *)(intptr_t)event_address;
	if (e == NULL || index > 1)
		return 0;            /* NoSymbol */
	return e->keysym;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_toUpper(JNIEnv *env, jclass c, jlong keysym) {
	(void)env; (void)c;
	if (keysym >= 'a' && keysym <= 'z')
		return keysym - 32;
	return keysym;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_lookupString(JNIEnv *env, jclass c, jlong event_address, jobject buffer, jobject status) {
	(void)c; (void)status;
	MeowPortEvent *e = (MeowPortEvent *)(intptr_t)event_address;
	unsigned char *out = (unsigned char *)meow_direct(env, buffer, 1);
	if (e == NULL || !e->has_char || out == NULL)
		return 0;
	out[0] = (unsigned char)(e->codepoint & 0xff);   /* Latin-1 fallback */
	positionBuffer(env, buffer, 1);
	return 1;
}

/* NOTE on the parameter order — it is (xic, event_ptr, buffer, pos, size), matching
 * upstream LinuxKeyboard.c and the Java declaration
 *   `private static native int utf8LookupString(long xic, long event_ptr, ByteBuffer buffer, int pos, int size);`
 * Getting this wrong makes us dereference the opaque XIC token as an event pointer, which
 * faulted at (token + 0x4c) inside this very function on every key press. */
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxKeyboard_utf8LookupString(JNIEnv *env, jclass c, jlong xic_ptr, jlong event_ptr, jobject buffer, jint buffer_position, jint buffer_length) {
	(void)c;
	(void)xic_ptr;                              /* we have no real XIC; the token is opaque */
	MeowPortEvent *e = (MeowPortEvent *)(intptr_t)event_ptr;
	unsigned char *base;
	unsigned int cp;
	int len = 0;
	unsigned char tmp[4];

	if (e == NULL || !e->has_char)
		return 0;
	base = (unsigned char *)meow_direct(env, buffer, (size_t)(buffer_position + 4));
	if (base == NULL)
		return 0;

	cp = e->codepoint;
	if (cp < 0x80) {
		tmp[len++] = (unsigned char)cp;
	} else if (cp < 0x800) {
		tmp[len++] = (unsigned char)(0xc0 | (cp >> 6));
		tmp[len++] = (unsigned char)(0x80 | (cp & 0x3f));
	} else if (cp < 0x10000) {
		tmp[len++] = (unsigned char)(0xe0 | (cp >> 12));
		tmp[len++] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
		tmp[len++] = (unsigned char)(0x80 | (cp & 0x3f));
	} else {
		tmp[len++] = (unsigned char)(0xf0 | (cp >> 18));
		tmp[len++] = (unsigned char)(0x80 | ((cp >> 12) & 0x3f));
		tmp[len++] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
		tmp[len++] = (unsigned char)(0x80 | (cp & 0x3f));
	}
	if (buffer_length > 0 && len > buffer_length)
		len = buffer_length;
	for (int i = 0; i < len; i++)
		base[buffer_position + i] = tmp[i];
	/* Java does buffer.flip() right after: bytes must end at pos+len (see LinuxKeyboard.lookupStringUnicode). */
	positionBuffer(env, buffer, buffer_position + len);
	return 2;                /* XLookupChars */
}

/* =================================================================== LinuxMouse */

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxMouse_nGetButtonCount(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 9;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxMouse_nGetWindowHeight(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return meow_win_h(meow_state());
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxMouse_nGetWindowWidth(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return meow_win_w(meow_state());
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxMouse_nQueryPointer(JNIEnv *env, jclass c, jlong display, jlong window, jobject result_buffer) {
	(void)c; (void)display; (void)window;
	struct meow_environ_s *st = meow_state();
	jint *out = (jint *)meow_direct(env, result_buffer, sizeof(jint) * 4);
	/* RAW top-left-origin coordinates — see meow_fill_motion(). LinuxMouse.reset() applies
	 * transformY() to win_y itself, so a flip here would cancel it out and mirror the pointer. */
	int wx = st != NULL ? (int)lround(st->cursorX) : 0;
	int wy = st != NULL ? (int)lround(st->cursorY) : 0;

	if (out != NULL) {
		out[0] = wx;          /* root_x */
		out[1] = wy;          /* root_y */
		out[2] = wx;          /* win_x  */
		out[3] = wy;          /* win_y  */
	}
	return 1;                 /* root window cookie */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxMouse_nWarpCursor(JNIEnv *env, jclass c, jlong display, jlong window, jint x, jint y) {
	(void)env; (void)c; (void)display; (void)window; (void)x; (void)y;
	/* Absolute pointer position is owned by the ArkTS layer. */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxMouse_nSendWarpEvent(JNIEnv *env, jclass c, jlong display, jlong window, jlong warp_atom, jint center_x, jint center_y) {
	(void)env; (void)c; (void)display; (void)window; (void)warp_atom; (void)center_x; (void)center_y;
}
