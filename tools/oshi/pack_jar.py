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

    # 自洽守卫（2026-09-16）：本打包器只装 classes 目录 ⇒ **永远不会有 `META-INF/versions/**`**。
    # 若传入的 MANIFEST 声明了 `Multi-Release: true`，产出就是「声称多版本 jar 却没有版本化条目」的
    # 坏件 —— bootstraplauncher 1.1.2（NeoForge 1.20.2）会在 SecureJar.from 里 Files.walk 该目录
    # 抛异常、启动即崩（实测事故）。这里统一剥掉并告警，防任何调用方复发。
    mf_txt = mf.decode('utf-8', 'replace')
    mf_lines = mf_txt.splitlines(keepends=True)
    kept = [l for l in mf_lines if not l.lstrip().lower().startswith('multi-release:')]
    if len(kept) != len(mf_lines):
        print("  pack_jar: stripped bogus 'Multi-Release' (jar has no META-INF/versions)",
              file=sys.stderr)
        # 字节级保留其余行的行尾（含末尾换行）——否则同输入产出会与历史值差几字节。
        mf = ''.join(kept).encode('utf-8')

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
