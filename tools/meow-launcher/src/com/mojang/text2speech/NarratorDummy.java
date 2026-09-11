package com.mojang.text2speech;

/** No-op narrator used on platforms without a speech backend. */
public class NarratorDummy implements Narrator {

    @Override
    public void say(String message, boolean interrupt) {
    }

    @Override
    public void clear() {
    }

    @Override
    public boolean active() {
        return false;
    }

    @Override
    public void destroy() {
    }
}
