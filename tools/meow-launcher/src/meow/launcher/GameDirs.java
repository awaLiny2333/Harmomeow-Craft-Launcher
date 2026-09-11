package meow.launcher;

/**
 * Directory model derived from the launch environment. The property keys are part of the
 * external launch contract and must not be renamed.
 */
public final class GameDirs {
    /** Launcher home (accounts and run data). */
    public static final String home = System.getProperty("MEOWCRAFT_HOME");
    /** Game directory, i.e. the .minecraft root. */
    public static final String game = System.getProperty("MEOWCRAFT_GAME_DIR");
    /** Working/profile directory used for options.txt and legacy paths. */
    public static final String profile = System.getProperty("user.dir");
    /** Optional bundle root; may be absent. */
    public static final String bundle = System.getProperty("BUNDLE_PATH");
    /** Native library directory. */
    public static final String natives = System.getProperty("java.library.path");

    public static final String accounts = home + "/accounts";
    public static final String versions = game + "/versions";
    public static final String libraries = game + "/libraries";
    public static final String assets = game + "/assets";

    private GameDirs() {
    }
}
