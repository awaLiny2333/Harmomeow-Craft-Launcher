/*
 * Meowcraft OHOS LWJGL2 port — Sys natives.
 *
 * Upstream implements Java_org_lwjgl_DefaultSysImplementation_getJNIVersion inside the
 * per-platform display file (src/native/linux/opengl/org_lwjgl_opengl_Display.c:110),
 * returning the constant
 *
 *     org_lwjgl_LinuxSysImplementation_JNI_VERSION
 *
 * which javah emitted as a `#define ... 19` from LinuxSysImplementation.java:46
 * (`private static final int JNI_VERSION = 19`; build.xml:414 asserts the define).
 * `javac -h` (our javah replacement) does NOT write a header for a class that declares
 * no native methods, so that macro no longer exists — we inline the same value here.
 *
 * The other two DefaultSysImplementation natives (getPointerSize, setDebug) live in the
 * reusable upstream file src/native/common/common_tools.c and are not duplicated here.
 * Keep 19 in sync with ref/lwjgl/src/java/org/lwjgl/LinuxSysImplementation.java.
 */
#include <jni.h>

JNIEXPORT jint JNICALL Java_org_lwjgl_DefaultSysImplementation_getJNIVersion(JNIEnv *env, jobject ignored) {
	(void)env;
	(void)ignored;
	return 19;
}
