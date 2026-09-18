package meow.launcher;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Expands the Minecraft game arguments from the version descriptor using the runtime macro table.
 */
public final class ArgBuilder {
    private static final String DEMO_PREFIX = "Demo.";
    // userType is always "msa": HMCL uses msa for offline too (its notes warn that "mojang"
    // can yield invalid-session / disconnect when playing online). 1.21+ has no --userType.
    private static final String MSA_USER_TYPE = "msa";

    private ArgBuilder() {
    }

    /**
     * Assemble the game arguments for {@code version} in the order the client expects.
     * {@code extraGameArgs} are appended verbatim at the end (the launcher's own arguments after
     * the account/version pair, e.g. {@code --graphicsBackend vulkan}); MC's parser is
     * order-independent for named options, so appending is safe.
     */
    public static String[] build(Account account, VersionJson version, String[] extraGameArgs) {
        boolean demo = account.username != null && account.username.startsWith(DEMO_PREFIX);
        String playerName = demo ? account.username.substring(DEMO_PREFIX.length()) : account.username;
        String versionName = (version.inheritsFrom != null && !version.inheritsFrom.isEmpty())
                ? version.inheritsFrom : version.id;

        File gameDir = new File(GameDirs.profile);
        gameDir.mkdirs();

        Map<String, String> macros = new HashMap<>();
        macros.put("auth_session", account.accessToken);
        macros.put("auth_access_token", account.accessToken);
        macros.put("auth_player_name", playerName);
        macros.put("auth_uuid", stripDashes(account.profileId));
        macros.put("auth_xuid", account.xuid);
        macros.put("assets_root", GameDirs.assets);
        macros.put("game_assets", GameDirs.assets);
        String assetIndexName = (version.assets != null && !version.assets.isEmpty())
                ? version.assets
                : (version.assetIndex != null ? version.assetIndex.id : null);
        macros.put("assets_index_name", assetIndexName);
        macros.put("clientid", account.clientToken);
        macros.put("game_directory", gameDir.getAbsolutePath());
        macros.put("user_properties", "{}");
        macros.put("user_type", MSA_USER_TYPE);
        macros.put("version_name", versionName);
        macros.put("version_type", version.type);
        macros.put("natives_directory", GameDirs.natives);

        String[] rawTokens = collectGameTokens(version, macros);
        List<String> args = new ArrayList<>();
        if (demo) {
            args.add("--demo");
        }
        for (String token : rawTokens) {
            if (token.isEmpty()) {
                continue;
            }
            args.add(expand(token, macros));
        }
        if (extraGameArgs != null) {
            for (String extra : extraGameArgs) {
                if (extra != null && !extra.isEmpty()) {
                    args.add(extra);
                }
            }
        }
        return args.toArray(new String[0]);
    }

    /** Keep only string entries (rule objects are ignored) or fall back to legacy arguments. */
    private static String[] collectGameTokens(VersionJson version, Map<String, String> macros) {
        if (version.arguments != null && version.arguments.game != null) {
            List<String> tokens = new ArrayList<>();
            for (Object arg : version.arguments.game) {
                if (arg instanceof String) {
                    tokens.add((String) arg);
                }
            }
            return tokens.toArray(new String[0]);
        }
        if (version.minecraftArguments != null && !version.minecraftArguments.isEmpty()) {
            return version.minecraftArguments.split(" ");
        }
        return new String[0];
    }

    private static String stripDashes(String value) {
        return value == null ? "" : value.replace("-", "");
    }

    private static String expand(String token, Map<String, String> macros) {
        String result = token;
        for (Map.Entry<String, String> macro : macros.entrySet()) {
            String value = macro.getValue() == null ? "" : macro.getValue();
            result = result.replace("${" + macro.getKey() + "}", value);
        }
        return result;
    }
}
