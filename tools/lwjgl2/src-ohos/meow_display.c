/*
 * Meowcraft OHOS LWJGL2 port — LinuxDisplay / peer-info / canvas natives.
 *
 * Replaces src/native/linux/opengl/{org_lwjgl_opengl_Display.c, display.c, context.c,
 * GLX.c, org_lwjgl_opengl_LinuxCanvasImplementation.c} (Xlib/GLX/XRandR/jawt).
 * There is no X server: display modes/gamma/atoms/grabs are OHOS-appropriate no-ops or
 * constants, the window is the OHNativeWindow the launcher injected into the shared
 * block, and the window size mirror comes from that same block.
 *
 * The Java contract that MUST hold (LinuxDisplay.java):
 *   openDisplay()  -> non-zero, else incDisplay() throws
 *   nIsXF86VidModeSupported -> true, else Display.<clinit> throws "No display mode extension"
 *   nIsXrandrSupported      -> false (XRandR.java shells out to `xrandr`, absent here)
 *   nGetAvailableDisplayModes -> non-empty, else Display.init() throws
 *   nCreateWindow(...)        -> non-zero, else createWindow() fails
 *   nGetWidth/nGetHeight      -> the real surface size (Mouse.transformY depends on it)
 */
#include "meow_port.h"

#define MEOW_DISPLAY_COOKIE ((jlong)0x4d454f57L)   /* 'MEOW' */
#define MEOW_ROOT_COOKIE    ((jlong)0x1L)
#define MEOW_RAMP_LEN       256

/* ------------------------------------------------------------------ helpers */

static inline int meow_w(const struct meow_environ_s *st) { return (st && st->width  > 0) ? st->width  : 1280; }
static inline int meow_h(const struct meow_environ_s *st) { return (st && st->height > 0) ? st->height : 720;  }

/* Read an integer system property (the launcher passes -Dmeow.screen.w/h for legacy). */
static int meow_prop_int(JNIEnv *env, const char *key, int fallback) {
	jclass sys = (*env)->FindClass(env, "java/lang/System");
	jmethodID gp;
	jstring k, v;
	const char *cs;
	int out = fallback;

	if (sys == NULL) { (*env)->ExceptionClear(env); return fallback; }
	gp = (*env)->GetStaticMethodID(env, sys, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
	if (gp == NULL) { (*env)->ExceptionClear(env); return fallback; }
	k = (*env)->NewStringUTF(env, key);
	if (k == NULL) return fallback;
	v = (jstring)(*env)->CallStaticObjectMethod(env, sys, gp, k);
	if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return fallback; }
	if (v == NULL) return fallback;
	cs = (*env)->GetStringUTFChars(env, v, NULL);
	if (cs != NULL) { out = atoi(cs); (*env)->ReleaseStringUTFChars(env, v, cs); }
	return out > 0 ? out : fallback;
}

/* ------------------------------------------------------------------ atoms */

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nInternAtom(JNIEnv *env, jclass c, jlong display, jstring atom_name, jboolean only_if_exists) {
	(void)c; (void)display; (void)only_if_exists;
	if (atom_name == NULL)
		return 0;
	const char *name = (*env)->GetStringUTFChars(env, atom_name, NULL);
	uint32_t h = 2166136261u;                       /* FNV-1a; stable, non-zero */
	for (const char *p = name; p != NULL && *p != '\0'; p++) {
		h ^= (uint8_t)*p;
		h *= 16777619u;
	}
	(*env)->ReleaseStringUTFChars(env, atom_name, name);
	return (jlong)(h != 0 ? h : 1u);
}

/* ------------------------------------------------------------------ display lifecycle */

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_openDisplay(JNIEnv *env, jclass c) {
	(void)env; (void)c;
	return MEOW_DISPLAY_COOKIE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_closeDisplay(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetDefaultScreen(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 0;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nLockAWT(JNIEnv *env, jclass c) { (void)env; (void)c; }
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nUnlockAWT(JNIEnv *env, jclass c) { (void)env; (void)c; }

/* ------------------------------------------------------------------ error handling (never reached: no X errors) */

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_setErrorHandler(JNIEnv *env, jclass c) { (void)env; (void)c; return 0; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_resetErrorHandler(JNIEnv *env, jclass c, jlong handler) { (void)env; (void)c; (void)handler; return 0; }
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_callErrorHandler(JNIEnv *env, jclass c, jlong handler, jlong display, jlong error_ptr) {
	(void)env; (void)c; (void)handler; (void)display; (void)error_ptr;
	return 0;
}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_synchronize(JNIEnv *env, jclass c, jlong display, jboolean s) { (void)env; (void)c; (void)display; (void)s; }
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSync(JNIEnv *env, jclass c, jlong display, jboolean throw_away) { (void)env; (void)c; (void)display; (void)throw_away; }

JNIEXPORT jstring JNICALL Java_org_lwjgl_opengl_LinuxDisplay_getErrorText(JNIEnv *env, jclass c, jlong display, jlong error_code) {
	(void)c; (void)display; (void)error_code;
	return (*env)->NewStringUTF(env, "unknown");
}

/* ------------------------------------------------------------------ extensions / modes */

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nIsXrandrSupported(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return JNI_FALSE;    /* XRandR.java shells out to the `xrandr` binary */
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nIsXF86VidModeSupported(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return JNI_TRUE;     /* Display.<clinit> requires at least one mode extension */
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nIsNetWMFullscreenSupported(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)env; (void)c; (void)display; (void)screen;
	return JNI_FALSE;
}

JNIEXPORT jobjectArray JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetAvailableDisplayModes(JNIEnv *env, jclass c, jlong display, jint screen, jint extension) {
	(void)c; (void)display; (void)screen; (void)extension;
	struct meow_environ_s *st = meow_state();
	jclass dm = (*env)->FindClass(env, "org/lwjgl/opengl/DisplayMode");
	jmethodID ctor;
	jobjectArray arr;
	jobject mode;

	if (dm == NULL) {
		(*env)->ExceptionClear(env);   /* else the pending NoClassDefFoundError surfaces later */
		return NULL;
	}
	ctor = (*env)->GetMethodID(env, dm, "<init>", "(IIII)V");
	if (ctor == NULL) {
		(*env)->ExceptionClear(env);
		return NULL;
	}

	arr = (*env)->NewObjectArray(env, 1, dm, NULL);
	if (arr == NULL) {
		(*env)->ExceptionClear(env);
		return NULL;
	}
	if ((*env)->ExceptionCheck(env))
		return NULL;

	/* Report the SCREEN size as the (fullscreen-capable) mode — MC's fullscreen viewport comes
	 * from the mode it selects (LWJGL2 sets window_width = mode.width in createWindow and
	 * deliberately suppresses resize notifications while fullscreen: Display.java
	 * `window_resized = !isFullscreen() && ...`). Reporting the current window size instead made
	 * MC keep a 1280x664 viewport after maximizing, i.e. the image stayed in the bottom-left.
	 * The launcher passes -Dmeow.screen.w/h for the legacy generation. */
	mode = (*env)->NewObject(env, dm, ctor,
	                         (jint)meow_prop_int(env, "meow.screen.w", meow_w(st)),
	                         (jint)meow_prop_int(env, "meow.screen.h", meow_h(st)),
	                         (jint)24, (jint)60);
	if (mode == NULL)
		return NULL;
	if ((*env)->ExceptionCheck(env)) {        /* DisplayMode validates bpp/freq ranges */
		(*env)->ExceptionClear(env);
		return NULL;
	}
	(*env)->SetObjectArrayElement(env, arr, 0, mode);
	if ((*env)->ExceptionCheck(env))
		return NULL;
	return arr;
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetCurrentXRandrMode(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)env; (void)c; (void)display; (void)screen;
	return NULL;          /* unreachable: nIsXrandrSupported() is false */
}

/* ------------------------------------------------------------------ gamma */

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetGammaRampLength(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)env; (void)c; (void)display; (void)screen;
	return MEOW_RAMP_LEN;
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetCurrentGammaRamp(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)c; (void)display; (void)screen;
	jobject buf = meow_new_buffer(env, (size_t)MEOW_RAMP_LEN * 3u * sizeof(unsigned short));
	unsigned short *p;
	if (buf == NULL)
		return NULL;
	p = (unsigned short *)(*env)->GetDirectBufferAddress(env, buf);
	if (p != NULL) {
		for (int i = 0; i < MEOW_RAMP_LEN * 3; i++)
			p[i] = (unsigned short)i;         /* identity ramp, never applied */
	}
	return buf;
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nConvertToNativeRamp(JNIEnv *env, jclass c, jobject ramp_buffer, jint buffer_offset, jint length) {
	(void)c;
	const float *ramp = (const float *)(*env)->GetDirectBufferAddress(env, ramp_buffer);
	jobject native_ramp;
	unsigned short *out;

	if (ramp == NULL || length <= 0) {
		throwException(env, "LWJGL2 port: invalid gamma ramp buffer");
		return NULL;
	}
	native_ramp = meow_new_buffer(env, (size_t)length * 3u * sizeof(unsigned short));
	if (native_ramp == NULL) {
		throwException(env, "Failed to allocate gamma ramp buffer");
		return NULL;
	}
	out = (unsigned short *)(*env)->GetDirectBufferAddress(env, native_ramp);
	if (out == NULL)
		return NULL;
	ramp += buffer_offset;
	for (int i = 0; i < length; i++) {
		unsigned short v = (unsigned short)roundf(ramp[i] * 0xffff);
		out[i] = v;
		out[i + length] = v;
		out[i + length * 2] = v;
	}
	return native_ramp;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetGammaRamp(JNIEnv *env, jclass c, jlong display, jint screen, jobject ramp) {
	(void)env; (void)c; (void)display; (void)screen; (void)ramp;
}

/* ------------------------------------------------------------------ window */

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nCreateWindow(JNIEnv *env, jclass c, jlong display, jint screen, jobject peer_info_handle, jobject mode, jint window_mode, jint x, jint y, jboolean undecorated, jlong parent_handle, jboolean resizable) {
	meow_port_request_focus();   /* LWJGL2 resets `focused` in createWindow; X11 sends FocusIn after */
	(void)c; (void)screen; (void)x; (void)y; (void)undecorated; (void)parent_handle; (void)resizable;
	struct meow_environ_s *st = meow_state();
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, peer_info_handle, sizeof(MeowPeerInfo));
	int w = meow_w(st), h = meow_h(st);

	if (mode != NULL) {
		jclass mc = (*env)->GetObjectClass(env, mode);
		if (mc != NULL) {
			jmethodID gw = (*env)->GetMethodID(env, mc, "getWidth", "()I");
			jmethodID gh = (*env)->GetMethodID(env, mc, "getHeight", "()I");
			if (gw == NULL || gh == NULL)
				(*env)->ExceptionClear(env);   /* NoSuchMethodError would stay pending */
			if (gw != NULL && gh != NULL) {
				int mw = (int)(*env)->CallIntMethod(env, mode, gw);
				int mh = (int)(*env)->CallIntMethod(env, mode, gh);
				if (mw > 0 && mh > 0) { w = mw; h = mh; }
			}
		}
	}
	(void)window_mode;

	if (peer != NULL) {
		peer->display  = MEOW_DISPLAY_COOKIE;
		peer->screen   = 0;
		peer->drawable = (jlong)(uintptr_t)(st != NULL ? st->window : NULL);
	}
	if (st != NULL) {
		if (st->width <= 0 || st->height <= 0) { st->width = w; st->height = h; }
		if (st->savedWidth <= 0 || st->savedHeight <= 0) { st->savedWidth = w; st->savedHeight = h; }
		return (jlong)(uintptr_t)(st->window != NULL ? st->window : (void *)MEOW_ROOT_COOKIE);
	}
	/* Fallback (no shared block): still return a non-zero handle so createWindow succeeds. */
	(void)display;
	return MEOW_DISPLAY_COOKIE | 1;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_getRootWindow(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)env; (void)c; (void)display; (void)screen;
	return MEOW_ROOT_COOKIE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_mapRaised(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nDestroyWindow(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	/* Never destroy the launcher-owned OHNativeWindow. */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetWindowSize(JNIEnv *env, jclass c, jlong display, jlong window, jint width, jint height, jboolean resizable) {
	(void)env; (void)c; (void)display; (void)window; (void)width; (void)height; (void)resizable;
	/* Do NOT write the shared block's width/height mirror: the bridge owns it (it mirrors the
	 * real OHNativeWindow surface) and meowSwapBuffers() self-heals a mismatch by rebuilding the
	 * EGL surface — writing MC's requested size here desyncs the two and shows up as flicker.
	 * The ArkTS/XComponent side owns the actual window size. */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nReshape(JNIEnv *env, jclass c, jlong display, jlong window, jint x, jint y, jint width, jint height) {
	(void)env; (void)c; (void)display; (void)window; (void)x; (void)y; (void)width; (void)height;
	/* See nSetWindowSize: the surface size mirror belongs to the bridge. */
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetX(JNIEnv *env, jclass c, jlong display, jlong window) { (void)env; (void)c; (void)display; (void)window; return 0; }
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetY(JNIEnv *env, jclass c, jlong display, jlong window) { (void)env; (void)c; (void)display; (void)window; return 0; }

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetWidth(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return meow_w(meow_state());
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetHeight(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return meow_h(meow_state());
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetTitle(JNIEnv *env, jclass c, jlong display, jlong window, jlong title, jint len) {
	(void)env; (void)c; (void)display; (void)window; (void)title; (void)len;
	/* The launcher shell owns the window chrome/title. */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetClassHint(JNIEnv *env, jclass c, jlong display, jlong window, jlong wm_name, jlong wm_class) {
	(void)env; (void)c; (void)display; (void)window; (void)wm_name; (void)wm_class;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetWindowIcon(JNIEnv *env, jclass c, jlong display, jlong window, jobject icon, jint len) {
	(void)env; (void)c; (void)display; (void)window; (void)icon; (void)len;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nIconifyWindow(JNIEnv *env, jclass c, jlong display, jlong window, jint screen) {
	(void)env; (void)c; (void)display; (void)window; (void)screen;
}

/* ------------------------------------------------------------------ grabs / focus / xembed (unreachable without a parent) */

/*
 * Pointer/kb grabs, view port and display-mode switching — wired to the platform.
 *
 * The launcher's ArkTS input controller POLLS two fields of the shared block:
 *   - `grabbing` (via meowGetGrabbing()) -> lockCursor + hide the pointer. The same field also
 *     switches the bridge's pointer filter from absolute motion to grab deltas
 *     (input_bridge.c "absolute motion while not grabbing"), so writing it here is the whole
 *     mouse-lock integration for LWJGL2. LWJGL2's LinuxDisplay.grabPointer() reaches us through
 *     nGrabPointer (and ungrabPointer->nUngrabPointer); reset()/changeGrabbed then compute
 *     deltas from our nQueryPointer.
 *   - `fsRequest` (via meowTakeFullscreenRequest()) -> GameWindow.enterFullscreen()/exitFullscreen()
 *     (win.maximize immersive / recover). LWJGL2 enters legacy fullscreen through
 *     grabPointer() -> nSetViewPort (only called when isLegacyFullscreen()), and any display-mode
 *     switch comes through nSwitchDisplayMode with the target mode.
 */
#define MEOW_FS_ENTER 1
#define MEOW_FS_EXIT  0

static void meow_request_fullscreen(int want) {
	MeowBridge *b = meow_bridge();
	struct meow_environ_s *st = meow_state();
	if (b->setFullscreenRequest == NULL)
		return;
	/* The restore rect is the current (windowed) surface size; ignored when entering. */
	b->setFullscreenRequest(want, 0, 0, st != NULL ? st->width : 0, st != NULL ? st->height : 0);
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGrabKeyboard(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return 0;                /* GrabSuccess */
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nUngrabKeyboard(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 0;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGrabPointer(JNIEnv *env, jclass c, jlong display, jlong window, jlong cursor) {
	(void)env; (void)c; (void)display; (void)window; (void)cursor;
	/* Deliberately does NOT touch env->grabbing: LWJGL2 calls this in legacy fullscreen even
	 * when Mouse.isGrabbed() is false. The per-frame mirror in meow_context.c owns `grabbing`
	 * (driven by Mouse.isGrabbed()); we only report GrabSuccess so LWJGL2's pointer_grabbed
	 * bookkeeping stays correct. */
	return 0;                /* GrabSuccess -> LWJGL2 sets pointer_grabbed */
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nUngrabPointer(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	/* See nGrabPointer: `grabbing` is owned by the per-frame mirror. */
	return 0;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetViewPort(JNIEnv *env, jclass c, jlong display, jlong window, jint screen) {
	(void)env; (void)c; (void)display; (void)window; (void)screen;
	/* LinuxDisplay.grabPointer() calls this only when isLegacyFullscreen(): entering fullscreen. */
	meow_request_fullscreen(MEOW_FS_ENTER);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSwitchDisplayMode(JNIEnv *env, jclass c, jlong display, jint screen, jint extension, jobject mode) {
	(void)env; (void)c; (void)display; (void)screen; (void)extension; (void)mode;
	/* The ArkTS owns the real window. Fullscreen is mirrored per frame from the Java-side
	 * Display.isFullscreen() in nSwapBuffers (see meow_context.c) — a size comparison here
	 * cannot work because nGetAvailableDisplayModes reports the current window size as the
	 * only available mode. */
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetInputFocus(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	struct meow_environ_s *st = meow_state();
	return (jlong)(uintptr_t)(st != NULL ? st->window : (void *)MEOW_ROOT_COOKIE);
}
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nSetInputFocus(JNIEnv *env, jclass c, jlong display, jlong window, jlong time) { (void)env; (void)c; (void)display; (void)window; (void)time; }

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxDisplay_hasProperty(JNIEnv *env, jclass c, jlong display, jlong window, jlong property) { (void)env; (void)c; (void)display; (void)window; (void)property; return JNI_FALSE; }
JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_getParentWindow(JNIEnv *env, jclass c, jlong display, jlong window) { (void)env; (void)c; (void)display; (void)window; return MEOW_ROOT_COOKIE; }
JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_getChildCount(JNIEnv *env, jclass c, jlong display, jlong window) { (void)env; (void)c; (void)display; (void)window; return 0; }
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_reparentWindow(JNIEnv *env, jclass c, jlong display, jlong window, jlong parent, jint x, jint y) { (void)env; (void)c; (void)display; (void)window; (void)parent; (void)x; (void)y; }

/* ------------------------------------------------------------------ pbuffer */

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetPbufferCapabilities(JNIEnv *env, jclass c, jlong display, jint screen) {
	(void)env; (void)c; (void)display; (void)screen;
	return 0;            /* no pbuffer support; MC never uses Pbuffers */
}

/* ------------------------------------------------------------------ peer info */

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxPeerInfo_createHandle(JNIEnv *env, jclass c) {
	(void)c;
	return meow_new_buffer(env, sizeof(MeowPeerInfo));
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxPeerInfo_nGetDisplay(JNIEnv *env, jclass c, jobject handle) {
	(void)c;
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, handle, sizeof(MeowPeerInfo));
	return peer != NULL && peer->display != 0 ? peer->display : MEOW_DISPLAY_COOKIE;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxPeerInfo_nGetDrawable(JNIEnv *env, jclass c, jobject handle) {
	(void)c;
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, handle, sizeof(MeowPeerInfo));
	return peer != NULL ? peer->drawable : 0;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplayPeerInfo_initDefaultPeerInfo(JNIEnv *env, jclass c, jlong display, jint screen, jobject handle, jobject pixel_format) {
	(void)c; (void)display; (void)screen; (void)pixel_format;
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, handle, sizeof(MeowPeerInfo));
	if (peer != NULL) {
		peer->display  = MEOW_DISPLAY_COOKIE;
		peer->screen   = 0;
		peer->drawable = 0;
	}
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplayPeerInfo_initDrawable(JNIEnv *env, jclass c, jlong window, jobject handle) {
	(void)c;
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, handle, sizeof(MeowPeerInfo));
	if (peer != NULL) {
		if (window != 0)
			peer->drawable = window;
		if (peer->display == 0)
			peer->display = MEOW_DISPLAY_COOKIE;
	}
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxPbufferPeerInfo_nInitHandle(JNIEnv *env, jclass c, jlong display, jint screen, jobject handle, jint width, jint height, jobject pixel_format) {
	(void)c; (void)display; (void)screen; (void)handle; (void)width; (void)height; (void)pixel_format;
	throwException(env, "No Pbuffer support on OHOS");
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxPbufferPeerInfo_nDestroy(JNIEnv *env, jclass c, jobject handle) {
	(void)env; (void)c; (void)handle;
}

/* ------------------------------------------------------------------ AWT canvas (MC uses no Canvas parent) */

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxCanvasImplementation_nFindVisualIDFromFormat(JNIEnv *env, jclass c, jlong display, jint screen, jobject pixel_format) {
	(void)env; (void)c; (void)display; (void)screen; (void)pixel_format;
	return 0;
}
