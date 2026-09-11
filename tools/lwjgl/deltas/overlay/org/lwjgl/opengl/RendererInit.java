package org.lwjgl.opengl;

import org.lwjgl.system.FunctionProvider;
import org.lwjgl.system.SharedLibrary;

public final class RendererInit {

    private RendererInit() {
    }

    public static void onCreateCapabilities(FunctionProvider provider) {
        String rendererName = null;
        if (provider instanceof SharedLibrary) {
            rendererName = ((SharedLibrary) provider).getName();
        }
        if (!isValid(rendererName)) {
            rendererName = System.getProperty("org.lwjgl.opengl.libname");
        }
        if (!isValid(rendererName)) {
            System.out.println("RendererInit: renderer name unavailable; "
                    + "renderer-specific initialization is skipped");
            return;
        }
        if (rendererName.endsWith("libng_gl4es.so")) {
            nativeInitGl4esInternals(provider);
        }
    }

    private static boolean isValid(String value) {
        return value != null && !value.isEmpty();
    }

    public static native void nativeInitGl4esInternals(FunctionProvider provider);

}
