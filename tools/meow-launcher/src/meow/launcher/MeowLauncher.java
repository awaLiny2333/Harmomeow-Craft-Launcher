package meow.launcher;

import java.io.File;
import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.jar.Attributes;
import java.util.jar.JarFile;
import java.util.jar.Manifest;

/**
 * Entry point for the Meowcraft launcher. It prepares the run environment and then reflectively
 * hands control to the Minecraft main class.
 */
public final class MeowLauncher {

    private MeowLauncher() {
    }

    public static void main(String[] args) throws Throwable {
        Thread.currentThread().setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread thread, Throwable throwable) {
                throwable.printStackTrace(System.err);
                System.exit(0);
            }
        });

        if (args.length > 0 && "-jar".equals(args[0])) {
            launchJar(args);
        } else {
            launchMinecraft(args);
        }
    }

    /** Run a user supplied jar through its manifest {@code Main-Class}. */
    private static void launchJar(String[] args) throws Throwable {
        File jar = new File(args[1]);
        try (JarFile jarFile = new JarFile(jar)) {
            Manifest manifest = jarFile.getManifest();
            String mainClass = manifest == null ? null
                    : manifest.getMainAttributes().getValue(Attributes.Name.MAIN_CLASS);
            if (mainClass == null) {
                System.err.println("No Main-Class in manifest: " + jar);
                return;
            }
            Class<?> clazz = ClassLoader.getSystemClassLoader().loadClass(mainClass);
            Method method = clazz.getMethod("main", String[].class);
            method.invoke(null, new Object[]{Arrays.copyOfRange(args, 2, args.length)});
        }
    }

    /** Prepare options/config, resolve the version and launch the game main class. */
    public static void launchMinecraft(String[] args) throws Throwable {
        System.setProperty("appdir", "./spiral");
        System.setProperty("resource_dir", "./spiral/rsrc");

        String screenSize = System.getProperty("cacio.managed.screensize");
        if (screenSize != null) {
            System.setProperty("glfw.windowSize", screenSize);
        }

        McOptions.load();
        McOptions.set("fullscreen", "false");
        if (screenSize != null) {
            String[] dimensions = screenSize.split("x");
            if (dimensions.length == 2) {
                McOptions.set("overrideWidth", dimensions[0]);
                McOptions.set("overrideHeight", dimensions[1]);
            }
        }
        McOptions.setDefault("mipmapLevels", "0");
        McOptions.setDefault("particles", "1");
        McOptions.setDefault("renderDistance", "2");
        McOptions.setDefault("simulationDistance", "5");
        McOptions.save();

        /*
         * ★2026-09-29 删除：这里原本有一条"替用户关掉 Forge splash"的策略 ——
         *   若系统属性 `meowcraft.internal.keepForgeSplash` 未设，就把 `<gameRoot>/config/splash.properties`
         *   写成 `enabled=false`。
         *
         * 【为什么当初存在】它是从被替换掉的 **PojavLauncher_iOS 派生 launcher.jar** 继承来的行为契约
         *   （原属性名 `pojav.internal.keepForgeSplash`，见 notes/20-design/launch/launcher净室-设计.md:55），
         *   目的：**绕开 FML 控制台 splash 在 GL 栈不支持"共享对象的第二上下文"时的崩溃**。
         *
         * 【为什么删掉】
         *   ① **在我们的目录布局下从未生效**：它写的是 `<gameRoot>/config/splash.properties`，
         *      而 FML 读的是**相对路径** `config/splash.properties`（CWD = `user.dir` = 每实例隔离目录）
         *      ⇒ 写错了地方（实测：1.12.2 实例里 FML 自己另生成了 `enabled=true`）。
         *   ② **违反兼容铁律**：它写进了用户的游戏目录（notes/00-current/工程与规范.md「兼容铁律」）。
         *   ③ **与 HMCL 不一致**：HMCL 完全不碰 splash（`ref/HMCL/.../DefaultLauncher.java` 只加两条
         *      `-Dfml.ignoreInvalidMinecraftCertificates/-Dfml.ignorePatchDiscrepancies`）⇒
         *      按"与 HMCL 双向兼容"的口径，我们也不该做。
         *   ④ **真正的问题已在正确的地方修好**：我们的 LWJGL2 shim 现在**尊重 `share` 实参**
         *      （上游契约 `nCreate(peer, attribs, shared_context_handle)`），splash 的第二上下文是**真的**
         *      —— 2026-09-29 实机日志：`shared ctx created: share=0x… -> ctx=0x… slot=0x…`，
         *      且 `eglMakeCurrent failed`/`make-current failed` 均归零、splash 正常显示。
         */

        Account account = Account.load(args[0]);
        VersionJson version = VersionLoader.load(args[1]);
        System.out.println("Launching Minecraft " + version.id);
        Log4jConfig.apply(version);

        String[] gameArgs = (args.length > 2)
                ? ArgBuilder.build(account, version, java.util.Arrays.copyOfRange(args, 2, args.length))
                : ArgBuilder.build(account, version, new String[0]);
        String classpath = LibraryResolver.build(version);
        System.out.println("Args init finished. Now starting game");

        // Vanilla 侧自研 system classloader（MeowClassLoader）允许运行期追加 classpath；
        // 加载器实例（Fabric）走默认 app classloader（-cp 已齐全），此时不追加，直接用系统 CL 加载主类。
        ClassLoader systemLoader = ClassLoader.getSystemClassLoader();
        if (systemLoader instanceof MeowClassLoader) {
            MeowClassLoader loader = (MeowClassLoader) systemLoader;
            String javaClassPath = System.getProperty("java.class.path");
            if (javaClassPath != null) {
                for (String entry : javaClassPath.split(File.pathSeparator)) {
                    if (!entry.isEmpty()) {
                        loader.addURL(new File(entry).toURI().toURL());
                    }
                }
            }
            for (String entry : classpath.split(":")) {
                if (!entry.isEmpty()) {
                    loader.addURL(new File(entry).toURI().toURL());
                }
            }
        }

        Class<?> mainClass = systemLoader.loadClass(version.mainClass);
        Method mainMethod = mainClass.getMethod("main", String[].class);
        mainMethod.invoke(null, new Object[]{gameArgs});
    }

    private static String readText(File file) throws IOException {
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    private static void writeText(File file, String text) throws IOException {
        File parent = file.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        Files.write(file.toPath(), text.getBytes(StandardCharsets.UTF_8));
    }
}
