#!/usr/bin/env python3
"""Structure-aware patcher for LEGACY oshi (pre-3.0 single-module tree).

Legacy oshi (e.g. oshi-core 1.1, used by MC 1.16.x) has a different layout and
API than modern oshi:
  oshi/software/os/linux/proc/CentralProcessor.java           (concrete Linux CPU)
  oshi/software/os/linux/LinuxHardwareAbstractionLayer.java   (getProcessors())

On aarch64 HarmonyOS, /proc/cpuinfo has no `model name` line, so the CPU name
stays null (F3 shows "<n>x null") and the block count is off. This patch injects
the app-provided chip name (`-Dmeow.cpu.chip`, from ArkTS deviceInfo.chipType)
and normalises the processor count to Runtime.availableProcessors().

Two edits:
  1. CentralProcessor.getName(): return -Dmeow.cpu.chip when set.
  2. LinuxHardwareAbstractionLayer.getProcessors(): when the chip is set, build
     `availableProcessors()` processors all named with the chip.

Idempotent (skips if `meow.cpu.chip` already present). Fails loudly if an anchor
is missing so a silent mismatch can never ship.

Usage:
  python3 patch_oshi_legacy.py <CentralProcessor.java> [<LinuxHardwareAbstractionLayer.java>]
"""
import re
import sys

MARKER = "meow.cpu.chip"


def patch_cpu(path: str) -> bool:
    src = open(path, encoding="utf-8").read()
    if MARKER in src:
        print("already patched:", path)
        return False
    anchor = re.compile(r"(public String getName\(\) \{\n)(\s*)(return _name;)", re.M)
    m = anchor.search(src)
    if m is None:
        sys.exit("anchor not found in %s: getName()/_name" % path)
    indent = m.group(2)
    inject = (m.group(1)
              + indent + 'String meowChip = System.getProperty("meow.cpu.chip");\n'
              + indent + "if (meowChip != null && !meowChip.isEmpty()) {\n"
              + indent + "\treturn meowChip;\n"
              + indent + "}\n"
              + m.group(2) + m.group(3))
    src = src[:m.start()] + inject + src[m.end():]
    open(path, "w", encoding="utf-8").write(src)
    print("patched:", path)
    return True


def patch_hal(path: str) -> bool:
    src = open(path, encoding="utf-8").read()
    if MARKER in src:
        print("already patched:", path)
        return False
    anchor = re.compile(r"^(\s*)(_processors = processors\.toArray\(new Processor\[0\]\);)$",
                        re.M)
    m = anchor.search(src)
    if m is None:
        sys.exit("anchor not found in %s: _processors = processors.toArray(...)" % path)
    ind = m.group(1)
    inject = (
        ind + 'String meowChip = System.getProperty("meow.cpu.chip");\n'
        + ind + "if (meowChip != null && !meowChip.isEmpty()) {\n"
        + ind + "\tint meowN = Runtime.getRuntime().availableProcessors();\n"
        + ind + "\tif (meowN < 1) {\n"
        + ind + "\t\tmeowN = 1;\n"
        + ind + "\t}\n"
        + ind + "\tprocessors.clear();\n"
        + ind + "\tfor (int meowI = 0; meowI < meowN; meowI++) {\n"
        + ind + "\t\tCentralProcessor meowCpu = new CentralProcessor();\n"
        + ind + "\t\tmeowCpu.setName(meowChip);\n"
        + ind + "\t\tmeowCpu.setVendor(meowChip);\n"
        + ind + "\t\tprocessors.add(meowCpu);\n"
        + ind + "\t}\n"
        + ind + "}\n"
        + m.group(1) + m.group(2))
    src = src[:m.start()] + inject + src[m.end():]
    open(path, "w", encoding="utf-8").write(src)
    print("patched:", path)
    return True


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    for path in argv[1:]:
        name = path.rsplit("/", 1)[-1]
        if name == "CentralProcessor.java":
            patch_cpu(path)
        elif name == "LinuxHardwareAbstractionLayer.java":
            patch_hal(path)
        else:
            sys.exit("unexpected file (legacy patcher): %s" % path)


if __name__ == "__main__":
    main(sys.argv)
