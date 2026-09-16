package org.lwjgl.opengl;

import java.util.LinkedHashSet;
import java.util.Set;

import org.lwjgl.system.FunctionProvider;
import org.lwjgl.system.SharedLibrary;

public final class RendererInit {

    /** Parsed capability deny-list (null until first use). */
    private static Set<String> deniedNames;

    /** Cached strict-capabilities decision (null until first use). */
    private static Boolean strictMode;

    private RendererInit() {
    }

    public static void onCreateCapabilities(FunctionProvider provider) {
        String rendererName = null;
        if (provider instanceof SharedLibrary) {
            rendererName = ((SharedLibrary) provider).getName();
        }
        if (!isValid(rendererName)) {
            rendererName = System.getProperty("org.lwjgl.opengl.libname");
        }
        if (!isValid(rendererName)) {
            System.out.println("RendererInit: renderer name unavailable; "
                    + "renderer-specific initialization is skipped");
            return;
        }
        if (rendererName.endsWith("libng_gl4es.so")) {
            nativeInitGl4esInternals(provider);
        }
    }

    /**
     * Whether the advertised-vs-resolvable guards must be honoured (gen_glcap.py edit 2).
     *
     * <p>Upstream LWJGL gates every version group and extension on what the driver
     * ADVERTISES ({@code if (!ext.contains("OpenGL46")) return false;}) and only then
     * requires the entry points to resolve. Our overlay used to delete those guards
     * process-wide, which made a version group - and an extension - report "supported"
     * merely because Mesa's dispatch table resolves the symbol. On the modern path that is
     * a lie: this device is GL 4.2, yet {@code OpenGL46} came out true, and Flywheel's
     * {@code if (CAPABILITIES.OpenGL46) return true;} shortcut then took the compute path
     * (measured 2026-09-16). So the guards stay, but they are runtime-conditional.</p>
     *
     * <p>Strict = ON for every renderer except {@code MEOWCRAFT_RENDERER=gl4es}, whose
     * compat context advertises a low version while the higher entry points still resolve
     * (that path needs the permissive probe). {@code MEOW_STRICT_CAPS} /
     * {@code -Dmeow.strictCaps} overrides either way.</p>
     */
    public static boolean strictCapabilities() {
        Boolean cached = strictMode;
        if (cached != null) {
            return cached;
        }
        String override = System.getProperty("meow.strictCaps");
        if (!isValid(override)) {
            override = System.getenv("MEOW_STRICT_CAPS");
        }
        boolean value;
        if (isValid(override)) {
            value = !"0".equals(override) && !"false".equalsIgnoreCase(override);
        } else {
            value = !"gl4es".equals(System.getenv("MEOWCRAFT_RENDERER"));
        }
        System.out.println("RendererInit: capability guards " + (value
                ? "ON (advertised + resolvable: honest version groups)"
                : "OFF (resolvable only - gl4es compat context)"));
        strictMode = value;
        return value;
    }

    /**
     * Runtime capability mask: a deny-list consulted by EVERY capability probe.
     *
     * <p>Wired in by {@code gen_glcap.py}: edit 6 wraps each capability assignment
     * ({@code FIELD = check_X(...);} and {@code FIELD = ext.contains("...");}) with
     * {@code && !RendererInit.isMasked("FIELD")}, and edit 5 rebinds the constructor's
     * {@code ext} parameter through {@link #filterCapabilities(Set)} for the probes that
     * consult nothing but that set.</p>
     *
     * <p>The policy is DATA, not code: {@code -Dmeow.maskExtensions=GL_A,GL_B} or the
     * {@code MEOW_MASK_EXTENSIONS} environment variable (the property wins) names the
     * capabilities to report as absent, so one can hide - and un-hide - without a
     * rebuild. The same names also drive the Mesa layer
     * ({@code MESA_EXTENSION_OVERRIDE}), so one list masks both consumers.</p>
     *
     * <p>Why the probe-level hook is the one that matters (measured 2026-09-16): a probe
     * such as {@code check_ARB_compute_shader} is a pure function-slot test with no
     * {@code ext.contains(...)} term, so neither filtering {@code ext}, nor the Mesa layer
     * ({@code MESA_EXTENSION_OVERRIDE}), nor a GL-layer filter can reach it - the flag
     * stays true because Zink does export {@code glDispatchCompute}. The wrapper keeps the
     * left operand evaluated (the slots still load, so the native address-slot contract is
     * untouched) and only forces the flag to false.</p>
     *
     * <p>Masking (true -&gt; false) is all we do on purpose: faking a capability
     * (false -&gt; true) would also need the driver to resolve that capability's entry
     * points, which we cannot guarantee.</p>
     */
    public static boolean isMasked(String name) {
        return denied().contains(name);
    }

    /** The deny-list, parsed once from the property/env (empty = masking disabled). */
    private static Set<String> denied() {
        Set<String> cached = deniedNames;
        if (cached != null) {
            return cached;
        }
        String spec = System.getProperty("meow.maskExtensions");
        if (!isValid(spec)) {
            spec = System.getenv("MEOW_MASK_EXTENSIONS");
        }
        Set<String> denied = new LinkedHashSet<>();
        if (isValid(spec)) {
            for (String name : spec.split("[,\\s]+")) {
                if (!name.isEmpty()) {
                    denied.add(name);
                }
            }
        }
        System.out.println("RendererInit: capability mask " + (denied.isEmpty() ? "off" : "armed")
                + ": [" + String.join(" ", denied) + "] (every capability probe consults it)");
        deniedNames = denied;
        return denied;
    }

    /** Drop the denied names from the extension set (probes that only test {@code ext}). */
    public static Set<String> filterCapabilities(Set<String> ext) {
        Set<String> denied = denied();
        if (denied.isEmpty()) {
            return ext;
        }
        Set<String> kept = new LinkedHashSet<>(ext);
        StringBuilder removed = new StringBuilder();
        for (String name : denied) {
            if (kept.remove(name)) {
                if (removed.length() > 0) {
                    removed.append(' ');
                }
                removed.append(name);
            }
        }
        System.out.println("RendererInit: extension set filtered: absent=["
                + (removed.length() > 0 ? removed.toString() : "none") + "]");
        return kept;
    }

    private static boolean isValid(String value) {
        return value != null && !value.isEmpty();
    }

    public static native void nativeInitGl4esInternals(FunctionProvider provider);

}
