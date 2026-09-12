#!/usr/bin/env python3
"""校验一套 JRE .so 的未定义符号是否被满足（给 glibc→musl 魔改做自检）。

- 只查 GLOBAL 未定义；WEAK 运行时归 0，忽略。
- 提供者 = OHOS libc ∪ 目标目录内所有 lib ∪ --extra 指定的外部件（libz / libc++_shared / libfreetype 等）。

用法:
  verify_symbols.py <libdir> [--libc <libc.so>] [--extra <a.so> [--extra <b.so> ...]]
"""
import argparse
import subprocess
from pathlib import Path


def dyn(path):
    out = subprocess.run(["readelf", "--dyn-syms", "--wide", str(path)],
                         capture_output=True, text=True).stdout
    defined, undef = set(), set()
    for line in out.splitlines():
        s = line.strip()
        if not s or not s[0].isdigit():
            continue
        parts = s.split()
        if len(parts) < 8:
            continue
        bind, ndx, name = parts[4], parts[6], parts[7].split("@")[0]
        if ndx == "UND":
            if bind != "WEAK":
                undef.add(name)
        else:
            defined.add(name)
    return defined, undef


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("libdir")
    ap.add_argument("--libc", default=None, help="OHOS libc.so（默认从 OHOS_SDK_NATIVE 推断）")
    ap.add_argument("--extra", action="append", default=[],
                    help="额外提供者 .so（可多次）")
    args = ap.parse_args()

    libc = args.libc
    if libc is None:
        import os
        sdk = os.environ.get("OHOS_SDK_NATIVE",
                             str(Path.home() / "devecow/deveco_tools/sdk/default/openharmony/native"))
        libc = str(Path(sdk) / "sysroot/usr/lib/aarch64-linux-ohos/libc.so")

    libdir = Path(args.libdir)
    libs = sorted(libdir.glob("*.so"))
    provide = set(dyn(libc)[0])
    for f in libs:
        provide |= dyn(f)[0]
    for e in args.extra:
        if Path(e).exists():
            provide |= dyn(e)[0]
        else:
            print(f"  ⚠️  --extra 不存在，已忽略（可能是路径写错）: {e}")

    bad = 0
    for f in libs:
        miss = dyn(f)[1] - provide
        if miss:
            bad += 1
            print(f"  ✗ {f.name}: 缺 {len(miss)} -> {sorted(miss)[:10]}")
        else:
            print(f"  ✓ {f.name}")
    print("结果:", "PASS" if bad == 0 else f"FAIL {bad}")
    raise SystemExit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
