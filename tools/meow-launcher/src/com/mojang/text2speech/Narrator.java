package com.mojang.text2speech;

/**
 * Clean-room compatibility surface for the narrator dependency that Minecraft links against. The
 * real speech backends are intentionally not provided on this platform.
 */
public interface Narrator {
    void say(String message, boolean interrupt);

    void clear();

    boolean active();

    void destroy();

    static Narrator getNarrator() {
        return new NarratorDummy();
    }

    static void setJNAPath(String separator) {
    }
}
