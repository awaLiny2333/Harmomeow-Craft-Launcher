package org.lwjgl.glfw;

import java.nio.ByteBuffer;

public final class CallbackBridge {

    public static final int EVENT_TYPE_CHAR = 1000;
    public static final int EVENT_TYPE_CHAR_MODS = 1001;
    public static final int EVENT_TYPE_CURSOR_ENTER = 1002;
    public static final int EVENT_TYPE_CURSOR_POS = 1003;
    public static final int EVENT_TYPE_FRAMEBUFFER_SIZE = 1004;
    public static final int EVENT_TYPE_KEY = 1005;
    public static final int EVENT_TYPE_MOUSE_BUTTON = 1006;
    public static final int EVENT_TYPE_SCROLL = 1007;
    public static final int EVENT_TYPE_WINDOW_SIZE = 1008;

    public static final int CLIPBOARD_COPY = 2000;
    public static final int CLIPBOARD_PASTE = 2001;

    public static final int ANDROID_TYPE_GRAB_STATE = 0;

    public static final int SDL = 0;
    public static final int INIT = 0;

    public static final boolean INPUT_DEBUG_ENABLED =
            Boolean.parseBoolean(System.getProperty("glfwstub.debugInput", "false"));

    public static boolean sGamepadDirectEnabled;

    private CallbackBridge() {
    }

    public static void sendData(int type, String data) {
        nativeSendData(false, type, data);
    }

    public static void enableGamepadDirectInput() {
        if (!sGamepadDirectEnabled) {
            sGamepadDirectEnabled = nativeEnableGamepadDirectInput();
        }
    }

    public static native void nativeSendData(boolean isAndroid, int type, String data);

    public static native boolean nativeSetInputReady(boolean ready);

    public static native String nativeClipboard(int action, byte[] copy);

    public static native void nativeSetGrabbing(boolean grab);

    /**
     * Forward a GLFW fullscreen toggle (glfwSetWindowMonitor) to the launcher.
     * The GLFW stub has no real OS window; the launcher (ArkTS) owns the window and
     * drives it fullscreen/windowed. {@code x/y/width/height} is the rect MC asked for
     * (windowed restore geometry when exiting fullscreen).
     */
    public static native void nativeSetFullscreen(boolean fullscreen, int x, int y, int width, int height);

    public static native ByteBuffer nativeCreateGamepadButtonBuffer();

    public static native ByteBuffer nativeCreateGamepadAxisBuffer();

    public static native boolean nativeEnableGamepadDirectInput();

    public static native float nativeGetAndroidDPI();

    public static native boolean nativeNotifyLauncher(int type, int... action);

}
