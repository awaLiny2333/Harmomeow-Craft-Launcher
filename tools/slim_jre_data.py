#!/usr/bin/env python3
"""
slim_jre_data.py — strip redundant JRE .so from the meow_jre25.tar.gz data image.

Why: executable JRE .so are dlopen'ed from el1 only (jrelib HSP libs dir,
"OHOS_DL_DIR"). The filesDir copy of meow_jre25 is a pure java.home layout for
open()/mmap() of data (lib/modules, conf/, jvm.cfg, cacerts, tzdb.dat ...) and
el2 is noexec, so the 32 .so under ./lib (20.8 MB, byte-identical to el1) are
never the load source - pure redundancy (supply-chain C2 trim).

This tool regenerates meow_jre25.tar.gz without regular .so entries under ./lib
(./lib/server/libjvm.so included). Everything else is preserved member-for-
member (dirs, symlinks, data). Idempotent; prints stats; self-verifies.

Usage: python3 tools/slim_jre_data.py [<meow_jre25.tar.gz>]
Original archive is preserved in git history (rawfile is tracked).
"""

import hashlib
import io
import os
import sys
import tarfile

DEFAULT = "entry/src/main/resources/rawfile/meow_jre25.tar.gz"


def is_redundant(m):
    return m.isfile() and m.name.startswith("./lib/") and m.name.endswith(".so")


def slim(tar_bytes):
    tin = tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz")
    out = io.BytesIO()
    removed = []
    with tarfile.open(fileobj=out, mode="w:gz") as tout:
        for m in tin.getmembers():
            if is_redundant(m):
                removed.append((m.name, m.size))
                continue
            if m.isfile():
                tout.addfile(m, tin.extractfile(m))
            else:
                tout.addfile(m)
    return out.getvalue(), removed


def sha(b):
    return hashlib.sha256(b).hexdigest()


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.isfile(path):
        sys.exit("tar not found: %s" % path)
    with open(path, "rb") as f:
        orig = f.read()
    new, removed = slim(orig)
    # self-verify
    t = tarfile.open(fileobj=io.BytesIO(new), mode="r:gz")
    left = [m.name for m in t.getmembers() if is_redundant(m)]
    if left:
        sys.exit("verification failed: still present %s" % left)
    names = set(m.name for m in t.getmembers())
    if "./lib/modules" not in names:
        sys.exit("verification failed: ./lib/modules missing")
    tmp = path + ".new"
    with open(tmp, "wb") as f:
        f.write(new)
    os.replace(tmp, path)
    saved = sum(s for _, s in removed)
    print("slim OK")
    print("removed %d .so under ./lib (uncompressed %d bytes / %.1f MB)" %
          (len(removed), saved, saved / 1048576.0))
    print("tar before %s (%d bytes)" % (sha(orig), len(orig)))
    print("tar after  %s (%d bytes)" % (sha(new), len(new)))


if __name__ == "__main__":
    main()
