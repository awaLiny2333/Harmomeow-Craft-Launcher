/*
 * Meowcraft OHOS LWJGL2 port — LinuxContextImplementation natives.
 *
 * Replaces src/native/linux/opengl/org_lwjgl_opengl_LinuxContextImplementation.c (GLX).
 * The EGL display/context/surface and the gl4es initialisation live in
 * libmeowcraftbridge.so (egl_gl.c): the bridge creates the GLES context for the injected
 * OHNativeWindow, calls eglMakeCurrent and then initialises gl4es. We therefore only
 * forward make-current / swap / swap-interval, and keep the context handle opaque.
 *
 * ORDERING: nMakeCurrent must run before any GL entry point is called (gl4es is only
 * usable after the bridge's initialize_gl4es()); GLContext.useContext() runs right after
 * createWindow(), i.e. after our nMakeCurrent, which preserves the required order.
 */
#include "meow_port.h"
#include <stdio.h>      /* fprintf for the fullscreen state flip log */

#define MEOW_CONTEXT_MAGIC 0x4d454f57   /* 'MEOW' */

/* NOTE on GL errors: MC 1.7–1.12 never calls glGetError; the only caller is LWJGL2's
 * Display.swapBuffers() pre-swap check, which is gated on LWJGLUtil.DEBUG
 * (Display.java:616). gl4es's fixed-pipeline emulation legitimately leaves GL errors
 * behind, so the launcher must NOT enable -Dorg.lwjgl.util.Debug for the legacy
 * generation (see MinecraftLauncher.ets) — otherwise MC aborts with
 * "OpenGLException: Invalid operation (1282)". We deliberately do not swallow errors here. */

/*
 * Per-thread "is the context current" flag, mirroring LWJGL2's own model (GLContext keeps a
 * per-thread capabilities entry; releaseCurrent() clears it). It MUST flip to 0 on
 * nReleaseCurrentContext: DrawableGL.destroy() -> releaseContext() would otherwise leave
 * ContextGL.destroy() believing the context is still current, and its glGetError() would
 * throw "No OpenGL context found in the current thread" because the Java-side caps were
 * already cleared. Tracking it ourselves also keeps us off the EGL display state that the
 * process-wide bridge owns.
 */
static __thread int t_context_current = 0;

static int g_fs_mirror = -1;   /* last fullscreen state mirrored into fsRequest */

/* Diagnostics off by default (the shipped native stays quiet); MEOW_LWJGL2_VERBOSE=1 enables the
 * fullscreen / pointer-lock transition logs. */
static int meow_verbose(void) {
	static int cached = -1;
	if (cached < 0)
		cached = (getenv("MEOW_LWJGL2_VERBOSE") != NULL) ? 1 : 0;
	return cached;
}

/* Ask LWJGL2's Java side for the authoritative fullscreen state. Returns -1 when the class or
 * method cannot be resolved (then we leave the shared block alone). */
static int meow_java_is_fullscreen(JNIEnv *env) {
	jclass cls;
	jmethodID mid;
	jboolean v;

	cls = (*env)->FindClass(env, "org/lwjgl/opengl/Display");
	if (cls == NULL) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	mid = (*env)->GetStaticMethodID(env, cls, "isFullscreen", "()Z");
	if (mid == NULL) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	v = (*env)->CallStaticBooleanMethod(env, cls, mid);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	return v == JNI_TRUE ? 1 : 0;
}

/* LWJGL2's own grab wish: org.lwjgl.input.Mouse.isGrabbed() (set by the app via
 * Mouse.setGrabbed). Returns -1 when unavailable. */
static int meow_java_mouse_grabbed(JNIEnv *env) {
	jclass cls = (*env)->FindClass(env, "org/lwjgl/input/Mouse");
	jmethodID mid;
	jboolean v;

	if (cls == NULL) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	mid = (*env)->GetStaticMethodID(env, cls, "isGrabbed", "()Z");
	if (mid == NULL) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	v = (*env)->CallStaticBooleanMethod(env, cls, mid);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		return -1;
	}
	return v == JNI_TRUE ? 1 : 0;
}

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nCreate(JNIEnv *env, jclass c, jobject shared_context_handle, jobject attribs, jobject drawable_handle) {
	(void)c; (void)shared_context_handle; (void)attribs; (void)drawable_handle;
	jobject buf = meow_new_buffer(env, sizeof(MeowContext));
	MeowContext *ctx;
	if (buf == NULL) {
		throwException(env, "LWJGL2 port: could not allocate context handle");
		return NULL;
	}
	ctx = (MeowContext *)(*env)->GetDirectBufferAddress(env, buf);
	if (ctx != NULL)
		ctx->magic = MEOW_CONTEXT_MAGIC;
	return buf;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_getGLXContext(JNIEnv *env, jobject self, jobject context_handle) {
	(void)env; (void)self; (void)context_handle;
	return 0;                 /* only used for OpenCL/GL sharing, which MC does not use */
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_getDisplay(JNIEnv *env, jobject self, jobject context_handle) {
	(void)env; (void)self; (void)context_handle;
	return (jlong)0x4d454f57L; /* opaque non-zero display cookie */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nMakeCurrent(JNIEnv *env, jclass c, jobject drawable_handle, jobject context_handle) {
	static int g_noerror_done = 0;
	(void)c; (void)context_handle;
	MeowBridge *b = meow_bridge();
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, drawable_handle, sizeof(MeowPeerInfo));
	struct meow_environ_s *st = meow_state();
	void *window = NULL;

	/*
	 * Silence gl4es's emulation noise for the legacy generation.
	 *
	 * MC 1.7–1.12 calls glGetError() every frame (its own "########## GL ERROR ##########"
	 * logger), and gl4es's glGetError() forwards the UNDERLYING GLES error (see
	 * ref/gl4es/src/gl/getter.c), so gl4es's internal calls leave a pending error that MC
	 * logs on every frame. LIBGL_NOERROR=1 is gl4es's documented switch for apps that check
	 * glGetError (getter.c: `if (globals4es.noerror) return GL_NO_ERROR;`).
	 *
	 * gl4es reads the flag once, inside initialize_gl4es(), which the bridge runs as part of
	 * the make-current below — so setting it here is early enough and scoped to this
	 * generation only (liblwjgl.so serves MC 1.7–1.12 exclusively). Set MEOW_LWJGL2_GLERRORS=1
	 * in the environment to keep real GL errors visible for debugging.
	 */
	if (!g_noerror_done) {
		g_noerror_done = 1;
		if (getenv("MEOW_LWJGL2_GLERRORS") == NULL)
			setenv("LIBGL_NOERROR", "1", 1);
	}

	if (peer != NULL && peer->drawable != 0)
		window = (void *)(uintptr_t)peer->drawable;
	else if (st != NULL)
		window = st->window;

	if (!b->resolved) {
		throwException(env, "LWJGL2 port: meowMakeCurrent unavailable");
		return;                 /* do not claim "current" on the failure path */
	}
	b->makeCurrent(window);
	t_context_current = 1;      /* LWJGL2 uses this for isCurrent()/destroy() bookkeeping */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nSwapBuffers(JNIEnv *env, jclass c, jobject context_handle) {
	(void)c; (void)context_handle;
	MeowBridge *b = meow_bridge();
	struct meow_environ_s *st = meow_state();
	int fs;

	/* Fullscreen mirror (once per frame): the authoritative state lives in LWJGL2's Java side,
	 * so ask it instead of guessing from the native hooks — our nGetAvailableDisplayModes
	 * reports the CURRENT window size as the only mode, which made a size-based heuristic in
	 * nSwitchDisplayMode never fire (and nSetViewPort is not reliably reached either).
	 * Display.isFullscreen() -> shared-block fsRequest (1 = enter / 2 = exit), which the ArkTS
	 * polls to win.maximize(immersive) / win.recover(); the resulting surface size comes back
	 * to us as ConfigureNotify. */
	fs = meow_java_is_fullscreen(env);
	if (fs >= 0 && b->setFullscreenRequest != NULL) {
		if (g_fs_mirror < 0) {
			g_fs_mirror = fs;              /* first reading: adopt silently, request nothing */
		} else if (fs != g_fs_mirror) {
			g_fs_mirror = fs;
			b->setFullscreenRequest(fs, 0, 0, st != NULL ? st->width : 0, st != NULL ? st->height : 0);
			if (meow_verbose())
				fprintf(stderr, "LWJGL2 port: fullscreen -> %d (fsRequest=%d)\n", fs, fs ? 1 : 2);
		}
	}

	/* Pointer lock, also mirrored authoritatively: LWJGL2 may lock the pointer for fullscreen
	 * (Display.isFullscreen()) or because the app asked for a grab (Mouse.isGrabbed()). Merely
	 * clearing it on nUngrabPointer is not enough — LWJGL2 does not always re-issue that when
	 * leaving legacy fullscreen, which left the cursor hidden/locked after exiting. */
	if (st != NULL) {
		int grabbed = meow_java_mouse_grabbed(env);
		/* Pointer lock follows the APP's grab wish ONLY (org.lwjgl.input.Mouse.isGrabbed), NOT
		 * fullscreen: LinuxDisplay.updatePointerGrab() grabs the pointer in legacy fullscreen
		 * too, but it blanks/hides the cursor only when shouldGrab() (Mouse.isGrabbed()) is true
		 * (LinuxDisplay.java:432-440). Tying the lock to fullscreen made MC's MENUS unusable in
		 * fullscreen — the bridge suppresses absolute motion while grabbing, so the menu cursor
		 * could not move and nothing was clickable. */
		int lock = (grabbed > 0) ? 1 : 0;
		if (lock != st->grabbing) {
			st->grabbing = lock;
			st->isGrabbing = (unsigned char)lock;
			if (meow_verbose())
				fprintf(stderr, "LWJGL2 port: pointer lock -> %d (fs=%d grabbed=%d)\n", lock, fs, grabbed);
		}
	}

	if (b->resolved)
		b->swapBuffers();
	else
		throwException(env, "LWJGL2 port: meowSwapBuffers unavailable");
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nIsCurrent(JNIEnv *env, jclass c, jobject context_handle) {
	(void)env; (void)c; (void)context_handle;
	return t_context_current ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nSetSwapInterval(JNIEnv *env, jclass c, jobject drawable_handle, jobject context_handle, jint value) {
	(void)env; (void)c; (void)drawable_handle; (void)context_handle;
	MeowBridge *b = meow_bridge();
	if (b->resolved && b->swapInterval != NULL)
		b->swapInterval((int)value);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nReleaseCurrentContext(JNIEnv *env, jclass c, jobject context_handle) {
	(void)env; (void)c; (void)context_handle;
	/* Report "not current" from now on (see nIsCurrent). The bridge's EGL context is
	 * process-wide and is simply rebound by the next make-current, so we do not touch the
	 * EGL display state here. */
	t_context_current = 0;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nDestroy(JNIEnv *env, jclass c, jobject drawable_handle, jobject context_handle) {
	(void)env; (void)c; (void)drawable_handle; (void)context_handle;
	/* Never terminate the bridge's EGL/gl4es state while the process keeps running. */
}
