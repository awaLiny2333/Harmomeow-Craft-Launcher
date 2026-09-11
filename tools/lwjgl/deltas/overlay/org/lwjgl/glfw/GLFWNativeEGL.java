package org.lwjgl.glfw;

import org.lwjgl.system.FunctionProvider;

public final class GLFWNativeEGL {

    private GLFWNativeEGL() {
    }

    public static long glfwGetEGLDisplay() {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetEGLContext(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetEGLSurface(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetEGLConfig(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setEGLPath(FunctionProvider provider) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setEGLPath(String path) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setGLESPath(FunctionProvider provider) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setGLESPath(String path) {
        throw new UnsupportedOperationException("Not implemented");
    }

}
