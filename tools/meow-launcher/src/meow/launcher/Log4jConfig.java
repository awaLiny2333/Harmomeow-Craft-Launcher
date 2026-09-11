package meow.launcher;

/**
 * Selects the log4j configuration file for the version being launched and publishes it through the
 * {@code log4j.configurationFile} system property.
 */
public final class Log4jConfig {
    private static final String CLIENT_1_12 = "client-1.12.xml";
    private static final String CLIENT_1_7 = "client-1.7.xml";

    private Log4jConfig() {
    }

    /** Apply the configuration selection; absent bundle roots or descriptors are skipped. */
    public static void apply(VersionJson version) {
        if (version == null || version.logging == null || version.logging.client == null
                || version.logging.client.file == null) {
            return;
        }
        String id = version.logging.client.file.id;
        if (id == null) {
            return;
        }

        String configPath;
        if (CLIENT_1_12.equals(id)) {
            if (GameDirs.bundle == null) {
                return;
            }
            configPath = GameDirs.bundle + "/security/log4j-rce-patch-1.12.xml";
        } else if (CLIENT_1_7.equals(id)) {
            if (GameDirs.bundle == null) {
                return;
            }
            configPath = GameDirs.bundle + "/security/log4j-rce-patch-1.7.xml";
        } else {
            configPath = GameDirs.game + "/" + id;
        }
        System.setProperty("log4j.configurationFile", configPath);
    }
}
