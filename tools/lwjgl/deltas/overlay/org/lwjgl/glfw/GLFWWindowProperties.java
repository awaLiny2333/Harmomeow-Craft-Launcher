package org.lwjgl.glfw;

import java.util.HashMap;
import java.util.Map;

public class GLFWWindowProperties {

    public int width = GLFW.mGLFWWindowWidth;
    public int height = GLFW.mGLFWWindowHeight;
    public int x;
    public int y;
    public CharSequence title;
    public boolean shouldClose;
    public boolean isInitialSizeCalled;
    public boolean isCursorEntered;
    public Map<Integer, Integer> inputModes = new HashMap<>();
    public Map<Integer, Integer> windowAttribs = new HashMap<>();

}
