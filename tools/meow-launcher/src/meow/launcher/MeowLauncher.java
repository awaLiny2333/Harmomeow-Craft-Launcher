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

        if (System.getProperty("meowcraft.internal.keepForgeSplash") == null) {
            File splashFile = new File(GameDirs.game, "config/splash.properties");
            splashFile.getParentFile().mkdirs();
            if (splashFile.exists()) {
                writeText(splashFile, readText(splashFile).replace("enabled=true", "enabled=false"));
            } else {
                writeText(splashFile, "enabled=false");
            }
        }

        Account account = Account.load(args[0]);
        VersionJson version = VersionLoader.load(args[1]);
        System.out.println("Launching Minecraft " + version.id);
        Log4jConfig.apply(version);

        String[] gameArgs = ArgBuilder.build(account, version);
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
