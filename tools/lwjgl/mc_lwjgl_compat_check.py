#!/usr/bin/env python3
"""Full member-level LWJGL compatibility check (inheritance-aware).

Collects every org/lwjgl reference made by the given Minecraft client jars and resolves it
against the given LWJGL jar:

  * member refs (Field/Method/InterfaceMethodref) -- resolved through the
    superclass/interface chain;
  * class refs (CP `Class` constants: `ldc X.class`, `checkcast`, `instanceof`, ...).

Prints the truly-missing classes/members -> the exact shim surface needed to run those MC
versions on that single LWJGL generation.

COVERAGE / LIMITS: only *direct* constant-pool references are seen. Reflection
(`Class.forName`, `MethodHandles`, `ServiceLoader`) and members inherited from JDK types
(apart from the well-known java.lang.Object ones, which are filtered out) are NOT covered
-- treat the output as "the directly-linked surface".

Validation: run against the generation an MC version declares -> must report ~0 missing.

Usage: mc_lwjgl_compat_check.py --jar <lwjgl.jar> <mcjar> [<mcjar> ...]
"""
import struct
import sys
import zipfile


def parse_cp(data):
    if data[:4] != b"\xca\xfe\xba\xbe":
        return None, 8
    off = 8
    count = struct.unpack_from(">H", data, off)[0]
    off += 2
    cp = {}
    i = 1
    while i < count:
        tag = data[off]
        off += 1
        if tag == 1:
            ln = struct.unpack_from(">H", data, off)[0]
            off += 2
            cp[i] = (1, data[off:off + ln].decode("utf-8", "replace"))
            off += ln
        elif tag in (3, 4):
            off += 4
        elif tag in (5, 6):
            off += 8
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            a = struct.unpack_from(">H", data, off)[0]
            off += 2
            cp[i] = (tag, a)
        elif tag in (9, 10, 11, 12):
            a, b = struct.unpack_from(">HH", data, off)
            off += 4
            cp[i] = (tag, a, b)
        elif tag == 15:
            off += 3
        elif tag in (17, 18):
            off += 4
        else:
            return None, 8
        i += 1
    return cp, off


def utf8(cp, idx):
    e = cp.get(idx)
    return e[1] if e and e[0] == 1 else None


def skip_attrs(data, off):
    n = struct.unpack_from(">H", data, off)[0]
    off += 2
    for _ in range(n):
        length = struct.unpack_from(">I", data, off + 2)[0]
        off += 6 + length
    return off


def class_info(data):
    """-> (this, super, [ifaces], {(name,desc)} declared, {(owner,name,desc)} refs)"""
    cp, off = parse_cp(data)
    if cp is None:
        return None
    this_idx = struct.unpack_from(">H", data, off + 2)[0]
    super_idx = struct.unpack_from(">H", data, off + 4)[0]
    this_name = utf8(cp, cp[this_idx][1])
    super_name = utf8(cp, cp[super_idx][1]) if super_idx else None
    off2 = off + 6
    icount = struct.unpack_from(">H", data, off2)[0]
    off2 += 2
    ifaces = []
    for _ in range(icount):
        ii = struct.unpack_from(">H", data, off2)[0]
        off2 += 2
        ifaces.append(utf8(cp, cp[ii][1]))
    declared = set()
    for _section in range(2):
        n = struct.unpack_from(">H", data, off2)[0]
        off2 += 2
        for _ in range(n):
            _acc, ni, di = struct.unpack_from(">HHH", data, off2)
            off2 += 6
            off2 = skip_attrs(data, off2)
            nm, ds = utf8(cp, ni), utf8(cp, di)
            if nm is not None:
                declared.add((nm, ds))
    refs = set()
    class_refs = set()
    for e in cp.values():
        if e[0] == 7:                       # CP Class constant (ldc X.class / checkcast / ...)
            nm = utf8(cp, e[1])
            if nm:
                class_refs.add(nm)
        elif e[0] in (9, 10, 11):
            cls = cp.get(e[1]); nat = cp.get(e[2])
            if not cls or not nat or cls[0] != 7 or nat[0] != 12:
                continue
            owner, nm, ds = utf8(cp, cls[1]), utf8(cp, nat[1]), utf8(cp, nat[2])
            if owner and nm:
                refs.add((owner, nm, ds))
    return this_name, super_name, ifaces, declared, refs, class_refs


def index_jar(path):
    classes = set()
    info = {}
    with zipfile.ZipFile(path) as z:
        for entry in z.namelist():
            if not entry.endswith(".class"):
                continue
            ci = class_info(z.read(entry))
            if ci is None or ci[0] is None:
                continue
            name, sup, ifs, declared, _refs, _crefs = ci
            classes.add(name)
            info[name] = (sup, [i for i in ifs if i], declared)
    return classes, info


def has_member(info, cls, name, desc):
    seen = set()
    stack = [cls]
    while stack:
        c = stack.pop()
        if c in seen or c not in info:
            continue
        seen.add(c)
        sup, ifs, declared = info[c]
        if (name, desc) in declared:
            return True
        if sup:
            stack.append(sup)
        stack.extend(ifs)
    return False


def collect_refs(mc):
    """-> (member refs, class refs), both restricted to org/lwjgl."""
    refs = set()
    class_refs = set()
    with zipfile.ZipFile(mc) as z:
        for entry in z.namelist():
            if not entry.endswith(".class"):
                continue
            ci = class_info(z.read(entry))
            if ci is None:
                continue
            refs |= {x for x in ci[4] if x[0].startswith("org/lwjgl")}
            class_refs |= {c for c in ci[5] if c.startswith("org/lwjgl")}
    return refs, class_refs


# Members every class inherits from java/lang/Object: those live in the JDK, not in the
# LWJGL jar, so "declared nowhere in the jar" is expected and is NOT a compat gap.
JDK_OBJECT_MEMBERS = {
    ("equals", "(Ljava/lang/Object;)Z"), ("hashCode", "()I"),
    ("toString", "()Ljava/lang/String;"), ("getClass", "()Ljava/lang/Class;"),
    ("clone", "()Ljava/lang/Object;"), ("notify", "()V"), ("notifyAll", "()V"),
    ("wait", "()V"), ("wait", "(J)V"), ("finalize", "()V"),
}


def main():
    args = sys.argv[1:]
    lwjgl = None
    mcs = []
    i = 0
    while i < len(args):
        if args[i] == "--jar":
            lwjgl = args[i + 1]; i += 2
        else:
            mcs.append(args[i]); i += 1
    classes, info = index_jar(lwjgl)
    print("LWJGL jar: %s  (%d classes)" % (lwjgl, len(classes)))
    for mc in mcs:
        refs, class_refs = collect_refs(mc)
        missing_class = sorted(({o for (o, _n, _d) in refs if o not in classes})
                               | {c for c in class_refs if c not in classes})
        missing_member = sorted({(o, n, d) for (o, n, d) in refs
                                 if o in classes and not has_member(info, o, n, d)
                                 and (n, d) not in JDK_OBJECT_MEMBERS})
        print("\n== %s  (%d org/lwjgl refs)" % (mc, len(refs)))
        print("   missing classes (%d): %s" % (len(missing_class), ", ".join(missing_class)))
        print("   missing members (%d):" % len(missing_member))
        for o, n, d in missing_member:
            print("      %-46s %-26s %s" % (o, n, d))


if __name__ == "__main__":
    main()
