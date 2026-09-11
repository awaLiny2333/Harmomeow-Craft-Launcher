#!/usr/bin/env python3
"""Create a deterministic jar from a classes dir + manifest.

Usage:  pack_jar.py <classes-dir> <manifest-file> <out.jar>

All entries get a fixed timestamp and are written in sorted order, so the same
inputs always produce a byte-identical jar (the JDK `jar` tool stamps META-INF/
and MANIFEST.MF with the current time, which breaks reproducibility).
"""
import os
import sys
import zipfile

FIXED = (2020, 1, 1, 0, 0, 0)


def main():
    classes, manifest, out = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(manifest, 'rb') as f:
        mf = f.read()

    entries = []
    for root, _dirs, files in os.walk(classes):
        for name in files:
            path = os.path.join(root, name)
            arc = os.path.relpath(path, classes).replace(os.sep, '/')
            entries.append((arc, path))
    entries.sort()

    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        zi = zipfile.ZipInfo('META-INF/MANIFEST.MF', FIXED)
        zi.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(zi, mf)
        for arc, path in entries:
            with open(path, 'rb') as f:
                data = f.read()
            zi = zipfile.ZipInfo(arc, FIXED)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)


if __name__ == '__main__':
    main()
