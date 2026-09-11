package org.lwjgl.glfw;

import org.lwjgl.system.FunctionProvider;

public final class GLFWNativeWGL {

    private GLFWNativeWGL() {
    }

    public static long glfwGetWGLContext(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setPath(FunctionProvider provider) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setPath(String path) {
        throw new UnsupportedOperationException("Not implemented");
    }

}
