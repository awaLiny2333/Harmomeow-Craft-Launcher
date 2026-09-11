#!/usr/bin/env python3
"""Apply the Meowcraft OHOS adaptation to oshi's LinuxCentralProcessor.java.

Usage:  patch_oshi.py <path/to/LinuxCentralProcessor.java>

Two structure-aware edits (tolerant of oshi version differences 5.x..6.9+):

  1. queryProcessorId(): prefer -Dmeow.cpu.chip (the app passes ArkTS
     deviceInfo.chipType) for the CPU name, because the HarmonyOS sandbox
     blocks /proc/cpuinfo.

  2. initProcessorCounts(): replace the body with a synthesized topology whose
     logical-processor count is Runtime.availableProcessors() (so MC's F3 line
     and -XX:ActiveProcessorCount stay in sync). On OHOS the real sources
     (/proc/cpuinfo, /sys/.../cpu, udev) are all blocked, so this is unconditional;
     it also makes the result independent of JNA/libudev being present.

Anchor 1 is the ProcessorIdentifier construction (stable across versions).
Anchor 2 is the initProcessorCounts signature; the synthesized value is chosen
from its declared return type (List / Pair / Triplet / Quartet).
"""
import re
import sys


def find_method_body(src, name):
    """Return (open_brace_idx, close_brace_idx) for the first method `name`."""
    m = re.search(r'\b' + re.escape(name) + r'\(\)\s*\{', src)
    if not m:
        raise SystemExit('ERROR: method %s() not found' % name)
    open_idx = m.end() - 1
    depth = 0
    i = open_idx
    n = len(src)
    state = None  # None | 'str' | 'char' | 'line' | 'block'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '"':
                state = 'str'
            elif c == "'":
                state = 'char'
            elif c == '/' and nxt == '/':
                state = 'line'
                i += 1
            elif c == '/' and nxt == '*':
                state = 'block'
                i += 1
            elif c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return open_idx, i
        elif state == 'str':
            if c == '\\':
                i += 1
            elif c == '"':
                state = None
        elif state == 'char':
            if c == '\\':
                i += 1
            elif c == "'":
                state = None
        elif state == 'line':
            if c == '\n':
                state = None
        elif state == 'block':
            if c == '*' and nxt == '/':
                state = None
                i += 1
        i += 1
    raise SystemExit('ERROR: unbalanced braces for %s()' % name)


def indent_of(src, idx):
    start = src.rfind('\n', 0, idx) + 1
    j = start
    while j < len(src) and src[j] in ' \t':
        j += 1
    return src[start:j]


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_oshi.py <LinuxCentralProcessor.java>')
    path = sys.argv[1]
    with open(path, encoding='utf-8') as f:
        src = f.read()

    if 'meow.cpu.chip' in src:
        print('already patched, skipping: %s' % path)
        return

    # ---- Edit 1: CPU name from -Dmeow.cpu.chip ----
    anchor1 = 'return new ProcessorIdentifier(cpuVendor, cpuName,'
    if src.count(anchor1) != 1:
        raise SystemExit('ERROR: ProcessorIdentifier anchor not unique (%d)'
                         % src.count(anchor1))
    idx1 = src.index(anchor1)
    ind1 = indent_of(src, idx1)
    line_start = src.rfind('\n', 0, idx1) + 1
    inject1 = (
        ind1 + '// Meowcraft (OHOS): the sandbox blocks /proc/cpuinfo; prefer the SoC name\n' +
        ind1 + '// the app passes via -Dmeow.cpu.chip (ArkTS deviceInfo.chipType).\n' +
        ind1 + 'String meowChip = System.getProperty("meow.cpu.chip", "");\n' +
        ind1 + 'if (!meowChip.isEmpty()) {\n' +
        ind1 + '    cpuName = meowChip;\n' +
        ind1 + '}\n'
    )
    src = src[:line_start] + inject1 + src[line_start:]

    # ---- Edit 2: initProcessorCounts() -> synthesize from availableProcessors() ----
    sig = re.search(r'protected\s+([^\n{]+?)\s+initProcessorCounts\(\)\s*\{', src)
    if not sig:
        raise SystemExit('ERROR: initProcessorCounts signature not found')
    ret_type = ' '.join(sig.group(1).split())
    open_idx, close_idx = find_method_body(src, 'initProcessorCounts')
    ind = indent_of(src, open_idx)

    fallback = {
        'List<LogicalProcessor>': 'fallback',
        'Pair<List<LogicalProcessor>, List<PhysicalProcessor>>':
            'new Pair<>(fallback, null)',
        'Triplet<List<LogicalProcessor>, List<PhysicalProcessor>, List<ProcessorCache>>':
            'new Triplet<>(fallback, null, java.util.Collections.emptyList())',
        'Quartet<List<LogicalProcessor>, List<PhysicalProcessor>, List<ProcessorCache>, List<String>>':
            'new Quartet<>(fallback, null, java.util.Collections.emptyList(),'
            ' java.util.Collections.emptyList())',
    }.get(ret_type)
    if fallback is None:
        raise SystemExit('ERROR: unsupported initProcessorCounts return type: %r'
                         % ret_type)

    b = ind + '    '  # method body indent
    body = (
        '\n' +
        b + '// Meowcraft (OHOS): /proc/cpuinfo, /sys/.../cpu and udev are all blocked in\n' +
        b + '// the sandbox (and JNA/libudev may be absent), so synthesize the topology\n' +
        b + '// from Runtime.availableProcessors() (respects -XX:ActiveProcessorCount).\n' +
        b + 'int meowCores = Runtime.getRuntime().availableProcessors();\n' +
        b + 'if (meowCores < 1) {\n' +
        b + '    meowCores = 1;\n' +
        b + '}\n' +
        b + 'java.util.List<LogicalProcessor> fallback = new java.util.ArrayList<>();\n' +
        b + 'for (int i = 0; i < meowCores; i++) {\n' +
        b + '    fallback.add(new LogicalProcessor(i, i, 0));\n' +
        b + '}\n' +
        b + 'return ' + fallback + ';\n' +
        ind
    )
    src = src[:open_idx + 1] + body + src[close_idx:]

    with open(path, 'w', encoding='utf-8') as f:
        f.write(src)
    print('patched %s (initProcessorCounts return=%s)' % (path, ret_type))


if __name__ == '__main__':
    main()
