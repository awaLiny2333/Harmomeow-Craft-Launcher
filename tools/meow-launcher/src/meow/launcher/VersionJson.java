package meow.launcher;

/**
 * Data transfer objects for the Mojang version descriptor. JSON key names are dictated by the
 * external format; only the fields the launcher consumes are modelled.
 */
public class VersionJson {
    public String id;
    public String inheritsFrom;
    public String mainClass;
    public String assets;
    public String type;
    public String minecraftArguments;

    public Logging logging;
    public Arguments arguments;
    public Library[] libraries;

    public static class Logging {
        public LoggingClient client;
    }

    public static class LoggingClient {
        public LoggingFile file;
    }

    public static class LoggingFile {
        public String id;
    }

    public static class Arguments {
        public Object[] game;
        public Object[] jvm;
    }

    public static class Library {
        public String name;
        public Downloads downloads;
    }

    public static class Downloads {
        public Artifact artifact;
    }

    public static class Artifact {
        public String path;
        public String url;
        public String sha1;
        public long size;
    }
}
