#!/usr/bin/env python3
"""确定性打包 java.home 数据目录为 meow_jre25.tar.gz（供逐字节复现）。

规范化：条目按名排序；mtime=0；uid/gid=0；uname/gname 清空；gzip header mtime=0。
用法: pack_jre_data.py --home <home目录> --out <meow_jre25.tar.gz>
"""
import argparse
import gzip
import os
import tarfile


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    home = a.home
    # 收集目录与文件（相对路径，'./' 前缀），整体排序
    entries = []
    for root, dirs, files in os.walk(home):
        dirs.sort()
        for d in dirs:
            entries.append(os.path.relpath(os.path.join(root, d), home))
        for f in files:
            entries.append(os.path.relpath(os.path.join(root, f), home))
    entries.sort()

    with open(a.out, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tf:
                for rel in entries:
                    p = os.path.join(home, rel)
                    ti = tf.gettarinfo(p, arcname="./" + rel)
                    ti.mtime = 0
                    ti.uid = ti.gid = 0
                    ti.uname = ti.gname = ""
                    if ti.isreg():
                        with open(p, "rb") as fh:
                            tf.addfile(ti, fh)
                    else:
                        tf.addfile(ti)
    print("wrote", a.out, os.path.getsize(a.out), "bytes")


if __name__ == "__main__":
    main()
