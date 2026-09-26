#!/usr/bin/env python3
"""Make jdk.zipfs's post-write chmod best-effort.

Why (2026-09-27, phone): Fabric's first-launch remap (tinyremapper) writes its
`.fabric/remappedJars/<...>/*.jar` through jdk.zipfs. `ZipFileSystem.sync()`
unconditionally re-applies the ORIGINAL file's POSIX permissions to the freshly
written temp file. On HarmonyOS the game dir lives on user storage (FUSE/hmdfs)
which REJECTS chmod (EPERM) -> Fabric aborts with
  "error remapping game jars ... Operation not permitted"
We wrap that one call so a chmod failure is ignored: the temp file then just keeps
its default umask permissions. The zip BYTES are unchanged by this.

Usage:  zipfs_chmod_best_effort.py <path to ZipFileSystem.java>
Exit codes: 0 ok (patched or already patched) / 2 anchor not found (fail loudly).
"""
import sys

OLD = """        if (attrs != null) {
            Files.setPosixFilePermissions(tmpFile, attrs.permissions());
        }
        Files.move(tmpFile, zfpath, REPLACE_EXISTING);"""

NEW = """        if (attrs != null) {
            try {
                Files.setPosixFilePermissions(tmpFile, attrs.permissions());
            } catch (IOException | UnsupportedOperationException e) {
                // Meowcraft/OHOS: some filesystems (e.g. HarmonyOS user storage /
                // FUSE) reject chmod with EPERM. Best-effort: keep the temp file's
                // default umask permissions instead of aborting the whole zip write.
                // The zip bytes are not changed by this.
            }
        }
        Files.move(tmpFile, zfpath, REPLACE_EXISTING);"""


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: zipfs_chmod_best_effort.py <ZipFileSystem.java>\n")
        return 2
    path = argv[1]
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as e:
        sys.stderr.write("zipfs chmod patch: cannot read %s: %s\n" % (path, e))
        return 2
    if NEW in src:
        print("zipfs chmod patch: already applied")
        return 0
    if OLD not in src:
        sys.stderr.write("zipfs chmod patch: ANCHOR NOT FOUND in %s\n" % path)
        return 2
    open(path, "w", encoding="utf-8").write(src.replace(OLD, NEW, 1))
    print("zipfs chmod patch: applied to %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
