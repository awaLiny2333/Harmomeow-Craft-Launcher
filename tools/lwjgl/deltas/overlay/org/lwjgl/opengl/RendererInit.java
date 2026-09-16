package org.lwjgl.opengl;

import java.util.LinkedHashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.lwjgl.system.FunctionProvider;
import org.lwjgl.system.JNI;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.SharedLibrary;

public final class RendererInit {

    /** Parsed capability deny-list (null until first use). */
    private static Set<String> deniedNames;

    /** Cached strict-capabilities decision (null until first use). */
    private static Boolean strictMode;

    /** The provider handed in by the capabilities constructor (source of the GL version query). */
    private static FunctionProvider capsProvider;

    /** GL_VERSION, once read (-1 = unknown, i.e. version groups are reported as unsupported). */
    private static int versionMajor = -1;
    private static int versionMinor = -1;
    private static boolean versionParsed;

    private RendererInit() {
    }

    public static void onCreateCapabilities(FunctionProvider provider) {
        capsProvider = provider;
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
     * <p>Upstream LWJGL gates every version group and extension on what the driver ADVERTISES
     * ({@code if (!ext.contains("OpenGL46")) return false;}) and only then requires the entry
     * points to resolve. Our overlay used to delete those guards process-wide, which made a
     * version group - and an extension - report "supported" merely because Mesa's dispatch table
     * resolves the symbol: on this GL 4.2 device {@code OpenGL46} came out true and Flywheel's
     * {@code if (CAPABILITIES.OpenGL46) return true;} shortcut took the compute path
     * (measured 2026-09-16). So the guards stay, but they are runtime-conditional.</p>
     *
     * <p>Strict = ON for every renderer except {@code MEOWCRAFT_RENDERER=gl4es}, whose compat
     * context advertises a low version while the higher entry points still resolve (that path
     * needs the permissive probe). {@code MEOW_STRICT_CAPS} / {@code -Dmeow.strictCaps}
     * overrides either way.</p>
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
     * Version-group decision for the generated guards (gen_glcap.py edit 2).
     *
     * <p>Neither of the two extremes is honest on this stack, and both were measured: Mesa
     * (Zink) never advertises the {@code "OpenGLxy"} pseudo-extension names, so upstream's
     * guard makes every version group false (under-report: the context really is 4.2), while
     * deleting the guards makes them all true (over-report: 4.2 claimed as 4.6). The truth is
     * the context's own {@code GL_VERSION} string, so a group is allowed when the driver
     * advertises it OR the parsed version is at least that group.</p>
     */
    public static boolean allowsVersionGroup(Set<String> ext, int major, int minor) {
        if (ext.contains("OpenGL" + major + minor)) {
            return true;
        }
        return atLeastVersion(major, minor);
    }

    /** Whether the context's parsed GL_VERSION is at least {@code major.minor}. */
    public static boolean atLeastVersion(int major, int minor) {
        parseVersion();
        return versionMajor > major || (versionMajor == major && versionMinor >= minor);
    }

    /** Read and log GL_VERSION once (safe: no context -> the call returns NULL and we say so). */
    private static void parseVersion() {
        if (versionParsed) {
            return;
        }
        versionParsed = true;
        String raw = null;
        try {
            FunctionProvider provider = capsProvider;
            long addr = provider == null ? 0L : provider.getFunctionAddress("glGetString");
            if (addr != 0L) {
                long ptr = JNI.invokeP(0x1F02 /* GL_VERSION */, addr);
                if (ptr != 0L) {
                    // NB: the bounded variant decodes `length` BYTES, so it can carry the
                    // terminator and whatever follows it in memory. Cut at the first NUL - an
                    // embedded NUL used to survive into our log line and the forwarder's `%s`
                    // then silently dropped everything after it (measured: 142 chars -> 85).
                    raw = MemoryUtil.memASCII(ptr, 64);
                    int nul = raw.indexOf('\0');
                    if (nul >= 0) {
                        raw = raw.substring(0, nul);
                    }
                }
            }
        } catch (Throwable t) {
            System.out.println("RendererInit: GL_VERSION query failed: " + t);
        }
        if (raw != null) {
            Matcher matcher = Pattern.compile("(\\d+)\\.(\\d+)").matcher(raw);
            if (matcher.find()) {
                try {
                    versionMajor = Integer.parseInt(matcher.group(1));
                    versionMinor = Integer.parseInt(matcher.group(2));
                } catch (NumberFormatException ignored) {
                    // keep -1/-1
                }
            }
        }
        // Short lines on purpose: a single hilog message is capped at 4096 bytes (documented) and
        // short lines also survive any forwarder-side surprise.
        System.out.println("RendererInit: GL_VERSION len=" + (raw == null ? -1 : raw.length()));
        System.out.println("RendererInit: GL_VERSION=["
                + (raw == null ? "unavailable" : raw) + "]");
        System.out.println("RendererInit: groups " + (versionMajor < 0
                ? "unsupported (no version known)"
                : versionMajor + "." + versionMinor + "; " + groupRange()));
    }

    /** Self-evidence: which generated version groups the parsed GL version turns on. */
    private static String groupRange() {
        if (versionMajor > 4) {
            return "OpenGL11..OpenGL46 on (all of them)";
        }
        if (versionMajor < 1) {
            return "none";
        }
        int minor = versionMajor == 1 ? Math.min(versionMinor, 5) : Math.min(versionMinor, 9);
        return "OpenGL11..OpenGL" + versionMajor + minor + " on, higher off";
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
     * capabilities to report as absent, so one can hide - and un-hide - without a rebuild.
     * The same names also drive the Mesa layer ({@code MESA_EXTENSION_OVERRIDE}), so one list
     * masks both consumers.</p>
     *
     * <p>Why the probe-level hook is the one that matters (measured 2026-09-16): a probe such
     * as {@code check_ARB_compute_shader} is a pure function-slot test with no
     * {@code ext.contains(...)} term, so neither filtering {@code ext}, nor the Mesa layer
     * ({@code MESA_EXTENSION_OVERRIDE}), nor a GL-layer filter can reach it - the flag stays
     * true because Zink does export {@code glDispatchCompute}. The wrapper keeps the left
     * operand evaluated (the slots still load, so the native address-slot contract is
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
