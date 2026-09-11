package meow.launcher;

import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;

/**
 * System class loader used to expose Minecraft libraries at runtime. It remains a plain
 * {@link URLClassLoader} (parent-first delegation) and mirrors every added location into the
 * {@code java.class.path} property for libraries that inspect it.
 */
public class MeowClassLoader extends URLClassLoader {

    public MeowClassLoader(ClassLoader parent) {
        super(new URL[0], parent);
    }

    @Override
    public void addURL(URL url) {
        super.addURL(url);
        String absolutePath;
        try {
            absolutePath = new File(url.toURI()).getAbsolutePath();
        } catch (Exception e) {
            absolutePath = new File(url.getPath()).getAbsolutePath();
        }
        String current = System.getProperty("java.class.path");
        if (current == null) {
            current = "";
        }
        System.setProperty("java.class.path", current + File.pathSeparator + absolutePath);
    }
}
