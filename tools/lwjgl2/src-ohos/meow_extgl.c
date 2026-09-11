/*
 * Meowcraft OHOS LWJGL2 port — GL function resolver.
 *
 * Replaces the upstream X11/GLX platform glue (src/native/linux/opengl/extgl_glx.c).
 * Upstream dlopens libGL.so.1 and resolves every GL entry point through
 * glXGetProcAddressARB; OHOS has no GLX, so we resolve the same names through our
 * GL provider (gl4es, the desktop-GL -> GLES translator we already build for the
 * LWJGL3 path) and, as a fallback, the platform EGL's eglGetProcAddress.
 *
 * The provider is dlopened (NOT linked): the shipped .so must not gain a DT_NEEDED
 * on any GL library. Name is overridable at runtime with MEOW_LWJGL2_GL.
 *
 * The NV_*_video helpers below are GLX/WGL-only by construction; on OHOS they report
 * "unavailable" (LWJGL2's Java side only reaches them through the GLX/WGL peer code).
 */
#include <dlfcn.h>
#include <stdlib.h>
#include <jni.h>

#include "common_tools.h"
#include "extgl.h"

typedef void * (APIENTRY * MeowGetProcAddressPROC)(const char *name);

static void *lib_gl_handle = NULL;
static MeowGetProcAddressPROC meow_proc_addr = NULL;

/* ------------------------------------------------------------------ NV video */
/* All return "no device / not available"; signatures must match extgl.h exactly. */

jint extgl_EnumerateVideoDevicesNV(JNIEnv *env, jobject peer_info_handle, jobject devices, jint devices_position) {
	(void)env; (void)peer_info_handle; (void)devices; (void)devices_position;
	return 0;
}

jboolean extgl_BindVideoDeviceNV(JNIEnv *env, jobject peer_info_handle, jint video_slot, jlong video_device, jobject attrib_list, jint attrib_list_position) {
	(void)env; (void)peer_info_handle; (void)video_slot; (void)video_device; (void)attrib_list; (void)attrib_list_position;
	return JNI_FALSE;
}

jboolean extgl_QueryContextNV(JNIEnv *env, jobject peer_info_handle, jobject context_handle, jint attrib, jobject value, jint value_position) {
	(void)env; (void)peer_info_handle; (void)context_handle; (void)attrib; (void)value; (void)value_position;
	return JNI_FALSE;
}

jboolean extgl_BindVideoCaptureDeviceNV(JNIEnv *env, jobject peer_info_handle, jint video_slot, jlong device) {
	(void)env; (void)peer_info_handle; (void)video_slot; (void)device;
	return JNI_FALSE;
}

jint extgl_EnumerateVideoCaptureDevicesNV(JNIEnv *env, jobject peer_info_handle, jobject devices, jint devices_position) {
	(void)env; (void)peer_info_handle; (void)devices; (void)devices_position;
	return 0;
}

jboolean extgl_LockVideoCaptureDeviceNV(JNIEnv *env, jobject peer_info_handle, jlong device) {
	(void)env; (void)peer_info_handle; (void)device;
	return JNI_FALSE;
}

jboolean extgl_QueryVideoCaptureDeviceNV(JNIEnv *env, jobject peer_info_handle, jlong device, jint attribute, jobject value, jint value_position) {
	(void)env; (void)peer_info_handle; (void)device; (void)attribute; (void)value; (void)value_position;
	return JNI_FALSE;
}

jboolean extgl_ReleaseVideoCaptureDeviceNV(JNIEnv *env, jobject peer_info_handle, jlong device) {
	(void)env; (void)peer_info_handle; (void)device;
	return JNI_FALSE;
}

/* -------------------------------------------------------------------- provider */

static const char *meow_gl_provider_name(void) {
	const char *name = getenv("MEOW_LWJGL2_GL");
	return (name != NULL && *name != '\0') ? name : "libgl4es.so";
}

/* env may be NULL when called from a path where no Java exception can be raised. */
static bool meow_open_provider(JNIEnv *env) {
	const char *name;

	if (lib_gl_handle != NULL)
		return true;

	name = meow_gl_provider_name();
	lib_gl_handle = dlopen(name, RTLD_LAZY | RTLD_GLOBAL);
	if (lib_gl_handle == NULL) {
		if (env != NULL)
			throwFormattedException(env, "Error loading GL provider '%s': %s", name, dlerror());
		return false;
	}

	/* gl4es exposes the GLX-style resolver; the platform EGL one is the fallback. */
	meow_proc_addr = (MeowGetProcAddressPROC)dlsym(lib_gl_handle, "glXGetProcAddressARB");
	if (meow_proc_addr == NULL)
		meow_proc_addr = (MeowGetProcAddressPROC)dlsym(lib_gl_handle, "glXGetProcAddress");
	if (meow_proc_addr == NULL)
		meow_proc_addr = (MeowGetProcAddressPROC)dlsym(lib_gl_handle, "eglGetProcAddress");
	if (meow_proc_addr == NULL)
		printfDebug("GL provider '%s' exposes no GetProcAddress entry point; using dlsym only\n", name);
	else
		printfDebug("GL provider '%s' opened\n", name);

	return true;
}

bool extgl_Open(JNIEnv *env) {
	return meow_open_provider(env);
}

void *extgl_GetProcAddress(const char *name) {
	void *t = NULL;

	if (lib_gl_handle == NULL)
		meow_open_provider(NULL);          /* GLContext.nLoadOpenGLLibrary normally opens first */

	if (meow_proc_addr != NULL)
		t = meow_proc_addr(name);
	if (t == NULL && lib_gl_handle != NULL)
		t = dlsym(lib_gl_handle, name);
	if (t == NULL)
		t = dlsym(RTLD_DEFAULT, name);
	if (t == NULL)
		printfDebug("Could not locate symbol %s\n", name);
	return t;
}

void extgl_Close(void) {
	if (lib_gl_handle != NULL)
		dlclose(lib_gl_handle);
	lib_gl_handle = NULL;
	meow_proc_addr = NULL;
}
