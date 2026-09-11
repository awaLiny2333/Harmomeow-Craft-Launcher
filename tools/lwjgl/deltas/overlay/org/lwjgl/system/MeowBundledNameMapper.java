/*
 * Meowcraft clean-room overlay — bundled shared-library name mapper.
 *
 * Enables several LWJGL generations to coexist in one (fs-verity signed) native
 * directory: the install can only sign packaged .so, and the device forbids
 * dlopen of runtime-written files, so both generations' natives must live side
 * by side under distinct names. LWJGL resolves bundled library names through
 * Platform.mapLibraryNameBundled -> Configuration.BUNDLED_LIBRARY_NAME_MAPPER,
 * which accepts a Function<String,String> implementation class.
 *
 * Activate with (before Platform class init, i.e. as a JVM -D):
 *   -Dorg.lwjgl.system.bundledLibrary.nameMapper=org.lwjgl.system.MeowBundledNameMapper
 *   -Dmeow.lwjgl.gen=<generation>     e.g. 3.4.3 -> files liblwjgl_343.so, ...
 *
 * With no meow.lwjgl.gen (or an empty value) the name is returned unchanged, so
 * the default generation keeps its stock file names.
 */
package org.lwjgl.system;

import java.util.function.Function;

public final class MeowBundledNameMapper implements Function<String, String> {

    /** Digits-only generation tag, e.g. "3.4.3" -> "_343"; empty when unset. */
    private static final String SUFFIX = suffix();

    private static String suffix() {
        String gen = System.getProperty("meow.lwjgl.gen", "");
        return gen.isEmpty() ? "" : "_" + gen.replace(".", "");
    }

    @Override
    public String apply(String name) {
        if (SUFFIX.isEmpty()) {
            return name;
        }
        // Only our own bundled LWJGL natives carry a generation suffix; the GL
        // driver / OpenAL / FreeType names must pass through untouched.
        if ("lwjgl".equals(name) || "lwjgl_opengl".equals(name) || "lwjgl_stb".equals(name)) {
            return name + SUFFIX;
        }
        return name;
    }
}
