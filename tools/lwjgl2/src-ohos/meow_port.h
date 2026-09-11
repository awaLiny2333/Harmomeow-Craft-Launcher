/*
 * Meowcraft OHOS LWJGL2 port — private shared header for the Stage-2 layer
 * (src-ohos/meow_display.c, meow_context.c, meow_input.c, meow_cursor.c).
 *
 * The port has to satisfy the *unchanged* LWJGL2 Java contract (MC's lwjgl-2.9.x.jar
 * declares Java_org_lwjgl_opengl_Linux* natives), but there is no X11/GLX/AWT on OHOS.
 * Instead we
 *   - adopt the process-wide Meowcraft state block (published as a hex pointer in
 *     MEOWCRAFT_ENVIRON) for the native window handle, the window size mirror and the
 *     input ring — the same block the LWJGL3/GLFW path uses;
 *   - call the already-loaded libmeowcraftbridge.so entry points (meowMakeCurrent,
 *     meowSwapBuffers, ...) through dlsym(RTLD_DEFAULT, ...): the bridge is loaded
 *     RTLD_GLOBAL before the JVM starts, and we deliberately keep no DT_NEEDED on it;
 *   - define our own opaque "X event" struct for the direct ByteBuffer that
 *     LinuxEvent.createEventBuffer() hands around, plus the accessors that read it.
 */
#ifndef MEOW_LWJGL2_PORT_H
#define MEOW_LWJGL2_PORT_H

#include <jni.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <math.h>

#include "common_tools.h"                /* throwException/printfDebug/newJavaManagedByteBuffer */
#include "meowcraftbridge_environ.h"     /* struct meow_environ_s, MEOW_EV_*, ring geometry */

/* ------------------------------------------------------------------ state block */

/* Resolve the shared block once per translation unit. NULL when the process was not
 * started by our launcher (then every native degrades to a safe no-op). */
static inline struct meow_environ_s *meow_state(void) {
	static struct meow_environ_s *cached = NULL;
	static int tried = 0;
	if (!tried) {
		const char *published = getenv("MEOWCRAFT_ENVIRON");
		tried = 1;
		if (published != NULL && *published != '\0')
			cached = (struct meow_environ_s *)(uintptr_t)strtoull(published, NULL, 16);
	}
	return cached;
}

/* ------------------------------------------------------------------ bridge thunks */

typedef struct {
	int resolved;
	void  (*makeCurrent)(void *window);
	void  (*swapBuffers)(void);
	void  (*swapInterval)(int interval);
	void *(*getCurrentContext)(void);
	/* want=1 -> env->fsRequest=1 (enter), want=0 -> 2 (exit); x/y/w/h = windowed restore rect. */
	void  (*setFullscreenRequest)(int want, int x, int y, int w, int h);
} MeowBridge;

static inline MeowBridge *meow_bridge(void) {
	static MeowBridge b;
	static int tried = 0;
	if (!tried) {
		tried = 1;
		b.makeCurrent        = (void  (*)(void *))    dlsym(RTLD_DEFAULT, "meowMakeCurrent");
		b.swapBuffers        = (void  (*)(void))      dlsym(RTLD_DEFAULT, "meowSwapBuffers");
		b.swapInterval       = (void  (*)(int))       dlsym(RTLD_DEFAULT, "meowSwapInterval");
		b.getCurrentContext  = (void *(*)(void))      dlsym(RTLD_DEFAULT, "meowGetCurrentContext");
		b.setFullscreenRequest = (void (*)(int, int, int, int, int)) dlsym(RTLD_DEFAULT, "meowSetFullscreenRequest");
		b.resolved = (b.makeCurrent != NULL && b.swapBuffers != NULL);
		if (!b.resolved)
			printfDebug("LWJGL2 port: libmeowcraftbridge entry points not found (EGL/swap unavailable)\n");
	}
	return &b;
}

/* ------------------------------------------------------------------ buffers */

static inline void *meow_direct(JNIEnv *env, jobject buffer, size_t need) {
	void *p;
	/*
	 * NOTE: do NOT range-check the capacity here. JNI's GetDirectBufferCapacity reports the
	 * capacity in ELEMENTS of the buffer's type, not bytes — an IntBuffer of 4 ints reports 4,
	 * not 16 — so a byte comparison false-positives (this once made LinuxMouse.nQueryPointer
	 * throw "undersized direct buffer", which killed Mouse.create() and crashed MC). The
	 * upstream Linux natives never check either. `need` is kept for documentation only.
	 */
	(void)need;
	if (buffer == NULL)
		return NULL;
	p = (*env)->GetDirectBufferAddress(env, buffer);
	if (p == NULL)
		printfDebug("LWJGL2 port: buffer is not direct\n");
	return p;
}

static inline jobject meow_new_buffer(JNIEnv *env, size_t size) {
	return newJavaManagedByteBuffer(env, (const int)size);
}

/* ------------------------------------------------------------------ opaque "X event" */

/* LinuxEvent/Keyboard/Mouse only ever touch the event buffer through our accessors,
 * so the layout is entirely ours (no Xlib ABI to reproduce). */
typedef struct {
	int      type;              /* one of MEOW_X_* below (X11 numbering) */
	int      window_ok;
	jlong    window;            /* xany.window */
	/* key/mouse common */
	jlong    time;              /* milliseconds */
	int      state;             /* modifier / button mask */
	int      button;
	jlong    root;
	int      x_root, y_root;
	int      x, y;
	/* key */
	int      keycode;
	jlong    keysym;
	unsigned int codepoint;     /* typing char for lookupString/utf8LookupString */
	int      has_char;
	/* focus */
	int      focus_mode;
	int      focus_detail;
	/* client message (window close) */
	jlong    client_type;
	int      client_format;
	int      client_data[5];
} MeowPortEvent;

/* Implemented in meow_input.c: make the next nNextEvent emit a fresh FocusIn. */
extern void meow_port_request_focus(void);

typedef struct {                 /* LinuxPeerInfo native buffer */
	jlong display;
	int   screen;
	jlong drawable;
} MeowPeerInfo;

typedef struct {                 /* LinuxContextImplementation native buffer */
	int magic;
} MeowContext;

/* X11 event type numbers used by LinuxEvent/LinuxMouse/LinuxKeyboard */
enum {
	MEOW_X_KeyPress      = 2,
	MEOW_X_KeyRelease    = 3,
	MEOW_X_ButtonPress   = 4,
	MEOW_X_ButtonRelease = 5,
	MEOW_X_MotionNotify  = 6,
	MEOW_X_FocusIn       = 9,
	MEOW_X_ConfigureNotify = 22,
	MEOW_X_ClientMessage = 33
};

/* GLFW key code -> X11 KeySym (LinuxKeyboard.mapKeySymToLWJGLKeyCode must see X11). */
static inline jlong meow_glfw_keysym(int key) {
	/*
	 * Printable ASCII maps STRAIGHT THROUGH: the X11 KeySyms for 0x20..0x7E *are* the ASCII
	 * values (XK_space = 0x20, XK_exclam = 0x21, … XK_asciitilde = 0x7E), and LWJGL2's
	 * LinuxKeycodes.mapKeySymToLWJGLKeyCode() maps them to Keyboard.KEY_*. Returning 0
	 * (NoSymbol) for a key makes that mapping yield KEY_NONE, so the key never reaches the
	 * game — that is exactly why Space (jump) and the punctuation keys did nothing.
	 */
	if (key >= 32 && key <= 126)
		return key;
	switch (key) {
	case 256: return 0xff1b;                    /* Escape      */
	case 257: return 0xff0d;                    /* Return      */
	case 258: return 0xff09;                    /* Tab         */
	case 259: return 0xff08;                    /* BackSpace   */
	case 260: return 0xff63;                    /* Insert      */
	case 261: return 0xffff;                    /* Delete      */
	case 262: return 0xff53;                    /* Right       */
	case 263: return 0xff51;                    /* Left        */
	case 264: return 0xff54;                    /* Down        */
	case 265: return 0xff52;                    /* Up          */
	case 266: return 0xff55;                    /* PageUp      */
	case 267: return 0xff56;                    /* PageDown    */
	case 268: return 0xff50;                    /* Home        */
	case 269: return 0xff57;                    /* End         */
	case 280: return 0xffe5;                    /* CapsLock    */
	case 281: return 0xff14;                    /* ScrollLock  */
	case 282: return 0xff7f;                    /* NumLock     */
	case 283: return 0xff61;                    /* Print (PrintScreen) */
	case 284: return 0xff13;                    /* Pause       */
	case 290: case 291: case 292: case 293: case 294: case 295:
	case 296: case 297: case 298: case 299: case 300: case 301:
		return 0xffbe + (key - 290);             /* F1..F12     */
	case 302: case 303: case 304: case 305: case 306: case 307:
	case 308: case 309: case 310: case 311: case 312: case 313:
		return 0xffca + (key - 302);             /* F13..F24    */
	case 161: case 162: return 0x20;             /* WORLD_1/2 -> space (no X11 equivalent) */
	case 320: case 321: case 322: case 323: case 324:
	case 325: case 326: case 327: case 328: case 329:
		return 0xffb0 + (key - 320);             /* KP_0..KP_9  */
	case 330: return 0xffae;                    /* KP_Decimal  */
	case 331: return 0xffaf;                    /* KP_Divide   */
	case 332: return 0xffaa;                    /* KP_Multiply */
	case 333: return 0xffad;                    /* KP_Subtract */
	case 334: return 0xffab;                    /* KP_Add      */
	case 335: return 0xff8d;                    /* KP_Enter    */
	case 336: return 0xffbd;                    /* KP_Equal    */
	case 340: return 0xffe1;                    /* Shift_L     */
	case 341: return 0xffe3;                    /* Control_L   */
	case 342: return 0xffe9;                    /* Alt_L       */
	case 343: return 0xffe7;                    /* Meta_L      */
	case 344: return 0xffe2;                    /* Shift_R     */
	case 345: return 0xffe4;                    /* Control_R   */
	case 346: return 0xffea;                    /* Alt_R       */
	case 347: return 0xffe8;                    /* Meta_R      */
	case 348: return 0xff67;                    /* Menu        */
	default:  return 0;                         /* NoSymbol    */
	}
}

#endif /* MEOW_LWJGL2_PORT_H */
