/*
 * Meowcraft OHOS LWJGL2 port — native cursor natives (declared on LinuxDisplay).
 *
 * Replaces the Xcursor parts of src/native/linux/org_lwjgl_input_Cursor.c and the cursor
 * natives of org_lwjgl_opengl_Display.c. OHOS has no X11 cursor resources and the pointer
 * is drawn by the platform, so real cursor images are not created: we hand back unique
 * non-zero opaque tokens (the Java side only stores and compares them) and advertise a
 * capability set that keeps Cursor's constructor and MC's setNativeCursor() path happy.
 *
 * LinuxDisplay.java requires CURSOR_ONE_BIT_TRANSPARENCY (1) to be set, otherwise
 * Cursor() throws LWJGLException.
 */
#include "meow_port.h"

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetNativeCursorCapabilities(JNIEnv *env, jclass c, jlong display) {
	(void)env; (void)c; (void)display;
	return 1 | 2;            /* CURSOR_ONE_BIT_TRANSPARENCY | CURSOR_ANIMATION */
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetMinCursorSize(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return 1;
}

JNIEXPORT jint JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nGetMaxCursorSize(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return 256;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nCreateCursor(JNIEnv *env, jclass c, jlong display, jint width, jint height, jint x_hotspot, jint y_hotspot, jint num_images, jobject images, jint images_offset, jobject delays, jint delays_offset) {
	(void)c; (void)display; (void)width; (void)height; (void)x_hotspot; (void)y_hotspot;
	(void)num_images; (void)images; (void)images_offset; (void)delays; (void)delays_offset;
	static jlong seq = 0x43555200L;      /* 'CUR' */
	(void)env;
	return ++seq;
}

JNIEXPORT jlong JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nCreateBlankCursor(JNIEnv *env, jclass c, jlong display, jlong window) {
	(void)env; (void)c; (void)display; (void)window;
	return 0x424c414eL;                  /* 'BLAN' */
}

JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nDestroyCursor(JNIEnv *env, jclass c, jlong display, jlong cursor) {
	(void)env; (void)c; (void)display; (void)cursor;
}

/* XDefineCursor: applies a cursor to a window. The OHOS pointer is drawn by the platform,
 * so this is a no-op (it must exist and must not throw). */
JNIEXPORT void JNICALL Java_org_lwjgl_opengl_LinuxDisplay_nDefineCursor(JNIEnv *env, jclass c, jlong display, jlong window, jlong cursor_handle) {
	(void)env; (void)c; (void)display; (void)window; (void)cursor_handle;
}
