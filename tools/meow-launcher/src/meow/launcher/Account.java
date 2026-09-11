package meow.launcher;

import com.google.gson.Gson;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.UUID;

/**
 * Account record. Field names are the on-disk JSON keys written by the ArkTS account layer.
 *
 * <p>Offline accounts may omit {@code profileId}; the launcher then derives the canonical
 * offline UUID ({@code UUID.nameUUIDFromBytes("OfflinePlayer:" + name)}) exactly like the
 * vanilla client, instead of trusting a (syntactically valid but wrong) placeholder.
 * Microsoft accounts carry a real UUID + token from the MS login chain.
 */
public class Account {
    private static final Gson GSON = new Gson();
    /** Offline access token: the vanilla client requires non-null, never validates the value. */
    private static final String OFFLINE_ACCESS_TOKEN = "0";

    public String accessToken;
    public String clientToken;
    public String profileId;
    public String username;
    public String xuid;

    /** Load {@code <accounts>/<name>.json} and normalise the fields (never returns null). */
    public static Account load(String name) throws IOException {
        String path = GameDirs.accounts + "/" + name + ".json";
        String json = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8);
        Account account = GSON.fromJson(json, Account.class);
        if (account == null) {
            account = new Account();
        }
        if (account.username == null || account.username.isEmpty()) {
            account.username = name;
        }
        if (account.accessToken == null || account.accessToken.isEmpty()) {
            account.accessToken = OFFLINE_ACCESS_TOKEN;
        }
        if (account.clientToken == null) {
            account.clientToken = "";
        }
        // Empty / all-zero / unparsable -> derive the canonical offline UUID from the name.
        if (!isUsableUuid(account.profileId)) {
            account.profileId = offlineUuid(account.username);
        }
        if (account.xuid == null) {
            account.xuid = "";
        }
        return account;
    }

    /** Canonical offline (type-3) UUID: md5("OfflinePlayer:" + name) — the vanilla derivation. */
    public static String offlineUuid(String name) {
        return UUID.nameUUIDFromBytes(("OfflinePlayer:" + name).getBytes(StandardCharsets.UTF_8))
                .toString();
    }

    /** Usable when the value parses (dashed or bare 32-hex) and is not the all-zero placeholder. */
    private static boolean isUsableUuid(String value) {
        if (value == null || value.isEmpty()) {
            return false;
        }
        try {
            UUID uuid = parseUuid(value);
            return uuid.getMostSignificantBits() != 0L || uuid.getLeastSignificantBits() != 0L;
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    /** Parse a UUID, tolerating the 32-hex (no dashes) form used by Minecraft services. */
    private static UUID parseUuid(String value) {
        String v = value.trim();
        if (v.length() == 32 && v.indexOf('-') < 0) {
            v = v.substring(0, 8) + "-" + v.substring(8, 12) + "-" + v.substring(12, 16) + "-"
                    + v.substring(16, 20) + "-" + v.substring(20);
        }
        return UUID.fromString(v);
    }
}
