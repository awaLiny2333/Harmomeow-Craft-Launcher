package org.lwjgl.glfw;

import java.nio.IntBuffer;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.FunctionProvider;

public final class GLFWNativeOSMesa {

    private GLFWNativeOSMesa() {
    }

    public static int nglfwGetOSMesaColorBuffer(long window, long width, long height, long format,
            long buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static boolean glfwGetOSMesaColorBuffer(long window, IntBuffer width, IntBuffer height,
            IntBuffer format, PointerBuffer buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static int nglfwGetOSMesaDepthBuffer(long window, long width, long height,
            long bytesPerValue, long buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static int glfwGetOSMesaDepthBuffer(long window, IntBuffer width, IntBuffer height,
            IntBuffer bytesPerValue, PointerBuffer buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static long glfwGetOSMesaContext(long window) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static boolean glfwGetOSMesaColorBuffer(long window, int[] width, int[] height,
            int[] format, PointerBuffer buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static int glfwGetOSMesaDepthBuffer(long window, int[] width, int[] height,
            int[] bytesPerValue, PointerBuffer buffer) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setPath(FunctionProvider provider) {
        throw new UnsupportedOperationException("Not implemented");
    }

    public static void setPath(String path) {
        throw new UnsupportedOperationException("Not implemented");
    }

}
