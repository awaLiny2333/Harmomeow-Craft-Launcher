#!/usr/bin/env python3
"""Assemble the shipped `meowcraft_extras.tar.gz` from per-generation artifacts.

The bundle carries every LWJGL generation side by side; ArkTS staging picks the
one matching the MC version and discards the other. Layout:

    ./launcher.jar                     (kept from --base-tar)
    ./gson-for-launcher.jar            (kept from --base-tar)
    ./lwjgl-<gen>.jar                  (one per --jar)
    ./lwjgl-natives-<gen>/liblwjgl*.so (one dir per --natives)

Deterministic: gzip mtime=0, tar mtime=0, mode 0644 (0755 for dirs), members
sorted. Pure python, so the agent can run it.

Usage:
  pack_extras.py --base-tar FILE --out FILE \
                 [--drop-prefix PREFIX]... [--jar NAME=PATH]... [--natives NAME=DIR]...
"""
import argparse
import gzip
import hashlib
import io
import os
import sys
import tarfile


def read_base(path):
    """name -> bytes for every regular file in the base tar (kept unless replaced)."""
    out = {}
    with tarfile.open(path, "r:gz") as tin:
        for m in tin.getmembers():
            if m.isfile():
                out[m.name.lstrip("./")] = tin.extractfile(m).read()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-tar", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--drop-prefix", action="append", default=[])
    ap.add_argument("--require", action="append", default=[])   # assert member present
    ap.add_argument("--jar", action="append", default=[])      # NAME=PATH
    ap.add_argument("--natives", action="append", default=[])  # NAME=DIR
    args = ap.parse_args()

    members = {}
    if os.path.exists(args.base_tar):
        members.update(read_base(args.base_tar))
    # drop every lwjgl jar the base tar carries -- the old single-generation `lwjgl.jar`
    # AND any per-generation `lwjgl-<ver>.jar`. Only the --jar set below ships. Without
    # this, retiring a generation would silently keep its stale jar in the bundle.
    for old in [k for k in members if k == "lwjgl.jar" or (k.startswith("lwjgl-") and k.endswith(".jar"))]:
        del members[old]
    # drop stale members (e.g. a previous layout's native subdirectories)
    for pfx in args.drop_prefix:
        for k in [k for k in members if k.startswith(pfx)]:
            del members[k]

    for spec in args.jar:
        name, _, path = spec.partition("=")
        members[name] = open(path, "rb").read()
    natives_names = []
    for spec in args.natives:
        name, _, path = spec.partition("=")
        natives_names.append(name)
        for fn in sorted(os.listdir(path)):
            members[f"{name}/{fn}"] = open(os.path.join(path, fn), "rb").read()

    buf = io.BytesIO()
    gzf = gzip.GzipFile(fileobj=buf, mode="wb", mtime=0)
    with tarfile.open(fileobj=gzf, mode="w", format=tarfile.GNU_FORMAT) as tout:
        # directories first (so extractors that skip implicit parents still work)
        for d in sorted(set([n for n in natives_names])):
            info = tarfile.TarInfo(f"./{d}")
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            info.mtime = 0
            tout.addfile(info)
        for name in sorted(members):
            data = members[name]
            info = tarfile.TarInfo(f"./{name}")
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            tout.addfile(info, io.BytesIO(data))
    gzf.close()

    blob = buf.getvalue()
    with open(args.out, "wb") as fh:
        fh.write(blob)

    print("members:")
    for name in sorted(members):
        sys.stdout.write("  ./%s  (%d bytes)\n" % (name, len(members[name])))
    # Build-time guard: every --require member must be present (we control packaging;
    # catch a missing generation jar here instead of at runtime on device).
    missing = [r for r in args.require if r not in members]
    if missing:
        sys.stderr.write("error: required member(s) missing from bundle: %s\n" % ", ".join(missing))
        return 1
    if args.require:
        print("required members present: %s" % ", ".join(sorted(args.require)))
    print("out: %s (%d bytes)  sha256=%s"
          % (args.out, len(blob), hashlib.sha256(blob).hexdigest()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
