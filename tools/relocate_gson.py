#!/usr/bin/env python3
"""
relocate_gson.py — shade the bundled gson for the launcher only.

Problem: the bundled `gson-2.13.1.jar` shares the flat staged classpath with
Minecraft's own gson (declared in every version's libraries). Measured on
device: 165 gson classes load from the bundled jar, 0 from MC's own -> the
bundled gson silently shadows the version-declared one.

Fix: relocate the bundled gson's package `com.google.gson` -> `meow.gson` and
rewrite `launcher.jar`'s references accordingly. Then:
  * launcher.jar  -> loads `meow.gson.*`  (its own private gson)
  * Minecraft     -> loads `com.google.gson.*` from its own declared jar
No class name is shared anymore, so there is nothing to shadow.

What it does to `meowcraft_extras.tar.gz` (in place):
  1. reads gson-2.13.1.jar + launcher.jar from the tar
  2. relocates gson (class entries moved + constant-pool Utf8 rewritten;
     drops META-INF/versions/9/module-info.class, unused on the classpath)
     -> member renamed to `gson-for-launcher.jar`
  3. rewrites `com/google/gson`->`meow/gson` in launcher.jar's classes
  4. repacks the tar, leaving every other member byte-identical
  5. self-verifies (relocated names present, old names gone, other members same)

Usage:
    python3 tools/relocate_gson.py [<meowcraft_extras.tar.gz>]

Idempotency: refuses to run if the tar already contains `gson-for-launcher.jar`.
"""

import hashlib
import io
import os
import sys
import tarfile
import zipfile

DEFAULT_TAR = "entry/src/main/resources/rawfile/meowcraft_extras.tar.gz"
OLD_GSON = "gson-2.13.1.jar"
NEW_GSON = "gson-for-launcher.jar"
OLD_PKG_SLASH = b"com/google/gson"
NEW_PKG_SLASH = b"meow/gson"
OLD_PKG_DOT = b"com.google.gson"
NEW_PKG_DOT = b"meow.gson"
DROP_MEMBERS = {"META-INF/versions/9/module-info.class"}

# Constant-pool tag payload sizes (bytes after the tag), excluding Utf8.
CP_FIXED = {7: 2, 8: 2, 16: 2, 19: 2, 20: 2, 15: 3,
            3: 4, 4: 4, 9: 4, 10: 4, 11: 4, 12: 4, 17: 4, 18: 4,
            5: 8, 6: 8}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def rename_name(name):
    """Relocate an entry name (slashes only)."""
    return name.replace(OLD_PKG_SLASH.decode(), NEW_PKG_SLASH.decode())


def relocate_class(data):
    """Rewrite constant-pool Utf8 strings in a class file. Returns (bytes, n)."""
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("not a class file")
    out = bytearray(data[:8])            # magic + minor + major
    cp_count = int.from_bytes(data[8:10], "big")
    out += data[8:10]
    off = 10
    idx = 1
    hits = 0
    while idx < cp_count:
        tag = data[off]
        if tag == 1:                     # CONSTANT_Utf8
            ln = int.from_bytes(data[off + 1:off + 3], "big")
            s = data[off + 3:off + 3 + ln]
            ns = s.replace(OLD_PKG_SLASH, NEW_PKG_SLASH).replace(OLD_PKG_DOT, NEW_PKG_DOT)
            if ns != s:
                hits += 1
            out += b"\x01" + len(ns).to_bytes(2, "big") + ns
            off += 3 + ln
        else:
            if tag not in CP_FIXED:
                raise ValueError("unknown constant pool tag %d at %d" % (tag, idx))
            n = CP_FIXED[tag]
            out += data[off:off + 1 + n]
            off += 1 + n
            if tag in (5, 6):            # Long/Double take two slots
                idx += 1
        idx += 1
    out += data[off:]                    # rest of the class (cp indices unchanged)
    return bytes(out), hits


def _new_info(info, name):
    ni = zipfile.ZipInfo(name, date_time=info.date_time)
    ni.compress_type = info.compress_type
    ni.external_attr = info.external_attr
    ni.internal_attr = info.internal_attr
    ni.create_system = info.create_system
    return ni


def rewrite_jar(jar_bytes, drop=()):
    """Relocate package refs in every class + move entries. Returns (bytes, hits)."""
    zin = zipfile.ZipFile(io.BytesIO(jar_bytes))
    out = io.BytesIO()
    hits = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in zin.infolist():
            if info.filename in drop:
                continue
            raw = zin.read(info.filename)
            name = rename_name(info.filename)
            if info.filename.endswith(".class"):
                raw, n = relocate_class(raw)
                hits += n
            zout.writestr(_new_info(info, name), raw)
    return out.getvalue(), hits


def repack_tar(tar_bytes, new_members):
    """Replace members by exact name; keep everything else byte-identical."""
    tin = tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz")
    out = io.BytesIO()
    import gzip
    gz = gzip.GzipFile(fileobj=out, mode="wb", mtime=0)
    replaced = set()
    with tarfile.open(fileobj=gz, mode="w") as tout:
        for m in tin.getmembers():
            key = m.name[2:] if m.name.startswith("./") else m.name
            raw = tin.extractfile(m).read() if m.isfile() else b""
            if key in new_members:
                name = new_members[key][0]
                raw = new_members[key][1]
                replaced.add(key)
            else:
                name = m.name
            info = tarfile.TarInfo(name)
            info.size = len(raw)
            info.mode = m.mode
            info.mtime = m.mtime
            info.type = m.type
            info.linkname = m.linkname
            tout.addfile(info, io.BytesIO(raw))
    gz.close()
    return out.getvalue(), replaced


def main():
    tar_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TAR
    if not os.path.isfile(tar_path):
        sys.exit("tar not found: %s" % tar_path)
    with open(tar_path, "rb") as f:
        orig = f.read()
    members = {}
    tin = tarfile.open(fileobj=io.BytesIO(orig), mode="r:gz")
    for m in tin.getmembers():
        if m.isfile():
            members[m.name[2:] if m.name.startswith("./") else m.name] = \
                tin.extractfile(m).read()
    if NEW_GSON in members:
        sys.exit("already relocated (%s present)" % NEW_GSON)
    if OLD_GSON not in members or "launcher.jar" not in members:
        sys.exit("expected %s + launcher.jar in tar" % OLD_GSON)

    gson_new, gson_hits = rewrite_jar(members[OLD_GSON], drop=DROP_MEMBERS)
    launch_new, launch_hits = rewrite_jar(members["launcher.jar"])
    if gson_hits == 0 or launch_hits == 0:
        sys.exit("relocation produced no hits (gson=%d launcher=%d)" % (gson_hits, launch_hits))

    new, replaced = repack_tar(orig, {OLD_GSON: ("./" + NEW_GSON, gson_new),
                                      "launcher.jar": ("./launcher.jar", launch_new)})
    if replaced != {OLD_GSON, "launcher.jar"}:
        sys.exit("tar repack missed members: %s" % sorted(replaced))

    # ---- self-verify ----
    t = tarfile.open(fileobj=io.BytesIO(new), mode="r:gz")
    names = [n[2:] if n.startswith("./") else n for n in t.getnames()]
    assert NEW_GSON in names and OLD_GSON not in names, names
    assert sha(t.extractfile("./lwjgl.jar").read()) == sha(members["lwjgl.jar"]), "lwjgl changed"
    gz2 = zipfile.ZipFile(io.BytesIO(t.extractfile("./" + NEW_GSON).read()))
    gnames = gz2.namelist()
    assert "meow/gson/Gson.class" in gnames and "com/google/gson/Gson.class" not in gnames
    assert not any(n.startswith("com/google/gson/") for n in gnames)
    lz = zipfile.ZipFile(io.BytesIO(t.extractfile("./launcher.jar").read()))
    for n in lz.namelist():
        if n.endswith(".class"):
            assert b"com/google/gson" not in lz.read(n), "stale gson ref in %s" % n
    assert any(b"meow/gson" in lz.read(n)
               for n in lz.namelist() if n.endswith(".class")), \
        "launcher.jar exposes no meow/gson reference after relocation"

    with open(tar_path + ".new", "wb") as f:
        f.write(new)
    os.replace(tar_path + ".new", tar_path)
    with open(tar_path, "rb") as f:
        assert sha(f.read()) == sha(new)

    print("relocate OK  gson hits=%d  launcher hits=%d" % (gson_hits, launch_hits))
    print("tar before %s" % sha(orig))
    print("tar after  %s" % sha(new))
    print("members:")
    for n in names:
        print("  %s" % n)


if __name__ == "__main__":
    main()
