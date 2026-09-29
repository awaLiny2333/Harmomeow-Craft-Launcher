/*
 * Meowcraft OHOS LWJGL2 port — LinuxContextImplementation natives.
 *
 * Replaces src/native/linux/opengl/org_lwjgl_opengl_LinuxContextImplementation.c (GLX).
 * The EGL display/context/surface and the gl4es initialisation live in
 * libmeowcraftbridge.so (egl_gl.c): the bridge creates the GLES context for the injected
 * OHNativeWindow, calls eglMakeCurrent and then initialises gl4es. We forward
 * create / make-current / swap / swap-interval, and carry the bridge's context handle in
 * the opaque buffer we hand to LWJGL.
 *
 * SHARED CONTEXTS: LWJGL2's SharedDrawable (DrawableGL.createSharedContext) requires a
 * SECOND context that SHARES objects with the primary one -- that is how FML's 1.7.10
 * console splash renders on a thread of its own. nCreate therefore forwards the sharing
 * handle to the bridge, which creates a real shared EGL context. A make-current the bridge
 * cannot satisfy is reported as an LWJGLException: claiming "current" anyway made gl4es run
 * with no current context and killed the process (SIGSEGV, measured 2026-09-29).
 *
 * ORDERING: nMakeCurrent must run before any GL entry point is called (gl4es is only
 * usable after the bridge's initialize_gl4es()); GLContext.useContext() runs right after
 * createWindow(), i.e. after our nMakeCurrent, which preserves the required order.
 *
 * ★JNI ARGUMENT CONTRACT (2026-09-29, VERIFIED against the upstream declarations). The
 *   parameter POSITION decides the meaning, and two of the natives take a PEER handle
 *   where it is easy to assume a CONTEXT handle. Read them off the Java natives
 *   (ref/lwjgl/src/java/org/lwjgl/opengl/LinuxContextImplementation.java):
 *
 *     nCreate(peer_handle, attribs, shared_context_handle)        [:60]  (static)
 *     nMakeCurrent(peer_handle, context_handle)                   [:130] (static)
 *     nIsCurrent(context_handle)                                  [:142] (static)
 *     nSetSwapInterval(peer_handle, context_handle, value)        [:170] (static)
 *     nDestroy(peer_handle, context_handle)                       [:186] (static)
 *     nReleaseCurrentContext(peer_info_handle)                    [:111] (static)
 *     nSwapBuffers(peer_info_handle)                              [:89]  (static)
 *     getGLXContext(context_handle) / getDisplay(peer_info_handle) [:62/:64] (instance)
 *
 *   The sibling natives keep the historical names below aligned with those positions so
 *   the same root cause (reading the wrong slot) cannot recur.
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
 * Per-thread current context, mirroring LWJGL2's own model (GLContext keeps a per-thread
 * capabilities entry; releaseCurrent() clears it) while also naming WHICH context, because a
 * shared context can be bound on a thread of its own. It MUST clear on
 * nReleaseCurrentContext: DrawableGL.destroy() -> releaseContext() would otherwise leave
 * ContextGL.destroy() believing the context is still current, and its glGetError() would
 * throw "No OpenGL context found in the current thread" because the Java-side caps were
 * already cleared. The authoritative EGL state stays in the process-wide bridge.
 */
static __thread MeowContext *t_current_ctx = NULL;

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

JNIEXPORT jobject JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nCreate(JNIEnv *env, jclass c, jobject peer_handle, jobject attribs, jobject shared_context_handle) {
	MeowBridge *b = meow_bridge();
	jobject buf;
	MeowContext *ctx;
	/*
	 * ★形参口径（2026-09-29 修正，VERIFIED）：上游 LWJGL2 的 JNI 契约是
	 *     LinuxContextImplementation.create(peer_info, attribs, shared_context_handle)
	 *       -> nCreate(peer_handle, attribs, shared_context_handle)      [LinuxContextImplementation.java:46,51,60]
	 * 即**第 1 个实参是 peer_handle、第 3 个才是共享上下文句柄**。
	 * 本文件的历史形参名把它们写反了（旧实现三者全丢弃，所以没暴露）；我们第一次实现共享上下文时
	 * 照着错的形参名读第 1 个实参 ⇒ 把 peer 缓冲当 MeowContext 读 ⇒ `bridge_ctx` 恒为 NULL
	 * ⇒ 桥永远走 `share == NULL`（主槽位）⇒ **共享上下文一次都没建过**（实机日志里
	 * `shared ctx created` 从来不存在），SharedDrawable 拿到的是主槽位 ⇒ splash 线程 make-current
	 * 打在主上下文上 ⇒ EGL_BAD_ACCESS(3002) ⇒ 抛异常 ⇒ FML 自行禁用 splash。
	 * 现在按**真实契约**读第 3 个实参。
	 */
	MeowContext *shared = (MeowContext *)meow_direct(env, shared_context_handle, sizeof(MeowContext));
	(void)c; (void)attribs; (void)peer_handle;
	/*
	 * LWJGL2 对主上下文传 NULL、对 SharedDrawable 传父上下文的 handle
	 * （ContextGL.java:132 `shared_context != null ? shared_context.handle : null`）。
	 * 桥把后者变成真正的共享 EGL 上下文；对前者只是登记主槽位，EGL 上下文仍保持懒创建。
	 */
	buf = meow_new_buffer(env, sizeof(MeowContext));
	if (buf == NULL) {
		throwException(env, "LWJGL2 port: could not allocate context handle");
		return NULL;
	}
	ctx = (MeowContext *)(*env)->GetDirectBufferAddress(env, buf);
	if (ctx == NULL) {
		throwException(env, "LWJGL2 port: context handle buffer is not direct");
		return NULL;
	}
	ctx->magic = MEOW_CONTEXT_MAGIC;
	ctx->bridge_ctx = NULL;
	if (b->createContext != NULL) {
		ctx->bridge_ctx = b->createContext(shared != NULL ? shared->bridge_ctx : NULL);
		if (ctx->bridge_ctx == NULL) {
			/* Handing LWJGL a handle it cannot bind is what let a failed make-current pass
			 * for success and crash gl4es with no current context. Fail loudly instead. */
			throwException(env, "LWJGL2 port: cannot create GL context (see bridge log)");
			return NULL;
		}
	}
	return buf;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_getGLXContext(JNIEnv *env, jobject self, jobject context_handle) {
	(void)env; (void)self; (void)context_handle;
	return 0;                 /* only used for OpenCL/GL sharing, which MC does not use */
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_getDisplay(JNIEnv *env, jobject self, jobject peer_info_handle) {
	(void)env; (void)self; (void)peer_info_handle;   /* peer handle, per LinuxContextImplementation.java:64 */
	return (jlong)0x4d454f57L; /* opaque non-zero display cookie */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nMakeCurrent(JNIEnv *env, jclass c, jobject peer_handle, jobject context_handle) {
	static int g_noerror_done = 0;
	(void)c;
	MeowBridge *b = meow_bridge();
	/* 第 1 个实参是 **peer handle**（LinuxContextImplementation.java:116,121,130：
	 * makeCurrent(peer_info, handle) -> nMakeCurrent(peer_handle, handle)），即 LinuxPeerInfo；
	 * 第 2 个才是上下文句柄。名字曾写作 drawable_handle（同一类口径债）。 */
	MeowPeerInfo *peer = (MeowPeerInfo *)meow_direct(env, peer_handle, sizeof(MeowPeerInfo));
	MeowContext *ctx = (MeowContext *)meow_direct(env, context_handle, sizeof(MeowContext));
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
	/*
	 * Prefer the registry entry point: it binds the context LWJGL actually asked for (a
	 * shared context is bound on a thread of its own) and reports whether it worked. The
	 * legacy makeCurrent() returns nothing, so a failure there can only be logged by the
	 * bridge -- and a silently failed bind is what crashed gl4es.
	 */
	if (b->makeCurrentFor != NULL && ctx != NULL && ctx->bridge_ctx != NULL) {
		if (!b->makeCurrentFor(window, ctx->bridge_ctx)) {
			throwException(env, "LWJGL2 port: make-current failed (see bridge log)");
			return;             /* still not current: LWJGL has to see that */
		}
	} else {
		b->makeCurrent(window);
	}
	t_current_ctx = ctx;        /* LWJGL2 uses this for isCurrent()/destroy() bookkeeping */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nSwapBuffers(JNIEnv *env, jclass c, jobject peer_info_handle) {
	(void)c; (void)peer_info_handle;   /* contract: LinuxContextImplementation.java:69,79,89 actually passes the peer handle here */
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
	MeowContext *ctx = (MeowContext *)meow_direct(env, context_handle, sizeof(MeowContext));
	(void)c;
	/* 口径核对（LinuxContextImplementation.java:132,135,142）：这里**确实**是上下文句柄
	 * （isCurrent(handle) -> nIsCurrent(context_handle)），与 nReleaseCurrentContext 不同。
	 * Ask about THIS context: a shared context is bound on another thread, so a plain
	 * per-thread boolean would answer for the wrong one. */
	return (ctx != NULL && ctx == t_current_ctx) ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nSetSwapInterval(JNIEnv *env, jclass c, jobject peer_handle, jobject context_handle, jint value) {
	(void)env; (void)c; (void)peer_handle; (void)context_handle;   /* peer handle first per LinuxContextImplementation.java:144,157,170 */
	MeowBridge *b = meow_bridge();
	if (b->resolved && b->swapInterval != NULL)
		b->swapInterval((int)value);
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nReleaseCurrentContext(JNIEnv *env, jclass c, jobject peer_info_handle) {
	MeowBridge *b = meow_bridge();
	(void)c;
	/*
	 * ★形参口径（2026-09-29 修正，契约出处 LinuxContextImplementation.java:91,101,111）：
	 * releaseCurrentContext() 传给 native 的是 **peer_info handle**
	 * （`current_peer_info.lockAndGetHandle()`），**不是**上下文句柄 —— 上游 native 声明的
	 * 形参名就是 `peer_info_handle`。这里历史实现把它当 MeowContext 读（读出的是
	 * MeowPeerInfo 的 `screen` 字段当 bridge_ctx），之所以一直无害，是因为 release 走
	 * `window == NULL`：桥上 meowMakeCurrentFor() 在解引用 handle 前就短路 release 并返回
	 * （见 libs/meowcraftlib/.../egl_gl.c:808-822）⇒ 垃圾指针从未被解引用。
	 * 现在按真实契约**显式不使用**该实参：release 要解除的是「本线程当前绑定」，
	 * 以 t_current_ctx 为准（nMakeCurrent 在此登记）。
	 */
	(void)peer_info_handle;
	MeowContext *ctx = t_current_ctx;
	/* Report "not current" from now on (see nIsCurrent) and have the bridge release this
	 * thread's binding: with shared contexts the old "just rebind later" shortcut is not
	 * enough, because the next bind may be for a different context. */
	if (b->makeCurrentFor != NULL && ctx != NULL && ctx->bridge_ctx != NULL)
		b->makeCurrentFor(NULL, ctx->bridge_ctx);   /* window == NULL => thread-local release */
	else if (b->resolved)
		b->makeCurrent(NULL);
	t_current_ctx = NULL;
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxContextImplementation_nDestroy(JNIEnv *env, jclass c, jobject peer_handle, jobject context_handle) {
	MeowBridge *b = meow_bridge();
	MeowContext *ctx = (MeowContext *)meow_direct(env, context_handle, sizeof(MeowContext));
	(void)c; (void)peer_handle;   /* peer handle first per LinuxContextImplementation.java:172,177,186 */
	/* Never terminate the bridge's primary EGL/gl4es state while the process keeps running
	 * (the bridge ignores a destroy for the primary slot). A secondary -- shared -- context
	 * is ours to destroy. */
	if (b->destroyContext != NULL && ctx != NULL && ctx->bridge_ctx != NULL)
		b->destroyContext(ctx->bridge_ctx);
	if (ctx != NULL) {
		ctx->bridge_ctx = NULL;
		if (ctx == t_current_ctx)
			t_current_ctx = NULL;
	}
}
