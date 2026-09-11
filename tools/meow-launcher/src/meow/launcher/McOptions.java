package meow.launcher;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * Line oriented reader/writer for {@code options.txt}. The file format is {@code key:value} per
 * line; saving is intentionally non-atomic.
 */
public final class McOptions {
    private static List<String> lines;

    private McOptions() {
    }

    /** (Re)read {@code <profile>/options.txt}; a missing file yields an empty option set. */
    public static void load() {
        if (lines == null) {
            lines = new ArrayList<>();
        } else {
            lines.clear();
        }
        File file = new File(GameDirs.profile, "options.txt");
        if (!file.exists()) {
            return;
        }
        try (BufferedReader reader = new BufferedReader(
                new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                lines.add(line);
            }
        } catch (IOException e) {
            System.err.println("Could not load options.txt");
            e.printStackTrace(System.err);
        }
    }

    /** @return the value for {@code key}, or null when the option is absent. */
    public static String get(String key) {
        if (lines == null) {
            load();
        }
        String prefix = key + ":";
        for (String line : lines) {
            if (line.startsWith(prefix)) {
                return line.substring(prefix.length());
            }
        }
        return null;
    }

    /** Replace the option or append it when missing. */
    public static void set(String key, String value) {
        if (lines == null) {
            load();
        }
        String prefix = key + ":";
        for (int i = 0; i < lines.size(); i++) {
            if (lines.get(i).startsWith(prefix)) {
                lines.set(i, prefix + value);
                return;
            }
        }
        lines.add(prefix + value);
    }

    /** Append the option only when it is not already present. */
    public static void setDefault(String key, String value) {
        if (get(key) == null) {
            lines.add(key + ":" + value);
        }
    }

    /** Write the option set back to {@code options.txt}. */
    public static void save() {
        if (lines == null) {
            return;
        }
        StringBuilder content = new StringBuilder();
        for (int i = 0; i < lines.size(); i++) {
            content.append(lines.get(i));
            if (i + 1 < lines.size()) {
                content.append('\n');
            }
        }
        File file = new File(GameDirs.profile, "options.txt");
        try {
            File parent = file.getParentFile();
            if (parent != null) {
                parent.mkdirs();
            }
            try (OutputStreamWriter writer = new OutputStreamWriter(
                    new FileOutputStream(file), StandardCharsets.UTF_8)) {
                writer.write(content.toString());
            }
        } catch (IOException e) {
            System.err.println("Could not save options.txt");
            e.printStackTrace(System.err);
        }
        lines = null;
    }
}
