#!/usr/bin/env python3
"""原地改写 ELF .dynstr 里的库名（不做任何重排/填充）。

为何不用 patchelf：patchelf 替换带 VERNEED 条目的 NEEDED（如 libc.so.6）会**重排文件并用 'X' 填充**，
导致 OHOS loader 把符号名读进填充区 → 打印 X 串 / 重定位失败。

本脚本把替换串**原地覆盖**（新名不得长于旧名，全部补 '\\0'），文件大小与所有偏移不变：
- DT_NEEDED 与 DT_VERNEED 的 vn_file 指向同一 .dynstr 偏移 → 一处替换同时更新两者，无需改偏移。
"""
import struct
import sys
from pathlib import Path

# 旧名 -> 新名（新名必须 <= 旧名长度；全部原地覆盖，不改任何偏移/大小）
MAP = {
    "libc.so.6": "libc6.so",                # -> 兼容层（既满足依赖，又把 shim 注入每个 lib）
    "ld-linux-aarch64.so.1": "libc6.so",    # OHOS 无 glibc 解释器；同一兼容层
    "libpthread.so.0": "libc.so",
    "libdl.so.2": "libc.so",
    "librt.so.1": "libc.so",
    "libm.so.6": "libc.so",
    "libz.so.1": "libz.so",
    "libfreetype.so.6": "libfreetype.so",
}


def patch(path: Path) -> int:
    data = bytearray(path.read_bytes())
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise SystemExit(f"not ELF64-LE: {path}")
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x3E)[0]

    def sh(i):
        off = e_shoff + i * e_shentsize
        name, typ = struct.unpack_from("<II", data, off)
        flags = struct.unpack_from("<Q", data, off + 8)[0]
        addr, sh_off, sh_size = struct.unpack_from("<QQQ", data, off + 16)
        return dict(name_off=name, type=typ, off=sh_off, size=sh_size)

    strtab = sh(e_shstrndx)
    strbase = strtab["off"]

    def secname(off):
        end = data.index(b"\0", strbase + off)
        return data[strbase + off:end].decode(errors="replace")

    dynstr = None
    for i in range(e_shnum):
        s = sh(i)
        if secname(s["name_off"]) == ".dynstr":
            dynstr = s
            break
    if dynstr is None:
        raise SystemExit(f"no .dynstr in {path}")

    base, size = dynstr["off"], dynstr["size"]
    blob = bytes(data[base:base + size])
    count = 0
    pos = 0
    replacements = []  # (abs_off, old, new)
    while pos < len(blob):
        end = blob.index(b"\0", pos)
        s = blob[pos:end].decode(errors="replace")
        if s in MAP:
            new = MAP[s]
            if len(new) > len(s):
                raise SystemExit(f"replacement longer than original: {s} -> {new}")
            replacements.append((base + pos, s, new))
        pos = end + 1
    for abs_off, old, new in replacements:
        data[abs_off:abs_off + len(old)] = new.encode() + b"\0" * (len(old) - len(new))
        count += 1
    if count:
        path.write_bytes(bytes(data))
    return count


def main():
    total = 0
    for p in sys.argv[1:]:
        n = patch(Path(p))
        print(f"  {Path(p).name}: 替换 {n} 处")
        total += n
    print(f"共 {total} 处")


if __name__ == "__main__":
    main()
