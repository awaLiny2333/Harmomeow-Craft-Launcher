package meow.launcher;

import com.google.gson.Gson;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * Reads a version descriptor and flattens {@code inheritsFrom} chains into one effective version.
 */
public final class VersionLoader {
    private static final Gson GSON = new Gson();

    private VersionLoader() {
    }

    /** Read {@code <versions>/<id>/<id>.json}, resolving a parent descriptor if declared. */
    public static VersionJson load(String id) throws IOException {
        VersionJson child = read(id);
        if (child == null) {
            throw new IOException("Version descriptor not found: " + id);
        }
        String base = child.id != null ? child.id : id;
        String parentId = child.inheritsFrom;
        if (parentId == null || parentId.isEmpty() || parentId.equals(base)) {
            return child;
        }
        VersionJson parent = read(parentId);
        if (parent == null) {
            return child;
        }
        return inherit(parent, child, parentId);
    }

    private static VersionJson read(String id) throws IOException {
        String path = GameDirs.versions + "/" + id + "/" + id + ".json";
        if (!Files.exists(Paths.get(path))) {
            return null;
        }
        String json = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
        return GSON.fromJson(json, VersionJson.class);
    }

    /** Overlay {@code child} on top of {@code parent}; the base id is remembered for name expansion. */
    private static VersionJson inherit(VersionJson parent, VersionJson child, String parentId) {
        parent.inheritsFrom = parentId;

        if (notEmpty(child.id)) {
            parent.id = child.id;
        }
        if (notEmpty(child.mainClass)) {
            parent.mainClass = child.mainClass;
        }
        if (notEmpty(child.minecraftArguments)) {
            parent.minecraftArguments = child.minecraftArguments;
        }
        if (notEmpty(child.assets)) {
            parent.assets = child.assets;
        }
        if (notEmpty(child.type)) {
            parent.type = child.type;
        }

        parent.libraries = mergeLibraries(parent.libraries, child.libraries);
        parent.arguments = mergeArguments(parent.arguments, child.arguments);
        return parent;
    }

    private static boolean notEmpty(String value) {
        return value != null && !value.isEmpty();
    }

    /** Concatenate libraries, letting a child entry replace the parent entry with the same group:artifact. */
    private static VersionJson.Library[] mergeLibraries(VersionJson.Library[] base,
            VersionJson.Library[] overlay) {
        List<VersionJson.Library> merged = new ArrayList<>();
        if (base != null) {
            for (VersionJson.Library library : base) {
                if (library == null) {
                    continue;
                }
                if (overlay != null && containsLibrary(overlay, libraryKey(library))) {
                    continue;
                }
                merged.add(library);
            }
        }
        if (overlay != null) {
            for (VersionJson.Library library : overlay) {
                if (library != null) {
                    merged.add(library);
                }
            }
        }
        return merged.toArray(new VersionJson.Library[0]);
    }

    private static boolean containsLibrary(VersionJson.Library[] libraries, String key) {
        for (VersionJson.Library library : libraries) {
            if (library != null && key.equals(libraryKey(library))) {
                return true;
            }
        }
        return false;
    }

    private static String libraryKey(VersionJson.Library library) {
        String name = library.name == null ? "" : library.name;
        int idx = name.lastIndexOf(':');
        return idx < 0 ? name : name.substring(0, idx);
    }

    /** Append child game arguments to the parent list, dropping duplicated flags and their values. */
    private static VersionJson.Arguments mergeArguments(VersionJson.Arguments base,
            VersionJson.Arguments overlay) {
        if (base == null || base.game == null) {
            return overlay != null ? overlay : base;
        }
        if (overlay == null || overlay.game == null) {
            return base;
        }
        List<Object> merged = new ArrayList<>();
        for (Object arg : base.game) {
            merged.add(arg);
        }
        Object[] extra = overlay.game;
        for (int i = 0; i < extra.length; i++) {
            Object arg = extra[i];
            if (arg instanceof String) {
                String text = (String) arg;
                if (text.startsWith("--") && merged.contains(text)) {
                    if (i + 1 < extra.length && isValue(extra[i + 1])) {
                        i++;
                    }
                } else {
                    merged.add(text);
                }
            } else if (!merged.contains(arg)) {
                merged.add(arg);
            }
        }
        VersionJson.Arguments result = new VersionJson.Arguments();
        result.game = merged.toArray(new Object[0]);
        result.jvm = overlay.jvm != null ? overlay.jvm : base.jvm;
        return result;
    }

    private static boolean isValue(Object arg) {
        return arg instanceof String && !((String) arg).startsWith("--");
    }
}
