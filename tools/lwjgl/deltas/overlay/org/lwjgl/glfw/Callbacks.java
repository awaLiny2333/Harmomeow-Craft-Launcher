package org.lwjgl.glfw;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

import org.lwjgl.system.Checks;

public final class Callbacks {

    private Callbacks() {
    }

    public static void glfwFreeCallbacks(long window) {
        if (Checks.CHECKS) {
            Checks.check(window);
        }

        try {
            for (Method method : GLFW.class.getMethods()) {
                String name = method.getName();
                if (!name.startsWith("glfwSet") || !name.endsWith("Callback")) {
                    continue;
                }
                int parameters = method.getParameterCount();
                if (parameters == 1) {
                    method.invoke(null, (Object) null);
                } else if (parameters == 2) {
                    method.invoke(null, GLFW.glfwGetCurrentContext(), null);
                }
            }
        } catch (IllegalAccessException | NullPointerException e) {
            throw new RuntimeException(
                    "org.lwjgl.glfw.GLFW.glfwSetXXXCallback() must be public and static", e);
        } catch (InvocationTargetException e) {
            throw new RuntimeException(e);
        }
    }

}
