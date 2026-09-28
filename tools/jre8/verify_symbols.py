#!/usr/bin/env python3
"""校验一套 JRE .so 的**动态重定位**所需符号是否被满足（纯 Python；宿主无 readelf 也能跑）。

为什么另写一份（**有意的口径修正**）：
  `tools/jre26/verify_symbols.py` 基于 `readelf --dyn-syms` 的"GLOBAL 未定义符号"，
  但这会把**只有 .dynsym 条目、没有任何重定位**的幽灵符号也算成"缺"。
  JDK 8 就撞上了这类误报：`libjava.so` 的 .dynsym 里有未定义的 `__timezone`，而其
  **真重定位**（`llvm-objdump -R` 实测）指向的是 `timezone` —— musl 本来就导出 `timezone`。
  按 dynsym 口径会得出"必须往 shim 加 `__timezone`"的错误结论。
  本文件只认 `.rela.dyn` / `.rela.plt` 里**被重定位引用**的未定义符号，与加载器的实际要求一致。

口径：
  * 需求 = 每个待查件里，被 R_AARCH64_* 重定位引用、且 `st_shndx == SHN_UNDEF` 的符号；
  * 提供 = OHOS libc ∪ 本集合自身导出 ∪ `--extra` 指定的外部件导出（只取 GLOBAL，忽略 WEAK）。

用法:
  verify_symbols.py <libdir> [--libc <libc.so>] [--extra <a.so> [...]]
"""
import argparse
import struct
import sys
from pathlib import Path

SHT_RELA = 4
SHT_DYNSYM = 11
SHN_UNDEF = 0
STB_LOCAL, STB_GLOBAL, STB_WEAK = 0, 1, 2


def _sections(data):
    e_shoff = struct.unpack_from('<Q', data, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', data, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', data, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', data, 0x3E)[0]
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ = struct.unpack_from('<II', data, off)
        sh_off, sh_size = struct.unpack_from('<QQ', data, off + 24)
        link = struct.unpack_from('<I', data, off + 40)[0]
        entsize = struct.unpack_from('<Q', data, off + 56)[0]
        secs.append(dict(type=typ, off=sh_off, size=sh_size, link=link, entsize=entsize))
    if e_shstrndx >= len(secs):
        return secs
    strbase = secs[e_shstrndx]['off']
    for s in secs:
        end = data.index(b'\0', strbase + s.get('name_off', 0))
        s['name'] = data[strbase + s.get('name_off', 0):end].decode(errors='replace')
    return secs


def _dynsym(data, secs):
    """→ (names, shndx, bind, defined_set, undef_set)。names 按 dynsym 下标索引。"""
    sym = next((s for s in secs if s['type'] == SHT_DYNSYM), None)
    if sym is None or sym['entsize'] == 0:
        return [], None, None, set(), set()
    strtab = secs[sym['link']]
    strblob = data[strtab['off']:strtab['off'] + strtab['size']]

    def name_at(off):
        end = strblob.index(b'\0', off)
        return strblob[off:end].decode(errors='replace')

    names, shndx, bind, defined, undef = [], [], [], set(), set()
    n = sym['size'] // sym['entsize']
    for i in range(n):
        off = sym['off'] + i * sym['entsize']
        st_name = struct.unpack_from('<I', data, off)[0]
        st_info = data[off + 4]
        st_shndx = struct.unpack_from('<H', data, off + 6)[0]
        nm = name_at(st_name) if st_name else ''
        b = st_info >> 4
        names.append(nm)
        shndx.append(st_shndx)
        bind.append(b)
        if nm and b != STB_LOCAL:
            if st_shndx == SHN_UNDEF:
                if b != STB_WEAK:
                    undef.add(nm)
            elif b == STB_GLOBAL:
                defined.add(nm)
    return names, shndx, bind, defined, undef


def analyze(path):
    """→ (exported:set, needed:set)。needed 只含**被重定位引用**的未定义符号。"""
    data = Path(path).read_bytes()
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        return set(), set()
    secs = _sections(data)
    names, shndx, bind, defined, _ = _dynsym(data, secs)
    needed = set()
    for s in secs:
        if s['type'] != SHT_RELA or s['size'] == 0:
            continue
        for k in range(s['size'] // 24):
            off = s['off'] + k * 24
            r_info = struct.unpack_from('<Q', data, off + 8)[0]
            sym_idx = r_info >> 32
            if sym_idx == 0 or sym_idx >= len(names):
                continue
            if shndx[sym_idx] == SHN_UNDEF and bind[sym_idx] != STB_WEAK and names[sym_idx]:
                needed.add(names[sym_idx])
    return defined, needed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('libdir')
    ap.add_argument('--libc', default=None, help='OHOS libc.so（默认从 SDK 推断）')
    ap.add_argument('--extra', action='append', default=[], help='额外提供者 .so（可多次）')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    libc = args.libc
    if libc is None:
        import os
        sdk = os.environ.get('OHOS_SDK_NATIVE',
                             str(Path.home() / 'devecow/deveco_tools/sdk/default/openharmony/native'))
        libc = str(Path(sdk) / 'sysroot/usr/lib/aarch64-linux-ohos/libc.so')

    libdir = Path(args.libdir)
    libs = sorted(libdir.glob('*.so'))
    provide = analyze(libc)[0]
    for f in libs:
        provide |= analyze(f)[0]
    for e in args.extra:
        if Path(e).exists():
            provide |= analyze(e)[0]
        else:
            print('  ⚠️  --extra 不存在，已忽略: %s' % e)

    bad = 0
    for f in libs:
        miss = analyze(f)[1] - provide
        if miss:
            bad += 1
            print('  ✗ %-24s 缺 %2d -> %s' % (f.name, len(miss), ' '.join(sorted(miss))))
        elif not args.quiet:
            print('  ✓ %s' % f.name)
    print('结果:', 'PASS' if bad == 0 else 'FAIL %d' % bad)
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
