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

    /** Parsed capability deny-list (published once; null until then). */
    private static volatile Set<String> deniedNames;

    /** Cached strict-capabilities decision (published once; null until then). */
    private static volatile Boolean strictMode;

    /** Provider handed in by the capabilities constructor (source of the GL version query). */
    private static volatile FunctionProvider capsProvider;

    /** GL version: published only after a SUCCESSFUL parse (a failure stays retry-able). */
    private static volatile int versionMajor = -1;
    private static volatile int versionMinor = -1;
    private static volatile boolean versionReady;

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
        // NOTE: the app ships "libgl4es.so" (LaunchDefaults), not "libng_gl4es.so", so this
        // branch is inert for the current gl4es path; kept for the historical HNP name.
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
     * {@code if (CAPABILITIES.OpenGL46) return true;} shortcut therefore took the compute path
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
        synchronized (RendererInit.class) {
            cached = strictMode;
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
    }

    /**
     * Version-group decision for the generated guards (gen_glcap.py edit 2).
     *
     * <p>LWJGL synthesises the ext set itself: {@code GL.createCapabilities} adds exactly ONE
     * version name, {@code "OpenGL" + major + minor}, taken from GL_MAJOR_VERSION /
     * GL_MINOR_VERSION (reference: ref/lwjgl3, org/lwjgl/opengl/GL.java). So on this GL 4.2
     * context that family contains {@code "OpenGL42"} and nothing else, and upstream's guard
     * made {@code OpenGL43..46} false - correct, and that is what kills Flywheel's
     * {@code if (CAPABILITIES.OpenGL46) return true;} shortcut - but ALSO made
     * {@code OpenGL11..41} false, which is wrong: the context does support them. Deleting the
     * guards had the opposite error (4.2 claimed as 4.6). Hence: a group is allowed when the
     * driver advertises its name OR the parsed GL_VERSION is at least that group.</p>
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

    /**
     * Read and log GL_VERSION once, thread-safely.
     *
     * <p>Two capabilities constructions can happen in a session (and not necessarily on the same
     * thread), so the values are computed into locals and only published - values first, then the
     * ready flag - inside the lock. A FAILURE (no current context, unresolvable
     * {@code glGetString}, unparseable string) leaves {@code versionReady == false} so the next
     * construction retries, instead of caching a bogus "GL 1.0" for the whole session.</p>
     */
    private static void parseVersion() {
        if (versionReady) {
            return;
        }
        synchronized (RendererInit.class) {
            if (versionReady) {
                return;
            }
            String raw = null;
            int major = -1;
            int minor = -1;
            try {
                FunctionProvider provider = capsProvider;
                long addr = provider == null ? 0L : provider.getFunctionAddress("glGetString");
                if (addr != 0L) {
                    long ptr = JNI.invokeP(0x1F02 /* GL_VERSION */, addr);
                    if (ptr != 0L) {
                        // NB: the bounded variant decodes `length` BYTES, so it can carry the
                        // terminator and whatever follows it in memory. Cut at the first NUL -
                        // an embedded NUL used to survive into our log line and the forwarder's
                        // `%s` then dropped everything after it (measured: 142 chars -> 85).
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
                        major = Integer.parseInt(matcher.group(1));
                        minor = Integer.parseInt(matcher.group(2));
                    } catch (NumberFormatException ignored) {
                        // leave -1/-1 -> not ready -> a later construction may retry
                    }
                }
            }
            versionMajor = major;
            versionMinor = minor;
            versionReady = major >= 0;
            // Short lines on purpose: a single hilog message is capped at 4096 bytes (documented)
            // and short lines also survive any forwarder-side surprise.
            System.out.println("RendererInit: GL_VERSION len=" + (raw == null ? -1 : raw.length()));
            System.out.println("RendererInit: GL_VERSION=["
                    + (raw == null ? "unavailable" : raw) + "]");
            System.out.println("RendererInit: groups " + (major < 0
                    ? "not known yet (this construction reports no version groups)"
                    : major + "." + minor + "; " + groupRange(major, minor)));
        }
    }

    /** Self-evidence: which generated version groups a GL version turns on. */
    private static String groupRange(int major, int minor) {
        if (major > 4) {
            return "OpenGL11..OpenGL46 on (all of them)";
        }
        if (major < 1) {
            return "none";
        }
        int capped;
        if (major == 1) {
            capped = Math.min(minor, 5);
        } else if (major == 4) {
            capped = Math.min(minor, 6);   // there is no OpenGL47
        } else {
            capped = Math.min(minor, 9);
        }
        return "OpenGL11..OpenGL" + major + capped + " on, higher off";
    }

    /**
     * Runtime capability mask: a deny-list consulted by EVERY capability probe.
     *
     * <p>Wired in by {@code gen_glcap.py}: edit 6 wraps each capability assignment
     * ({@code FIELD = check_X(...);} and {@code FIELD = ext.contains("...");}) with
     * {@code && !RendererInit.isMasked("FIELD")}, and edit 5 rebinds the constructor's
     * {@code ext} parameter through {@link #filterCapabilities(Set)}.</p>
     *
     * <p>Edit 6 is what makes the VERSION GROUPS maskable (they are computed from the parsed
     * GL_VERSION, which knows nothing about the deny-list) and what keeps masking effective on
     * the strict-OFF gl4es path; edit 5 alone cannot reach either.</p>
     *
     * <p>The policy is DATA, not code: {@code -Dmeow.maskExtensions=GL_A,GL_B} and the
     * {@code MEOW_MASK_EXTENSIONS} environment variable are UNIONed here. NOTE the asymmetry:
     * only the environment variable also drives the Mesa layer ({@code MESA_EXTENSION_OVERRIDE},
     * set by the launcher from the same list) - a {@code -D} masks the LWJGL view only.</p>
     *
     * <p>Masking (true -&gt; false) is all we do on purpose: faking a capability
     * (false -&gt; true) would also need the driver to resolve that capability's entry
     * points, which we cannot guarantee.</p>
     */
    public static boolean isMasked(String name) {
        return denied().contains(name);
    }

    /** The deny-list: property and env unioned, parsed once (empty = masking disabled). */
    private static Set<String> denied() {
        Set<String> cached = deniedNames;
        if (cached != null) {
            return cached;
        }
        synchronized (RendererInit.class) {
            cached = deniedNames;
            if (cached != null) {
                return cached;
            }
            Set<String> denied = new LinkedHashSet<>();
            collect(denied, System.getProperty("meow.maskExtensions"));
            collect(denied, System.getenv("MEOW_MASK_EXTENSIONS"));
            System.out.println("RendererInit: capability mask "
                    + (denied.isEmpty() ? "off" : "armed") + ": [" + String.join(" ", denied)
                    + "] (consulted by every capability probe)");
            deniedNames = denied;
            return denied;
        }
    }

    private static void collect(Set<String> into, String spec) {
        if (!isValid(spec)) {
            return;
        }
        for (String name : spec.split("[,\\s]+")) {
            if (!name.isEmpty()) {
                into.add(name);
            }
        }
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
