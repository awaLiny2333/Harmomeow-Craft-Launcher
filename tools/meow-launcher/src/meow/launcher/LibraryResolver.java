package meow.launcher;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

/**
 * Builds the runtime classpath from the effective version descriptor. Unsupported artifacts are
 * excluded and non-existent files are reported rather than shipped to the JVM.
 */
public final class LibraryResolver {
    private static final String[] SKIPPED_PREFIXES = {
        "com.mojang:text2speech",
        "net.java.dev.jna:platform:",
        "org.lwjgl",
        "tv.twitch"
    };

    private LibraryResolver() {
    }

    /** Resolve the classpath entries for {@code version}, terminated by the version jar. */
    public static String build(VersionJson version) {
        List<String> entries = new ArrayList<>();
        if (version.libraries != null) {
            for (VersionJson.Library library : version.libraries) {
                if (library == null || library.name == null || isSkipped(library.name)) {
                    continue;
                }
                String path = artifactPath(library);
                if (path == null) {
                    continue;
                }
                String full = GameDirs.libraries + "/" + path;
                if (!entries.contains(full)) {
                    entries.add(full);
                }
            }
        }

        StringBuilder classpath = new StringBuilder();
        for (String entry : entries) {
            if (!new File(entry).exists()) {
                System.out.println("Ignored non-exists file: " + entry);
                continue;
            }
            classpath.append(entry).append(':');
        }
        String jarId = resolveJarId(version);
        classpath.append(GameDirs.versions).append('/').append(jarId)
                .append('/').append(jarId).append(".jar");
        return classpath.toString();
    }

    /**
     * Version id whose {@code <id>.jar} provides the client classes.
     *
     * <p>For an {@code inheritsFrom} form (e.g. a Fabric profile
     * {@code fabric-loader-<loader>-<game>}) the leaf has no jar of its own; the vanilla client jar
     * lives in the base version directory. An explicit {@code jar} field wins, otherwise the
     * inherited base id, otherwise the version id; falls back to the version id when the resolved
     * jar is absent but the version's own jar exists.
     */
    private static String resolveJarId(VersionJson version) {
        String base = (version.jar != null && !version.jar.isEmpty()) ? version.jar
                : (version.inheritsFrom != null && !version.inheritsFrom.isEmpty()
                        ? version.inheritsFrom : version.id);
        if (!versionJarExists(base) && version.id != null && !version.id.isEmpty()
                && versionJarExists(version.id)) {
            return version.id;
        }
        return base;
    }

    private static boolean versionJarExists(String id) {
        return id != null && new File(GameDirs.versions + "/" + id + "/" + id + ".jar").exists();
    }

    private static boolean isSkipped(String name) {
        for (String prefix : SKIPPED_PREFIXES) {
            if (name.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    private static String artifactPath(VersionJson.Library library) {
        if (library.downloads != null && library.downloads.artifact != null
                && library.downloads.artifact.path != null) {
            return library.downloads.artifact.path;
        }
        String[] parts = library.name.split(":");
        if (parts.length < 3) {
            return null;
        }
        String group = parts[0].replace('.', '/');
        String artifact = parts[1];
        String version = parts[2];
        return group + "/" + artifact + "/" + version + "/" + artifact + "-" + version + ".jar";
    }
}
