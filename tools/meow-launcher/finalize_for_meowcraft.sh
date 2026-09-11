#!/bin/sh
# Finalize the clean-room launcher.jar into the shipped meowcraft_extras.tar.gz.
#
# Layout-aware: the shipped tar carries multiple LWJGL generations
# (lwjgl-3.3.3.jar / lwjgl-3.4.3.jar) + an already-shaded gson-for-launcher.jar.
# This replaces ONLY launcher.jar with the freshly built one, re-shading its
# gson references com.google.gson -> meow.gson to match the existing shaded
# gson-for-launcher.jar; every other member stays byte-identical.
#
# (The old single-`lwjgl.jar` swapper is gone; the previous version rebuilt a
#  3-member tar and therefore failed on the multi-generation layout.)
#
# Pure python -> the agent CAN run this. javac (build_meow_launcher.sh) is the
# only user-run step.
#
# Usage: sh finalize_for_meowcraft.sh [<launcher.jar>]
# Default launcher.jar: <outer>/stuffs/research/meow_launcher_build/out/launcher.jar
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUTER="$(cd "$ROOT/.." && pwd)"
LJ="$OUTER/stuffs/research/meow_launcher_build/out/launcher.jar"
[ "$#" -gt 0 ] && LJ="$1"

TAR="$ROOT/entry/src/main/resources/rawfile/meowcraft_extras.tar.gz"
TOOLS="$ROOT/tools"

[ -f "$LJ" ]  || { echo "launcher.jar not found: $LJ" >&2; exit 1; }
[ -f "$TAR" ] || { echo "tar not found: $TAR" >&2; exit 1; }

python3 - "$TOOLS" "$LJ" "$TAR" <<'PY'
import gzip, io, os, sys, tarfile, zipfile
tools_dir, lj_path, tar_path = sys.argv[1:4]
sys.path.insert(0, tools_dir)
import relocate_gson as rg   # reuse rewrite_jar / sha (module has no side effects)

orig = open(tar_path, "rb").read()
tin = tarfile.open(fileobj=io.BytesIO(orig), mode="r:gz")
members = {}
for m in tin.getmembers():
    if m.isfile():
        members[m.name.lstrip("./")] = tin.extractfile(m).read()

if "gson-for-launcher.jar" not in members:
    sys.exit("expected shaded gson-for-launcher.jar in tar; got %s" % sorted(members))
if "launcher.jar" not in members:
    sys.exit("expected launcher.jar in tar")

new_launcher, hits = rg.rewrite_jar(open(lj_path, "rb").read())
if hits == 0:
    sys.exit("relocation produced no hits (does launcher.jar reference com.google.gson?)")

# Repack: replace only launcher.jar; keep every other member byte-identical; deterministic.
out = io.BytesIO()
gz = gzip.GzipFile(fileobj=out, mode="wb", mtime=0)
with tarfile.open(fileobj=gz, mode="w") as tout:
    for m in tin.getmembers():
        key = m.name.lstrip("./")
        if key == "launcher.jar":
            name, raw = "./launcher.jar", new_launcher
        else:
            name, raw = m.name, members.get(key, b"")
        info = tarfile.TarInfo(name)
        info.size = len(raw)
        info.mode = m.mode
        info.mtime = m.mtime
        info.type = m.type
        tout.addfile(info, io.BytesIO(raw))
gz.close()
new = out.getvalue()

# ---- self-verify ----
t = tarfile.open(fileobj=io.BytesIO(new), mode="r:gz")
names = [n.lstrip("./") for n in t.getnames()]
assert "launcher.jar" in names, names
for n in names:
    if n == "launcher.jar":
        continue
    assert rg.sha(t.extractfile("./" + n).read()) == rg.sha(members[n]), "member changed: %s" % n
lz = zipfile.ZipFile(io.BytesIO(t.extractfile("./launcher.jar").read()))
for n in lz.namelist():
    if n.endswith(".class"):
        assert b"com/google/gson" not in lz.read(n), "stale gson ref in %s" % n
assert any(b"meow/gson" in lz.read(n) for n in lz.namelist() if n.endswith(".class")), \
    "launcher.jar exposes no meow/gson reference after relocation"

with open(tar_path + ".new", "wb") as f:
    f.write(new)
os.replace(tar_path + ".new", tar_path)

print("finalize OK  launcher hits=%d" % hits)
print("members:")
for n in names:
    print("  %s" % n)
PY

echo "shipped -> $TAR"
sha256sum "$TAR"
echo "== next: bump EXTRAS_VERSION in LaunchDefaults.ets, then devecocli build + run"
