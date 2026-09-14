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
 *   -Dmeow.lwjgl.gen=<generation>     e.g. 3.4.3 -> files liblwjgl_343.so,
 *                                     liblwjgl_343_opengl.so, liblwjgl_343_stb.so
 *
 * With no meow.lwjgl.gen (or an empty value) the name is returned unchanged, so
 * the default generation keeps its stock file names.
 */
package org.lwjgl.system;

import java.util.function.Function;

public final class MeowBundledNameMapper implements Function<String, String> {

    /** Digits-only generation tag, e.g. "3.4.3" -> "343"; empty when unset. */
    private static final String GEN = System.getProperty("meow.lwjgl.gen", "").replace(".", "");

    @Override
    public String apply(String name) {
        if (GEN.isEmpty()) {
            return name;   // unset -> the stock file names
        }
        // The generation tag sits right AFTER the base name, so the three natives line up:
        //   lwjgl -> liblwjgl_343.so
        //   lwjgl_opengl -> liblwjgl_343_opengl.so
        //   lwjgl_stb -> liblwjgl_343_stb.so
        // Everything else (gl driver / openal / freetype / SDL3 / lwjgl_tinyfd ...) passes
        // through untouched -- keep this an EXPLICIT allowlist (a "lwjgl_" prefix rule
        // would wrongly rewrite lwjgl_tinyfd, which is generation-agnostic).
        if ("lwjgl".equals(name)) {
            return "lwjgl_" + GEN;
        }
        if ("lwjgl_opengl".equals(name)) {
            return "lwjgl_" + GEN + "_opengl";
        }
        if ("lwjgl_stb".equals(name)) {
            return "lwjgl_" + GEN + "_stb";
        }
        return name;
    }
}
