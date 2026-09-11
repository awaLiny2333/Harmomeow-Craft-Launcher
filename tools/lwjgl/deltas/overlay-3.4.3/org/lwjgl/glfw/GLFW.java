/*
 * Meowcraft clean-room GLFW overlay — LWJGL 3.4.x generation.
 *
 * DERIVED FILE: this is ../overlay/org/lwjgl/glfw/GLFW.java (the common clean-room
 * overlay) plus exactly two deltas required by the 3.4.x line:
 *   1. GLFW_VERSION_* bumped to the 3.4.x version;
 *   2. the 3.4.x IME / preedit API added (glfwSetPreeditCallback,
 *      glfwSetIMEStatusCallback, glfwSetPreeditCursorRectangle) — MC >= 1.22
 *      references these from InputConstants / TextInputManager.
 * When the common overlay changes, re-sync this copy; keep the delta minimal.
 */
package org.lwjgl.glfw;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.DoubleBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

import org.lwjgl.PointerBuffer;
import org.lwjgl.system.Library;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.SharedLibrary;

import static org.lwjgl.system.APIUtil.*;
import static org.lwjgl.system.Checks.*;
import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.MemoryUtil.*;

public class GLFW {

    public static final int GLFW_VERSION_MAJOR = 3;
    public static final int GLFW_VERSION_MINOR = 4;
    public static final int GLFW_VERSION_REVISION = 3;

    public static final int GLFW_TRUE = 1;
    public static final int GLFW_FALSE = 0;

    public static final int GLFW_RELEASE = 0;
    public static final int GLFW_PRESS = 1;
    public static final int GLFW_REPEAT = 2;

    public static final int
        GLFW_HAT_CENTERED = 0,
        GLFW_HAT_UP = 1,
        GLFW_HAT_RIGHT = 2,
        GLFW_HAT_DOWN = 4,
        GLFW_HAT_LEFT = 8,
        GLFW_HAT_RIGHT_UP = GLFW_HAT_RIGHT | GLFW_HAT_UP,
        GLFW_HAT_RIGHT_DOWN = GLFW_HAT_RIGHT | GLFW_HAT_DOWN,
        GLFW_HAT_LEFT_UP = GLFW_HAT_LEFT | GLFW_HAT_UP,
        GLFW_HAT_LEFT_DOWN = GLFW_HAT_LEFT | GLFW_HAT_DOWN;

    public static final int GLFW_KEY_UNKNOWN = -1;

    public static final int
        GLFW_KEY_SPACE = 32,
        GLFW_KEY_APOSTROPHE = 39,
        GLFW_KEY_COMMA = 44,
        GLFW_KEY_MINUS = 45,
        GLFW_KEY_PERIOD = 46,
        GLFW_KEY_SLASH = 47,
        GLFW_KEY_0 = 48,
        GLFW_KEY_1 = 49,
        GLFW_KEY_2 = 50,
        GLFW_KEY_3 = 51,
        GLFW_KEY_4 = 52,
        GLFW_KEY_5 = 53,
        GLFW_KEY_6 = 54,
        GLFW_KEY_7 = 55,
        GLFW_KEY_8 = 56,
        GLFW_KEY_9 = 57,
        GLFW_KEY_SEMICOLON = 59,
        GLFW_KEY_EQUAL = 61,
        GLFW_KEY_A = 65,
        GLFW_KEY_B = 66,
        GLFW_KEY_C = 67,
        GLFW_KEY_D = 68,
        GLFW_KEY_E = 69,
        GLFW_KEY_F = 70,
        GLFW_KEY_G = 71,
        GLFW_KEY_H = 72,
        GLFW_KEY_I = 73,
        GLFW_KEY_J = 74,
        GLFW_KEY_K = 75,
        GLFW_KEY_L = 76,
        GLFW_KEY_M = 77,
        GLFW_KEY_N = 78,
        GLFW_KEY_O = 79,
        GLFW_KEY_P = 80,
        GLFW_KEY_Q = 81,
        GLFW_KEY_R = 82,
        GLFW_KEY_S = 83,
        GLFW_KEY_T = 84,
        GLFW_KEY_U = 85,
        GLFW_KEY_V = 86,
        GLFW_KEY_W = 87,
        GLFW_KEY_X = 88,
        GLFW_KEY_Y = 89,
        GLFW_KEY_Z = 90,
        GLFW_KEY_LEFT_BRACKET = 91,
        GLFW_KEY_BACKSLASH = 92,
        GLFW_KEY_RIGHT_BRACKET = 93,
        GLFW_KEY_GRAVE_ACCENT = 96,
        GLFW_KEY_WORLD_1 = 161,
        GLFW_KEY_WORLD_2 = 162;

    public static final int
        GLFW_KEY_ESCAPE = 256,
        GLFW_KEY_ENTER = 257,
        GLFW_KEY_TAB = 258,
        GLFW_KEY_BACKSPACE = 259,
        GLFW_KEY_INSERT = 260,
        GLFW_KEY_DELETE = 261,
        GLFW_KEY_RIGHT = 262,
        GLFW_KEY_LEFT = 263,
        GLFW_KEY_DOWN = 264,
        GLFW_KEY_UP = 265,
        GLFW_KEY_PAGE_UP = 266,
        GLFW_KEY_PAGE_DOWN = 267,
        GLFW_KEY_HOME = 268,
        GLFW_KEY_END = 269,
        GLFW_KEY_CAPS_LOCK = 280,
        GLFW_KEY_SCROLL_LOCK = 281,
        GLFW_KEY_NUM_LOCK = 282,
        GLFW_KEY_PRINT_SCREEN = 283,
        GLFW_KEY_PAUSE = 284,
        GLFW_KEY_F1 = 290,
        GLFW_KEY_F2 = 291,
        GLFW_KEY_F3 = 292,
        GLFW_KEY_F4 = 293,
        GLFW_KEY_F5 = 294,
        GLFW_KEY_F6 = 295,
        GLFW_KEY_F7 = 296,
        GLFW_KEY_F8 = 297,
        GLFW_KEY_F9 = 298,
        GLFW_KEY_F10 = 299,
        GLFW_KEY_F11 = 300,
        GLFW_KEY_F12 = 301,
        GLFW_KEY_F13 = 302,
        GLFW_KEY_F14 = 303,
        GLFW_KEY_F15 = 304,
        GLFW_KEY_F16 = 305,
        GLFW_KEY_F17 = 306,
        GLFW_KEY_F18 = 307,
        GLFW_KEY_F19 = 308,
        GLFW_KEY_F20 = 309,
        GLFW_KEY_F21 = 310,
        GLFW_KEY_F22 = 311,
        GLFW_KEY_F23 = 312,
        GLFW_KEY_F24 = 313,
        GLFW_KEY_F25 = 314,
        GLFW_KEY_KP_0 = 320,
        GLFW_KEY_KP_1 = 321,
        GLFW_KEY_KP_2 = 322,
        GLFW_KEY_KP_3 = 323,
        GLFW_KEY_KP_4 = 324,
        GLFW_KEY_KP_5 = 325,
        GLFW_KEY_KP_6 = 326,
        GLFW_KEY_KP_7 = 327,
        GLFW_KEY_KP_8 = 328,
        GLFW_KEY_KP_9 = 329,
        GLFW_KEY_KP_DECIMAL = 330,
        GLFW_KEY_KP_DIVIDE = 331,
        GLFW_KEY_KP_MULTIPLY = 332,
        GLFW_KEY_KP_SUBTRACT = 333,
        GLFW_KEY_KP_ADD = 334,
        GLFW_KEY_KP_ENTER = 335,
        GLFW_KEY_KP_EQUAL = 336,
        GLFW_KEY_LEFT_SHIFT = 340,
        GLFW_KEY_LEFT_CONTROL = 341,
        GLFW_KEY_LEFT_ALT = 342,
        GLFW_KEY_LEFT_SUPER = 343,
        GLFW_KEY_RIGHT_SHIFT = 344,
        GLFW_KEY_RIGHT_CONTROL = 345,
        GLFW_KEY_RIGHT_ALT = 346,
        GLFW_KEY_RIGHT_SUPER = 347,
        GLFW_KEY_MENU = 348,
        GLFW_KEY_LAST = GLFW_KEY_MENU;

    public static final int GLFW_MOD_SHIFT = 0x0001;
    public static final int GLFW_MOD_CONTROL = 0x0002;
    public static final int GLFW_MOD_ALT = 0x0004;
    public static final int GLFW_MOD_SUPER = 0x0008;
    public static final int GLFW_MOD_CAPS_LOCK = 0x0010;
    public static final int GLFW_MOD_NUM_LOCK = 0x0020;

    public static final int
        GLFW_MOUSE_BUTTON_1 = 0,
        GLFW_MOUSE_BUTTON_2 = 1,
        GLFW_MOUSE_BUTTON_3 = 2,
        GLFW_MOUSE_BUTTON_4 = 3,
        GLFW_MOUSE_BUTTON_5 = 4,
        GLFW_MOUSE_BUTTON_6 = 5,
        GLFW_MOUSE_BUTTON_7 = 6,
        GLFW_MOUSE_BUTTON_8 = 7,
        GLFW_MOUSE_BUTTON_LAST = GLFW_MOUSE_BUTTON_8,
        GLFW_MOUSE_BUTTON_LEFT = GLFW_MOUSE_BUTTON_1,
        GLFW_MOUSE_BUTTON_RIGHT = GLFW_MOUSE_BUTTON_2,
        GLFW_MOUSE_BUTTON_MIDDLE = GLFW_MOUSE_BUTTON_3;

    public static final int
        GLFW_JOYSTICK_1 = 0,
        GLFW_JOYSTICK_2 = 1,
        GLFW_JOYSTICK_3 = 2,
        GLFW_JOYSTICK_4 = 3,
        GLFW_JOYSTICK_5 = 4,
        GLFW_JOYSTICK_6 = 5,
        GLFW_JOYSTICK_7 = 6,
        GLFW_JOYSTICK_8 = 7,
        GLFW_JOYSTICK_9 = 8,
        GLFW_JOYSTICK_10 = 9,
        GLFW_JOYSTICK_11 = 10,
        GLFW_JOYSTICK_12 = 11,
        GLFW_JOYSTICK_13 = 12,
        GLFW_JOYSTICK_14 = 13,
        GLFW_JOYSTICK_15 = 14,
        GLFW_JOYSTICK_16 = 15,
        GLFW_JOYSTICK_LAST = GLFW_JOYSTICK_16;

    public static final int
        GLFW_GAMEPAD_BUTTON_A = 0,
        GLFW_GAMEPAD_BUTTON_B = 1,
        GLFW_GAMEPAD_BUTTON_X = 2,
        GLFW_GAMEPAD_BUTTON_Y = 3,
        GLFW_GAMEPAD_BUTTON_LEFT_BUMPER = 4,
        GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER = 5,
        GLFW_GAMEPAD_BUTTON_BACK = 6,
        GLFW_GAMEPAD_BUTTON_START = 7,
        GLFW_GAMEPAD_BUTTON_GUIDE = 8,
        GLFW_GAMEPAD_BUTTON_LEFT_THUMB = 9,
        GLFW_GAMEPAD_BUTTON_RIGHT_THUMB = 10,
        GLFW_GAMEPAD_BUTTON_DPAD_UP = 11,
        GLFW_GAMEPAD_BUTTON_DPAD_RIGHT = 12,
        GLFW_GAMEPAD_BUTTON_DPAD_DOWN = 13,
        GLFW_GAMEPAD_BUTTON_DPAD_LEFT = 14,
        GLFW_GAMEPAD_BUTTON_LAST = GLFW_GAMEPAD_BUTTON_DPAD_LEFT,
        GLFW_GAMEPAD_BUTTON_CROSS = GLFW_GAMEPAD_BUTTON_A,
        GLFW_GAMEPAD_BUTTON_CIRCLE = GLFW_GAMEPAD_BUTTON_B,
        GLFW_GAMEPAD_BUTTON_SQUARE = GLFW_GAMEPAD_BUTTON_X,
        GLFW_GAMEPAD_BUTTON_TRIANGLE = GLFW_GAMEPAD_BUTTON_Y;

    public static final int
        GLFW_GAMEPAD_AXIS_LEFT_X = 0,
        GLFW_GAMEPAD_AXIS_LEFT_Y = 1,
        GLFW_GAMEPAD_AXIS_RIGHT_X = 2,
        GLFW_GAMEPAD_AXIS_RIGHT_Y = 3,
        GLFW_GAMEPAD_AXIS_LEFT_TRIGGER = 4,
        GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER = 5,
        GLFW_GAMEPAD_AXIS_LAST = GLFW_GAMEPAD_AXIS_RIGHT_TRIGGER;

    public static final int
        GLFW_NO_ERROR = 0,
        GLFW_NOT_INITIALIZED = 0x00010001,
        GLFW_NO_CURRENT_CONTEXT = 0x00010002,
        GLFW_INVALID_ENUM = 0x00010003,
        GLFW_INVALID_VALUE = 0x00010004,
        GLFW_OUT_OF_MEMORY = 0x00010005,
        GLFW_API_UNAVAILABLE = 0x00010006,
        GLFW_VERSION_UNAVAILABLE = 0x00010007,
        GLFW_PLATFORM_ERROR = 0x00010008,
        GLFW_FORMAT_UNAVAILABLE = 0x00010009,
        GLFW_NO_WINDOW_CONTEXT = 0x0001000A,
        GLFW_CURSOR_UNAVAILABLE = 0x0001000B,
        GLFW_FEATURE_UNAVAILABLE = 0x0001000C,
        GLFW_FEATURE_UNIMPLEMENTED = 0x0001000D,
        GLFW_PLATFORM_UNAVAILABLE = 0x0001000E;

    public static final int
        GLFW_FOCUSED = 0x00020001,
        GLFW_ICONIFIED = 0x00020002,
        GLFW_RESIZABLE = 0x00020003,
        GLFW_VISIBLE = 0x00020004,
        GLFW_DECORATED = 0x00020005,
        GLFW_AUTO_ICONIFY = 0x00020006,
        GLFW_FLOATING = 0x00020007,
        GLFW_MAXIMIZED = 0x00020008,
        GLFW_CENTER_CURSOR = 0x00020009,
        GLFW_TRANSPARENT_FRAMEBUFFER = 0x0002000A,
        GLFW_HOVERED = 0x0002000B,
        GLFW_FOCUS_ON_SHOW = 0x0002000C,
        GLFW_MOUSE_PASSTHROUGH = 0x0002000D,
        GLFW_POSITION_X = 0x0002000E,
        GLFW_POSITION_Y = 0x0002000F;

    public static final int
        GLFW_CURSOR = 0x00033001,
        GLFW_STICKY_KEYS = 0x00033002,
        GLFW_STICKY_MOUSE_BUTTONS = 0x00033003,
        GLFW_LOCK_KEY_MODS = 0x00033004,
        GLFW_RAW_MOUSE_MOTION = 0x00033005,
        GLFW_UNLIMITED_MOUSE_BUTTONS = 0x00033006,
        GLFW_IME = 0x00033007;

    public static final int
        GLFW_CURSOR_NORMAL = 0x00034001,
        GLFW_CURSOR_HIDDEN = 0x00034002,
        GLFW_CURSOR_DISABLED = 0x00034003,
        GLFW_CURSOR_CAPTURED = 0x00034004;

    public static final int
        GLFW_ARROW_CURSOR = 0x00036001,
        GLFW_IBEAM_CURSOR = 0x00036002,
        GLFW_CROSSHAIR_CURSOR = 0x00036003,
        GLFW_POINTING_HAND_CURSOR = 0x00036004,
        GLFW_RESIZE_EW_CURSOR = 0x00036005,
        GLFW_RESIZE_NS_CURSOR = 0x00036006,
        GLFW_RESIZE_NWSE_CURSOR = 0x00036007,
        GLFW_RESIZE_NESW_CURSOR = 0x00036008,
        GLFW_RESIZE_ALL_CURSOR = 0x00036009,
        GLFW_NOT_ALLOWED_CURSOR = 0x0003600A,
        GLFW_HRESIZE_CURSOR = GLFW_RESIZE_EW_CURSOR,
        GLFW_VRESIZE_CURSOR = GLFW_RESIZE_NS_CURSOR,
        GLFW_HAND_CURSOR = GLFW_POINTING_HAND_CURSOR;

    public static final int
        GLFW_CONNECTED = 0x00040001,
        GLFW_DISCONNECTED = 0x00040002;

    public static final int
        GLFW_JOYSTICK_HAT_BUTTONS = 0x00050001,
        GLFW_ANGLE_PLATFORM_TYPE = 0x00050002,
        GLFW_PLATFORM = 0x00050003,
        GLFW_COCOA_CHDIR_RESOURCES = 0x00051001,
        GLFW_COCOA_MENUBAR = 0x00051002,
        GLFW_X11_XCB_VULKAN_SURFACE = 0x00052001,
        GLFW_WAYLAND_LIBDECOR = 0x00053001;

    public static final int GLFW_ANY_POSITION = 0x80000000;

    public static final int
        GLFW_ANY_PLATFORM = 0x00060000,
        GLFW_PLATFORM_WIN32 = 0x00060001,
        GLFW_PLATFORM_COCOA = 0x00060002,
        GLFW_PLATFORM_WAYLAND = 0x00060003,
        GLFW_PLATFORM_X11 = 0x00060004,
        GLFW_PLATFORM_NULL = 0x00060005;

    public static final int GLFW_DONT_CARE = -1;

    public static final int
        GLFW_RED_BITS = 0x00021001,
        GLFW_GREEN_BITS = 0x00021002,
        GLFW_BLUE_BITS = 0x00021003,
        GLFW_ALPHA_BITS = 0x00021004,
        GLFW_DEPTH_BITS = 0x00021005,
        GLFW_STENCIL_BITS = 0x00021006,
        GLFW_ACCUM_RED_BITS = 0x00021007,
        GLFW_ACCUM_GREEN_BITS = 0x00021008,
        GLFW_ACCUM_BLUE_BITS = 0x00021009,
        GLFW_ACCUM_ALPHA_BITS = 0x0002100A,
        GLFW_AUX_BUFFERS = 0x0002100B,
        GLFW_STEREO = 0x0002100C,
        GLFW_SAMPLES = 0x0002100D,
        GLFW_SRGB_CAPABLE = 0x0002100E,
        GLFW_REFRESH_RATE = 0x0002100F,
        GLFW_DOUBLEBUFFER = 0x00021010;

    public static final int
        GLFW_CLIENT_API = 0x00022001,
        GLFW_CONTEXT_VERSION_MAJOR = 0x00022002,
        GLFW_CONTEXT_VERSION_MINOR = 0x00022003,
        GLFW_CONTEXT_REVISION = 0x00022004,
        GLFW_CONTEXT_ROBUSTNESS = 0x00022005,
        GLFW_OPENGL_FORWARD_COMPAT = 0x00022006,
        GLFW_OPENGL_DEBUG_CONTEXT = 0x00022007,
        GLFW_CONTEXT_DEBUG = GLFW_OPENGL_DEBUG_CONTEXT,
        GLFW_OPENGL_PROFILE = 0x00022008,
        GLFW_CONTEXT_RELEASE_BEHAVIOR = 0x00022009,
        GLFW_CONTEXT_NO_ERROR = 0x0002200A,
        GLFW_CONTEXT_CREATION_API = 0x0002200B,
        GLFW_SCALE_TO_MONITOR = 0x0002200C;

    public static final int GLFW_COCOA_RETINA_FRAMEBUFFER = 0x00023001;
    public static final int GLFW_COCOA_FRAME_NAME = 0x00023002;
    public static final int GLFW_COCOA_GRAPHICS_SWITCHING = 0x00023003;

    public static final int
        GLFW_X11_CLASS_NAME = 0x00024001,
        GLFW_X11_INSTANCE_NAME = 0x00024002;

    public static final int GLFW_WIN32_KEYBOARD_MENU = 0x00025001;
    public static final int GLFW_WAYLAND_APP_ID = 0x00026001;

    public static final int
        GLFW_NO_API = 0,
        GLFW_OPENGL_API = 0x00030001,
        GLFW_OPENGL_ES_API = 0x00030002;

    public static final int
        GLFW_NO_ROBUSTNESS = 0,
        GLFW_NO_RESET_NOTIFICATION = 0x00031001,
        GLFW_LOSE_CONTEXT_ON_RESET = 0x00031002;

    public static final int
        GLFW_OPENGL_ANY_PROFILE = 0,
        GLFW_OPENGL_CORE_PROFILE = 0x00032001,
        GLFW_OPENGL_COMPAT_PROFILE = 0x00032002;

    public static final int
        GLFW_ANY_RELEASE_BEHAVIOR = 0,
        GLFW_RELEASE_BEHAVIOR_FLUSH = 0x00035001,
        GLFW_RELEASE_BEHAVIOR_NONE = 0x00035002;

    public static final int
        GLFW_NATIVE_CONTEXT_API = 0x00036001,
        GLFW_EGL_CONTEXT_API = 0x00036002,
        GLFW_OSMESA_CONTEXT_API = 0x00036003;

    public static final int
        GLFW_ANGLE_PLATFORM_TYPE_NONE = 0x00037001,
        GLFW_ANGLE_PLATFORM_TYPE_OPENGL = 0x00037002,
        GLFW_ANGLE_PLATFORM_TYPE_OPENGLES = 0x00037003,
        GLFW_ANGLE_PLATFORM_TYPE_D3D9 = 0x00037004,
        GLFW_ANGLE_PLATFORM_TYPE_D3D11 = 0x00037005,
        GLFW_ANGLE_PLATFORM_TYPE_VULKAN = 0x00037007,
        GLFW_ANGLE_PLATFORM_TYPE_METAL = 0x00037008;

    public static final int
        GLFW_WAYLAND_PREFER_LIBDECOR = 0x00038001,
        GLFW_WAYLAND_DISABLE_LIBDECOR = 0x00038002;

    public static final ByteBuffer keyDownBuffer = ByteBuffer.allocateDirect(317);
    public static final ByteBuffer mouseDownBuffer = ByteBuffer.allocateDirect(8);

    public static GLFWCharCallback mGLFWCharCallback;
    public static GLFWCharModsCallback mGLFWCharModsCallback;
    public static GLFWCursorEnterCallback mGLFWCursorEnterCallback;
    public static GLFWCursorPosCallback mGLFWCursorPosCallback;
    public static GLFWDropCallback mGLFWDropCallback;
    public static GLFWErrorCallback mGLFWErrorCallback;
    public static GLFWJoystickCallback mGLFWJoystickCallback;
    public static GLFWKeyCallback mGLFWKeyCallback;
    public static GLFWMonitorCallback mGLFWMonitorCallback;
    public static GLFWMouseButtonCallback mGLFWMouseButtonCallback;
    public static GLFWScrollCallback mGLFWScrollCallback;
    public static GLFWWindowCloseCallback mGLFWWindowCloseCallback;
    public static GLFWWindowContentScaleCallback mGLFWWindowContentScaleCallback;
    public static GLFWWindowFocusCallback mGLFWWindowFocusCallback;
    public static GLFWWindowIconifyCallback mGLFWWindowIconifyCallback;
    public static GLFWWindowMaximizeCallback mGLFWWindowMaximizeCallback;
    public static GLFWWindowPosCallback mGLFWWindowPosCallback;
    public static GLFWWindowRefreshCallback mGLFWWindowRefreshCallback;

    public static GLFWFramebufferSizeCallbackI mGLFWFramebufferSizeCallbackI;
    public static GLFWWindowSizeCallbackI mGLFWWindowSizeCallbackI;

    public static volatile int mGLFWWindowWidth;
    public static volatile int mGLFWWindowHeight;

    public static boolean mGLFWIsInputReady;
    public static long mainContext;

    private static GLFWGammaRamp mGLFWGammaRamp;
    private static GLFWVidMode mGLFWVideoMode;
    private static Map<Integer, String> mGLFWKeyCodes;
    private static long mGLFWWindowMonitor;
    private static double mGLFWInitialTime;
    private static float mGLFWContentScale = 1.0f;
    private static boolean mGLFWInputPumping;
    private static boolean mGLFWWindowVisibleOnCreation = true;
    private static int mGLFWContextVersionMajor = 3;
    private static int mGLFWContextVersionMinor = 3;
    private static int mGLFWOpenGLProfile = GLFW_OPENGL_ANY_PROFILE;
    private static long mGLFWGamepadDataPointer;
    private static FloatBuffer mGLFWJoystickAxes;
    private static ByteBuffer mGLFWJoystickButtons;
    private static ByteBuffer mGLFWJoystickHats = ByteBuffer.allocateDirect(0);
    private static boolean mGLFWReady;
    private static GLFWPreeditCallback mGLFWPreeditCallback;
    private static GLFWIMEStatusCallback mGLFWIMEStatusCallback;

    private static final Map<Long, GLFWWindowProperties> mGLFWWindowMap = new java.util.HashMap<>();
    private static final SharedLibrary LIBRARY;

    private static native void nativeInitializeGLFWNativeBridge();

    private static native long nglfwSetCharCallback(long window, long callback);
    private static native long nglfwSetCharModsCallback(long window, long callback);
    private static native long nglfwSetCursorEnterCallback(long window, long callback);
    private static native long nglfwSetCursorPosCallback(long window, long callback);
    private static native long nglfwSetKeyCallback(long window, long callback);
    private static native long nglfwSetMouseButtonCallback(long window, long callback);
    private static native long nglfwSetScrollCallback(long window, long callback);
    private static native void nglfwSetShowingWindow(long window);
    private static native long internalGetGamepadDataPointer();

    public static native void nglfwGetCursorPos(long window, DoubleBuffer xpos, DoubleBuffer ypos);
    public static native void nglfwGetCursorPosA(long window, double[] xpos, double[] ypos);
    public static native void glfwSetCursorPos(long window, double xpos, double ypos);

    static {
        System.loadLibrary("meowcraftbridge");
        nativeInitializeGLFWNativeBridge();
        LIBRARY = Library.loadNative(GLFW.class, "org.lwjgl.glfw", "libmeowcraftbridge.so", true);

        mGLFWInitialTime = System.nanoTime();
        mGLFWErrorCallback = GLFWErrorCallback.createPrint();
        mGLFWKeyCodes = new HashMap<>();
        mGLFWContentScale = CallbackBridge.nativeGetAndroidDPI();

        for (Field field : GLFW.class.getFields()) {
            String name = field.getName();
            if (!name.startsWith("GLFW_KEY_") || name.length() <= 9) {
                continue;
            }
            try {
                String label = name.substring(9, 10).toUpperCase(Locale.US)
                        + name.substring(10).replace('_', ' ').toLowerCase(Locale.US);
                mGLFWKeyCodes.put(field.getInt(null), label);
            } catch (IllegalAccessException ignored) {
            }
        }

        mGLFWVideoMode = new GLFWVidMode(ByteBuffer.allocateDirect(GLFWVidMode.SIZEOF));
        writeVideoModeSize(mGLFWWindowWidth, mGLFWWindowHeight);
    }

    protected GLFW() {
        throw new UnsupportedOperationException();
    }

    public static SharedLibrary getLibrary() {
        return LIBRARY;
    }

    public static final class Functions {

        private Functions() {
        }

        public static final long
            Init = apiGetFunctionAddress(LIBRARY, "meowInit"),
            CreateContext = apiGetFunctionAddress(LIBRARY, "meowCreateContext"),
            GetCurrentContext = apiGetFunctionAddress(LIBRARY, "meowGetCurrentContext"),
            MakeContextCurrent = apiGetFunctionAddress(LIBRARY, "meowMakeCurrent"),
            Terminate = apiGetFunctionAddress(LIBRARY, "meowTerminate"),
            SetWindowHint = apiGetFunctionAddress(LIBRARY, "meowSetWindowHint"),
            SwapBuffers = apiGetFunctionAddress(LIBRARY, "meowSwapBuffers"),
            SwapInterval = apiGetFunctionAddress(LIBRARY, "meowSwapInterval"),
            PumpEvents = apiGetFunctionAddress(LIBRARY, "meowPumpEvents"),
            StartPumping = apiGetFunctionAddress(LIBRARY, "meowStartPumping"),
            StopPumping = apiGetFunctionAddress(LIBRARY, "meowStopPumping");

    }

    private static void writeVideoModeSize(int width, int height) {
        if (mGLFWVideoMode == null) {
            return;
        }
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.WIDTH, width);
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.HEIGHT, height);
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.REDBITS, 8);
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.GREENBITS, 8);
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.BLUEBITS, 8);
        memPutInt(mGLFWVideoMode.address() + GLFWVidMode.REFRESHRATE, 60);
    }

    public static GLFWWindowProperties internalGetWindow(long window) {
        GLFWWindowProperties properties = mGLFWWindowMap.get(window);
        if (properties == null) {
            throw new IllegalArgumentException("No window pointer found: " + window);
        }
        return properties;
    }

    @SuppressWarnings("unused")
    public static void internalChangeMonitorSize(int width, int height) {
        mGLFWWindowWidth = width;
        mGLFWWindowHeight = height;
        writeVideoModeSize(width, height);
    }

    @SuppressWarnings("unused")
    public static void internalWindowSizeChanged(long window, int width, int height) {
        try {
            mGLFWWindowWidth = width;
            mGLFWWindowHeight = height;
            GLFWWindowProperties properties = mGLFWWindowMap.get(window);
            if (properties != null) {
                properties.width = width;
                properties.height = height;
            }
            writeVideoModeSize(width, height);
            if (mGLFWFramebufferSizeCallbackI != null) {
                mGLFWFramebufferSizeCallbackI.invoke(window, width, height);
            }
            if (mGLFWWindowSizeCallbackI != null) {
                mGLFWWindowSizeCallbackI.invoke(window, width, height);
            }
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }

    @SuppressWarnings("unused")
    public static void internalWindowSizeChanged(long window) {
        internalWindowSizeChanged(window, mGLFWWindowWidth, mGLFWWindowHeight);
    }

    public static boolean glfwInit() {
        if (!mGLFWReady) {
            mGLFWInitialTime = System.nanoTime();
            mGLFWReady = invokeI(Functions.Init) != 0;
            mGLFWGamepadDataPointer = internalGetGamepadDataPointer();
            mGLFWJoystickAxes = CallbackBridge.nativeCreateGamepadAxisBuffer()
                    .order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer();
            mGLFWJoystickButtons = CallbackBridge.nativeCreateGamepadButtonBuffer();
        }
        return mGLFWReady;
    }

    public static void glfwTerminate() {
        mGLFWIsInputReady = false;
        CallbackBridge.nativeSetInputReady(false);
        invokeV(Functions.Terminate);
        mGLFWReady = false;
    }

    public static void glfwInitHint(int hint, int value) {
    }

    public static void glfwInitAllocator(GLFWAllocator allocator) {
    }

    public static int glfwGetPlatform() {
        return GLFW_PLATFORM_X11;
    }

    public static boolean glfwPlatformSupported(int platform) {
        return platform == GLFW_PLATFORM_X11;
    }

    public static void glfwGetVersion(IntBuffer major, IntBuffer minor, IntBuffer rev) {
        if (major != null) {
            major.put(GLFW_VERSION_MAJOR);
        }
        if (minor != null) {
            minor.put(GLFW_VERSION_MINOR);
        }
        if (rev != null) {
            rev.put(GLFW_VERSION_REVISION);
        }
    }

    public static void glfwGetVersion(int[] major, int[] minor, int[] rev) {
        if (major != null && major.length > 0) {
            major[0] = GLFW_VERSION_MAJOR;
        }
        if (minor != null && minor.length > 0) {
            minor[0] = GLFW_VERSION_MINOR;
        }
        if (rev != null && rev.length > 0) {
            rev[0] = GLFW_VERSION_REVISION;
        }
    }

    public static String glfwGetVersionString() {
        return GLFW_VERSION_MAJOR + "." + GLFW_VERSION_MINOR + "." + GLFW_VERSION_REVISION;
    }

    public static int glfwGetError(PointerBuffer description) {
        return GLFW_NO_ERROR;
    }

    public static long glfwGetCurrentContext() {
        return invokeP(Functions.GetCurrentContext);
    }

    public static void glfwMakeContextCurrent(long window) {
        invokePV(window, Functions.MakeContextCurrent);
    }

    public static void glfwSwapBuffers(long window) {
        invokePV(window, Functions.SwapBuffers);
    }

    public static void glfwSwapInterval(int interval) {
        invokeV(interval, Functions.SwapInterval);
    }

    public static double glfwGetTime() {
        return (System.nanoTime() - mGLFWInitialTime) / 1.0e9;
    }

    public static void glfwSetTime(double time) {
        mGLFWInitialTime = System.nanoTime() - (long) (time * 1.0e9);
    }

    public static long glfwGetTimerValue() {
        return System.nanoTime();
    }

    public static long glfwGetTimerFrequency() {
        return 1000000000L;
    }

    public static long nglfwCreateContext(long share) {
        return invokePP(share, Functions.CreateContext);
    }

    public static long glfwCreateWindow(int width, int height, CharSequence title, long monitor,
            long share) {
        long window = nglfwCreateContext(share);

        GLFWWindowProperties properties = new GLFWWindowProperties();
        properties.width = width > 0 ? width : mGLFWWindowWidth;
        properties.height = height > 0 ? height : mGLFWWindowHeight;
        properties.title = title;
        properties.windowAttribs.put(GLFW_RESIZABLE, GLFW_FALSE);
        properties.windowAttribs.put(GLFW_VISIBLE,
                mGLFWWindowVisibleOnCreation ? GLFW_TRUE : GLFW_FALSE);
        properties.windowAttribs.put(GLFW_HOVERED, GLFW_TRUE);
        properties.windowAttribs.put(GLFW_FOCUSED, GLFW_TRUE);
        properties.windowAttribs.put(GLFW_CONTEXT_VERSION_MAJOR, mGLFWContextVersionMajor);
        properties.windowAttribs.put(GLFW_CONTEXT_VERSION_MINOR, mGLFWContextVersionMinor);
        properties.windowAttribs.put(GLFW_OPENGL_PROFILE, mGLFWOpenGLProfile);
        properties.inputModes.put(GLFW_CURSOR, GLFW_CURSOR_NORMAL);
        properties.inputModes.put(GLFW_STICKY_KEYS, GLFW_FALSE);
        properties.inputModes.put(GLFW_STICKY_MOUSE_BUTTONS, GLFW_FALSE);
        properties.inputModes.put(GLFW_IME, GLFW_FALSE);

        if (mGLFWWindowWidth <= 0) {
            mGLFWWindowWidth = properties.width;
        }
        if (mGLFWWindowHeight <= 0) {
            mGLFWWindowHeight = properties.height;
        }
        writeVideoModeSize(mGLFWWindowWidth, mGLFWWindowHeight);

        mGLFWWindowMap.put(window, properties);
        mainContext = window;

        if (mGLFWWindowVisibleOnCreation || monitor != 0L) {
            glfwShowWindow(window);
        }
        return window;
    }

    public static void glfwDestroyWindow(long window) {
        if (mGLFWWindowMap.remove(window) == null) {
            System.err.println("GLFW: warning: failed to remove window " + window);
        }
        long last = 0L;
        for (Long key : mGLFWWindowMap.keySet()) {
            last = key;
        }
        nglfwSetShowingWindow(last);
        if (mainContext == window) {
            mainContext = 0L;
        }
    }

    public static void glfwDefaultWindowHints() {
        mGLFWWindowVisibleOnCreation = true;
        mGLFWContextVersionMajor = 3;
        mGLFWContextVersionMinor = 3;
        mGLFWOpenGLProfile = GLFW_OPENGL_ANY_PROFILE;
    }

    public static void glfwWindowHint(int hint, int value) {
        if (hint == GLFW_VISIBLE) {
            mGLFWWindowVisibleOnCreation = value == GLFW_TRUE;
            return;
        }
        if (hint == GLFW_CONTEXT_VERSION_MAJOR) {
            mGLFWContextVersionMajor = value;
            return;
        }
        if (hint == GLFW_CONTEXT_VERSION_MINOR) {
            mGLFWContextVersionMinor = value;
            return;
        }
        if (hint == GLFW_OPENGL_PROFILE) {
            mGLFWOpenGLProfile = value;
            return;
        }
        invokeV(hint, value, Functions.SetWindowHint);
    }

    public static void glfwWindowHintString(int hint, ByteBuffer value) {
    }

    public static void glfwWindowHintString(int hint, CharSequence value) {
    }

    public static void glfwPollEvents() {
        if (!mGLFWIsInputReady) {
            mGLFWIsInputReady = true;
            CallbackBridge.nativeSetInputReady(true);
        }
        if (mGLFWInputPumping) {
            return;
        }
        mGLFWInputPumping = true;
        invokeV(Functions.StartPumping);
        for (Long window : mGLFWWindowMap.keySet()) {
            invokePV(window, Functions.PumpEvents);
        }
        invokeV(Functions.StopPumping);
        mGLFWInputPumping = false;
    }

    public static void glfwWaitEvents() {
    }

    public static void glfwWaitEventsTimeout(double timeout) {
    }

    public static void glfwPostEmptyEvent() {
    }

    public static void glfwShowWindow(long window) {
        GLFWWindowProperties properties = internalGetWindow(window);
        properties.windowAttribs.put(GLFW_HOVERED, GLFW_TRUE);
        properties.windowAttribs.put(GLFW_VISIBLE, GLFW_TRUE);
        nglfwSetShowingWindow(window);
    }

    public static void glfwHideWindow(long window) {
        GLFWWindowProperties properties = internalGetWindow(window);
        properties.windowAttribs.put(GLFW_HOVERED, GLFW_FALSE);
        properties.windowAttribs.put(GLFW_VISIBLE, GLFW_FALSE);
    }

    public static boolean glfwWindowShouldClose(long window) {
        return internalGetWindow(window).shouldClose;
    }

    public static void glfwSetWindowShouldClose(long window, boolean close) {
        GLFWWindowProperties properties = mGLFWWindowMap.get(window);
        if (properties != null) {
            properties.shouldClose = close;
        }
    }

    public static void glfwSetWindowTitle(long window, ByteBuffer title) {
    }

    public static void glfwSetWindowTitle(long window, CharSequence title) {
        internalGetWindow(window).title = title;
    }

    public static void glfwSetWindowIcon(long window, GLFWImage.Buffer images) {
    }

    public static void glfwGetWindowPos(long window, IntBuffer xpos, IntBuffer ypos) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (xpos != null) {
            xpos.put(properties.x);
        }
        if (ypos != null) {
            ypos.put(properties.y);
        }
    }

    public static void glfwGetWindowPos(long window, int[] xpos, int[] ypos) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (xpos != null && xpos.length > 0) {
            xpos[0] = properties.x;
        }
        if (ypos != null && ypos.length > 0) {
            ypos[0] = properties.y;
        }
    }

    public static void glfwSetWindowPos(long window, int xpos, int ypos) {
        GLFWWindowProperties properties = internalGetWindow(window);
        properties.x = xpos;
        properties.y = ypos;
    }

    public static void glfwGetWindowSize(long window, IntBuffer width, IntBuffer height) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (width != null) {
            width.put(properties.width);
        }
        if (height != null) {
            height.put(properties.height);
        }
    }

    public static void glfwGetWindowSize(long window, int[] width, int[] height) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (width != null && width.length > 0) {
            width[0] = properties.width;
        }
        if (height != null && height.length > 0) {
            height[0] = properties.height;
        }
    }

    public static void glfwSetWindowSize(long window, int width, int height) {
        GLFWWindowProperties properties = internalGetWindow(window);
        properties.width = width;
        properties.height = height;
        System.out.println("GLFW: set size for window " + window + ", width=" + width
                + ", height=" + height);
    }

    public static void glfwSetWindowSizeLimits(long window, int minwidth, int minheight,
            int maxwidth, int maxheight) {
    }

    public static void glfwSetWindowAspectRatio(long window, int numerator, int denominator) {
    }

    public static void glfwGetFramebufferSize(long window, IntBuffer width, IntBuffer height) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (width != null) {
            width.put(properties.width);
        }
        if (height != null) {
            height.put(properties.height);
        }
    }

    public static void glfwGetFramebufferSize(long window, int[] width, int[] height) {
        GLFWWindowProperties properties = internalGetWindow(window);
        if (width != null && width.length > 0) {
            width[0] = properties.width;
        }
        if (height != null && height.length > 0) {
            height[0] = properties.height;
        }
    }

    public static void glfwGetWindowFrameSize(long window, IntBuffer left, IntBuffer top,
            IntBuffer right, IntBuffer bottom) {
        if (left != null) {
            left.put(0);
        }
        if (top != null) {
            top.put(0);
        }
        if (right != null) {
            right.put(0);
        }
        if (bottom != null) {
            bottom.put(0);
        }
    }

    public static void glfwGetWindowFrameSize(long window, int[] left, int[] top, int[] right,
            int[] bottom) {
        if (left != null && left.length > 0) {
            left[0] = 0;
        }
        if (top != null && top.length > 0) {
            top[0] = 0;
        }
        if (right != null && right.length > 0) {
            right[0] = 0;
        }
        if (bottom != null && bottom.length > 0) {
            bottom[0] = 0;
        }
    }

    public static void glfwGetWindowContentScale(long window, FloatBuffer xscale,
            FloatBuffer yscale) {
        if (xscale != null) {
            xscale.put(mGLFWContentScale);
        }
        if (yscale != null) {
            yscale.put(mGLFWContentScale);
        }
    }

    public static void glfwGetWindowContentScale(long window, float[] xscale, float[] yscale) {
        if (xscale != null) {
            Arrays.fill(xscale, mGLFWContentScale);
        }
        if (yscale != null) {
            Arrays.fill(yscale, mGLFWContentScale);
        }
    }

    public static float glfwGetWindowOpacity(long window) {
        return 1.0f;
    }

    public static void glfwSetWindowOpacity(long window, float opacity) {
    }

    public static void glfwIconifyWindow(long window) {
    }

    public static void glfwRestoreWindow(long window) {
    }

    public static void glfwMaximizeWindow(long window) {
    }

    public static void glfwFocusWindow(long window) {
    }

    public static void glfwRequestWindowAttention(long window) {
    }

    public static int glfwGetWindowAttrib(long window, int attrib) {
        Integer value = internalGetWindow(window).windowAttribs.get(attrib);
        return value != null ? value : 0;
    }

    public static void glfwSetWindowAttrib(long window, int attrib, int value) {
        internalGetWindow(window).windowAttribs.put(attrib, value);
    }

    public static void glfwSetWindowUserPointer(long window, long pointer) {
    }

    public static long glfwGetWindowUserPointer(long window) {
        return 0L;
    }

    public static void glfwSetWindowMonitor(long window, long monitor, int xpos, int ypos,
            int width, int height, int refreshRate) {
        // No real GLFW window: monitor 0 = windowed, non-zero = fullscreen (see
        // glfwGetWindowMonitor). Forward the toggle to the launcher (native -> ArkTS),
        // which owns and resizes the real OS window; pass the requested rect so it can
        // restore the windowed geometry on exit.
        mGLFWWindowMonitor = monitor != 0L ? 1L : 0L;
        CallbackBridge.nativeSetFullscreen(monitor != 0L, xpos, ypos, width, height);
    }

    public static long glfwGetWindowMonitor(long window) {
        return mGLFWWindowMonitor;
    }

    public static PointerBuffer glfwGetMonitors() {
        PointerBuffer monitors = PointerBuffer.allocateDirect(1);
        monitors.put(glfwGetPrimaryMonitor());
        return monitors;
    }

    public static long glfwGetPrimaryMonitor() {
        return 1L;
    }

    public static void glfwGetMonitorPos(long monitor, IntBuffer xpos, IntBuffer ypos) {
        if (xpos != null) {
            xpos.put(0);
        }
        if (ypos != null) {
            ypos.put(0);
        }
    }

    public static void glfwGetMonitorPos(long monitor, int[] xpos, int[] ypos) {
        if (xpos != null && xpos.length > 0) {
            xpos[0] = 0;
        }
        if (ypos != null && ypos.length > 0) {
            ypos[0] = 0;
        }
    }

    public static void glfwGetMonitorWorkarea(long monitor, IntBuffer xpos, IntBuffer ypos,
            IntBuffer width, IntBuffer height) {
        if (xpos != null) {
            xpos.put(0);
        }
        if (ypos != null) {
            ypos.put(0);
        }
        if (width != null) {
            width.put(mGLFWWindowWidth);
        }
        if (height != null) {
            height.put(mGLFWWindowHeight);
        }
    }

    public static void glfwGetMonitorWorkarea(long monitor, int[] xpos, int[] ypos, int[] width,
            int[] height) {
        if (xpos != null && xpos.length > 0) {
            xpos[0] = 0;
        }
        if (ypos != null && ypos.length > 0) {
            ypos[0] = 0;
        }
        if (width != null && width.length > 0) {
            width[0] = mGLFWWindowWidth;
        }
        if (height != null && height.length > 0) {
            height[0] = mGLFWWindowHeight;
        }
    }

    public static void glfwGetMonitorPhysicalSize(long monitor, IntBuffer widthMM,
            IntBuffer heightMM) {
        if (widthMM != null) {
            widthMM.put(mGLFWWindowWidth);
        }
        if (heightMM != null) {
            heightMM.put(mGLFWWindowHeight);
        }
    }

    public static void glfwGetMonitorPhysicalSize(long monitor, int[] widthMM, int[] heightMM) {
        if (widthMM != null && widthMM.length > 0) {
            widthMM[0] = mGLFWWindowWidth;
        }
        if (heightMM != null && heightMM.length > 0) {
            heightMM[0] = mGLFWWindowHeight;
        }
    }

    public static void glfwGetMonitorContentScale(long monitor, FloatBuffer xscale,
            FloatBuffer yscale) {
        if (xscale != null) {
            xscale.put(0, mGLFWContentScale);
        }
        if (yscale != null) {
            yscale.put(0, mGLFWContentScale);
        }
    }

    public static void glfwGetMonitorContentScale(long monitor, float[] xscale, float[] yscale) {
        if (xscale != null && xscale.length > 0) {
            xscale[0] = mGLFWContentScale;
        }
        if (yscale != null && yscale.length > 0) {
            yscale[0] = mGLFWContentScale;
        }
    }

    public static String glfwGetMonitorName(long monitor) {
        return String.format(Locale.US, "Meowcraft Display (%dx%d)", mGLFWWindowWidth,
                mGLFWWindowHeight);
    }

    public static void glfwSetMonitorUserPointer(long monitor, long pointer) {
    }

    public static long glfwGetMonitorUserPointer(long monitor) {
        return 0L;
    }

    public static GLFWVidMode.Buffer glfwGetVideoModes(long monitor) {
        GLFWVidMode mode = glfwGetVideoMode(monitor);
        return mode == null ? null : GLFWVidMode.create(mode.address(), 1);
    }

    public static GLFWVidMode glfwGetVideoMode(long monitor) {
        return mGLFWVideoMode;
    }

    public static GLFWGammaRamp glfwGetGammaRamp(long monitor) {
        return mGLFWGammaRamp;
    }

    public static void glfwSetGamma(long monitor, float gamma) {
    }

    public static void glfwSetGammaRamp(long monitor, GLFWGammaRamp ramp) {
        mGLFWGammaRamp = ramp;
    }

    public static int glfwGetInputMode(long window, int mode) {
        Integer value = internalGetWindow(window).inputModes.get(mode);
        return value != null ? value : 0;
    }

    public static void glfwSetInputMode(long window, int mode, int value) {
        if (mode == GLFW_CURSOR) {
            if (value == GLFW_CURSOR_DISABLED) {
                CallbackBridge.nativeSetGrabbing(true);
            } else {
                CallbackBridge.nativeSetGrabbing(false);
            }
        }
        internalGetWindow(window).inputModes.put(mode, value);
    }

    public static String glfwGetKeyName(int key, int scancode) {
        return mGLFWKeyCodes.get(key);
    }

    public static int glfwGetKeyScancode(int key) {
        return 0;
    }

    public static int glfwGetKey(long window, int key) {
        if (key < 0) {
            return GLFW_RELEASE;
        }
        int index = key - 31;
        if (index < 0 || index >= keyDownBuffer.capacity()) {
            return GLFW_RELEASE;
        }
        return keyDownBuffer.get(index) != 0 ? GLFW_PRESS : GLFW_RELEASE;
    }

    public static int glfwGetMouseButton(long window, int button) {
        if (button < 0 || button >= mouseDownBuffer.capacity()) {
            return GLFW_RELEASE;
        }
        return mouseDownBuffer.get(button) != 0 ? GLFW_PRESS : GLFW_RELEASE;
    }

    public static void glfwGetCursorPos(long window, DoubleBuffer xpos, DoubleBuffer ypos) {
        if (CHECKS) {
            checkSafe(xpos, 1);
            checkSafe(ypos, 1);
        }
        nglfwGetCursorPos(window, xpos, ypos);
    }

    public static void glfwGetCursorPos(long window, double[] xpos, double[] ypos) {
        if (CHECKS) {
            checkSafe(xpos, 1);
            checkSafe(ypos, 1);
        }
        nglfwGetCursorPosA(window, xpos, ypos);
    }

    public static long glfwCreateCursor(GLFWImage image, int xhot, int yhot) {
        return 4L;
    }

    public static long glfwCreateStandardCursor(int shape) {
        return 4L;
    }

    public static void glfwDestroyCursor(long cursor) {
    }

    public static void glfwSetCursor(long window, long cursor) {
    }

    public static boolean glfwRawMouseMotionSupported() {
        return false;
    }

    public static void glfwSetClipboardString(long window, ByteBuffer string) {
        byte[] bytes = new byte[string.remaining()];
        string.get(bytes);
        CallbackBridge.nativeClipboard(CallbackBridge.CLIPBOARD_COPY, bytes);
    }

    public static void glfwSetClipboardString(long window, CharSequence string) {
        glfwSetClipboardString(window, memUTF8Safe(string));
    }

    public static String glfwGetClipboardString(long window) {
        return CallbackBridge.nativeClipboard(CallbackBridge.CLIPBOARD_PASTE, null);
    }

    public static boolean glfwExtensionSupported(CharSequence extension) {
        return false;
    }

    public static boolean glfwExtensionSupported(ByteBuffer extension) {
        return false;
    }

    public static long glfwGetProcAddress(ByteBuffer procname) {
        throw new UnsupportedOperationException("Unimplemented!");
    }

    public static long glfwGetProcAddress(CharSequence procname) {
        throw new UnsupportedOperationException("Unimplemented!");
    }

    public static GLFWCharCallback glfwSetCharCallback(long window, GLFWCharCallbackI cbfun) {
        GLFWCharCallback previous = mGLFWCharCallback;
        long address = nglfwSetCharCallback(window, memAddressSafe(cbfun));
        mGLFWCharCallback = cbfun == null ? null : GLFWCharCallback.createSafe(address);
        return previous;
    }

    public static GLFWCharModsCallback glfwSetCharModsCallback(long window,
            GLFWCharModsCallbackI cbfun) {
        GLFWCharModsCallback previous = mGLFWCharModsCallback;
        long address = nglfwSetCharModsCallback(window, memAddressSafe(cbfun));
        mGLFWCharModsCallback = cbfun == null ? null : GLFWCharModsCallback.createSafe(address);
        return previous;
    }

    public static GLFWCursorEnterCallback glfwSetCursorEnterCallback(long window,
            GLFWCursorEnterCallbackI cbfun) {
        GLFWCursorEnterCallback previous = mGLFWCursorEnterCallback;
        long address = nglfwSetCursorEnterCallback(window, memAddressSafe(cbfun));
        mGLFWCursorEnterCallback = cbfun == null ? null
                : GLFWCursorEnterCallback.createSafe(address);
        return previous;
    }

    public static GLFWCursorPosCallback glfwSetCursorPosCallback(long window,
            GLFWCursorPosCallbackI cbfun) {
        GLFWCursorPosCallback previous = mGLFWCursorPosCallback;
        long address = nglfwSetCursorPosCallback(window, memAddressSafe(cbfun));
        mGLFWCursorPosCallback = cbfun == null ? null
                : GLFWCursorPosCallback.createSafe(address);
        return previous;
    }

    public static GLFWDropCallback glfwSetDropCallback(long window, GLFWDropCallbackI cbfun) {
        GLFWDropCallback previous = mGLFWDropCallback;
        mGLFWDropCallback = cbfun == null ? null : GLFWDropCallback.create(cbfun);
        return previous;
    }

    public static GLFWErrorCallback glfwSetErrorCallback(GLFWErrorCallbackI cbfun) {
        GLFWErrorCallback previous = mGLFWErrorCallback;
        mGLFWErrorCallback = cbfun == null ? null : GLFWErrorCallback.create(cbfun);
        return previous;
    }

    public static GLFWFramebufferSizeCallback glfwSetFramebufferSizeCallback(long window,
            GLFWFramebufferSizeCallbackI cbfun) {
        GLFWFramebufferSizeCallback previous = null;
        if (mGLFWFramebufferSizeCallbackI != null) {
            previous = GLFWFramebufferSizeCallback.create(mGLFWFramebufferSizeCallbackI);
        }
        mGLFWFramebufferSizeCallbackI = cbfun;
        return previous;
    }

    public static GLFWJoystickCallback glfwSetJoystickCallback(GLFWJoystickCallbackI cbfun) {
        GLFWJoystickCallback previous = mGLFWJoystickCallback;
        mGLFWJoystickCallback = cbfun == null ? null : GLFWJoystickCallback.create(cbfun);
        return previous;
    }

    public static GLFWKeyCallback glfwSetKeyCallback(long window, GLFWKeyCallbackI cbfun) {
        GLFWKeyCallback previous = mGLFWKeyCallback;
        long address = nglfwSetKeyCallback(window, memAddressSafe(cbfun));
        mGLFWKeyCallback = cbfun == null ? null : GLFWKeyCallback.createSafe(address);
        return previous;
    }

    public static GLFWMonitorCallback glfwSetMonitorCallback(GLFWMonitorCallbackI cbfun) {
        GLFWMonitorCallback previous = mGLFWMonitorCallback;
        mGLFWMonitorCallback = cbfun == null ? null : GLFWMonitorCallback.create(cbfun);
        return previous;
    }

    public static GLFWMouseButtonCallback glfwSetMouseButtonCallback(long window,
            GLFWMouseButtonCallbackI cbfun) {
        GLFWMouseButtonCallback previous = mGLFWMouseButtonCallback;
        long address = nglfwSetMouseButtonCallback(window, memAddressSafe(cbfun));
        mGLFWMouseButtonCallback = cbfun == null ? null
                : GLFWMouseButtonCallback.createSafe(address);
        return previous;
    }

    public static GLFWPreeditCallback glfwSetPreeditCallback(long window,
            GLFWPreeditCallbackI cbfun) {
        GLFWPreeditCallback previous = mGLFWPreeditCallback;
        mGLFWPreeditCallback = cbfun == null ? null : GLFWPreeditCallback.create(cbfun);
        return previous;
    }

    public static GLFWIMEStatusCallback glfwSetIMEStatusCallback(long window,
            GLFWIMEStatusCallbackI cbfun) {
        GLFWIMEStatusCallback previous = mGLFWIMEStatusCallback;
        mGLFWIMEStatusCallback = cbfun == null ? null : GLFWIMEStatusCallback.create(cbfun);
        return previous;
    }

    // 3.4.x IME cursor hint. The HarmonyOS IME (ArkUI) does not consume a
    // client-supplied candidate rectangle, so there is nothing to forward yet;
    // an explicit no-op keeps the MC >= 1.22 call site resolvable.
    public static void glfwSetPreeditCursorRectangle(long window, int x, int y, int w, int h) {
    }

    public static GLFWScrollCallback glfwSetScrollCallback(long window,
            GLFWScrollCallbackI cbfun) {
        GLFWScrollCallback previous = mGLFWScrollCallback;
        long address = nglfwSetScrollCallback(window, memAddressSafe(cbfun));
        mGLFWScrollCallback = cbfun == null ? null : GLFWScrollCallback.createSafe(address);
        return previous;
    }

    public static GLFWWindowCloseCallback glfwSetWindowCloseCallback(long window,
            GLFWWindowCloseCallbackI cbfun) {
        GLFWWindowCloseCallback previous = mGLFWWindowCloseCallback;
        mGLFWWindowCloseCallback = cbfun == null ? null
                : GLFWWindowCloseCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowContentScaleCallback glfwSetWindowContentScaleCallback(long window,
            GLFWWindowContentScaleCallbackI cbfun) {
        GLFWWindowContentScaleCallback previous = mGLFWWindowContentScaleCallback;
        mGLFWWindowContentScaleCallback = cbfun == null ? null
                : GLFWWindowContentScaleCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowFocusCallback glfwSetWindowFocusCallback(long window,
            GLFWWindowFocusCallbackI cbfun) {
        GLFWWindowFocusCallback previous = mGLFWWindowFocusCallback;
        mGLFWWindowFocusCallback = cbfun == null ? null : GLFWWindowFocusCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowIconifyCallback glfwSetWindowIconifyCallback(long window,
            GLFWWindowIconifyCallbackI cbfun) {
        GLFWWindowIconifyCallback previous = mGLFWWindowIconifyCallback;
        mGLFWWindowIconifyCallback = cbfun == null ? null
                : GLFWWindowIconifyCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowMaximizeCallback glfwSetWindowMaximizeCallback(long window,
            GLFWWindowMaximizeCallbackI cbfun) {
        GLFWWindowMaximizeCallback previous = mGLFWWindowMaximizeCallback;
        mGLFWWindowMaximizeCallback = cbfun == null ? null
                : GLFWWindowMaximizeCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowPosCallback glfwSetWindowPosCallback(long window,
            GLFWWindowPosCallbackI cbfun) {
        GLFWWindowPosCallback previous = mGLFWWindowPosCallback;
        mGLFWWindowPosCallback = cbfun == null ? null : GLFWWindowPosCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowRefreshCallback glfwSetWindowRefreshCallback(long window,
            GLFWWindowRefreshCallbackI cbfun) {
        GLFWWindowRefreshCallback previous = mGLFWWindowRefreshCallback;
        mGLFWWindowRefreshCallback = cbfun == null ? null
                : GLFWWindowRefreshCallback.create(cbfun);
        return previous;
    }

    public static GLFWWindowSizeCallback glfwSetWindowSizeCallback(long window,
            GLFWWindowSizeCallbackI cbfun) {
        GLFWWindowSizeCallback previous = null;
        if (mGLFWWindowSizeCallbackI != null) {
            previous = GLFWWindowSizeCallback.create(mGLFWWindowSizeCallbackI);
        }
        mGLFWWindowSizeCallbackI = cbfun;
        return previous;
    }

    public static boolean glfwJoystickPresent(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            CallbackBridge.enableGamepadDirectInput();
            return true;
        }
        return false;
    }

    public static String glfwGetJoystickName(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return "Meowcraft gamepad";
        }
        return null;
    }

    public static FloatBuffer glfwGetJoystickAxes(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return mGLFWJoystickAxes;
        }
        return null;
    }

    public static ByteBuffer glfwGetJoystickButtons(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return mGLFWJoystickButtons;
        }
        return null;
    }

    public static ByteBuffer glfwGetJoystickHats(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return mGLFWJoystickHats;
        }
        return null;
    }

    public static boolean glfwJoystickIsGamepad(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            CallbackBridge.enableGamepadDirectInput();
            return true;
        }
        return false;
    }

    public static String glfwGetJoystickGUID(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return "030000005e0400008e02000056210000";
        }
        return null;
    }

    private static long mGLFWJoystickUserPointer;

    public static long glfwGetJoystickUserPointer(int jid) {
        return mGLFWJoystickUserPointer;
    }

    public static void glfwSetJoystickUserPointer(int jid, long pointer) {
        mGLFWJoystickUserPointer = pointer;
    }

    public static boolean glfwUpdateGamepadMappings(ByteBuffer string) {
        return false;
    }

    public static String glfwGetGamepadName(int jid) {
        if (jid == GLFW_JOYSTICK_1) {
            return "Meowcraft gamepad";
        }
        return null;
    }

    public static boolean glfwGetGamepadState(int jid, GLFWGamepadState state) {
        if (jid != GLFW_JOYSTICK_1 || state == null) {
            return false;
        }
        MemoryUtil.memCopy(mGLFWGamepadDataPointer, state.address(), state.sizeof());
        return true;
    }

}
