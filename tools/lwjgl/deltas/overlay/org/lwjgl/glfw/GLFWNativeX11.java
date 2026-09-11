package org.lwjgl.glfw;

import java.nio.ByteBuffer;

public final class GLFWNativeX11 {

    private GLFWNativeX11() {
    }

    public static long glfwGetX11Display() {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetX11Adapter(long monitor) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetX11Monitor(long monitor) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetX11Window(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void nglfwSetX11SelectionString(long string) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void glfwSetX11SelectionString(ByteBuffer string) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void glfwSetX11SelectionString(CharSequence string) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long nglfwGetX11SelectionString() {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static String glfwGetX11SelectionString() {
        throw new UnsupportedOperationException("Not implemented");
    }

}
