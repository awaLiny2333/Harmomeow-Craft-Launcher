#!/usr/bin/env python3
"""Generate the clean-room `org/lwjgl/opengl/GLCapabilities.java` overlay variant
from an official LWJGL generated `GLCapabilities.java`.

Why this exists
---------------
`GLCapabilities` is a MACHINE-GENERATED, version-pinned file: its field order
defines the slot index that every `Java_org_lwjgl_opengl_*` native reads via

    #define tlsGetFunction(index) (uintptr_t)((void **)(*__env)->reserved3)[index]

so the Java caps and the C natives MUST come from the same LWJGL version, and the
overlay must stay in lock-step with the source tree the natives are built from.
Hand-editing the 10k-line file is not reproducible, so we derive it.

Our overlay differs from the official file by exactly four deterministic edits:

  1. inject  RendererInit.onCreateCapabilities(provider);  as the first statement
     of the package-private capabilities constructor (hooks our renderer/GL init)
  2. drop the early-return guards
         if (!ext.contains("OpenGLxx")) { return false; }
         if (!ext.contains("GL_ARB_...")) { return false; }
     (the compat/Zink context reports a version we still must probe capabilities
      against, so we cannot bail out on the advertised version string)
  3. force every capability probe to evaluate (no short-circuit):
         `||` -> `|`   and   `&&` -> `&`
  4. neutralise the pure-logging call `reportMissing("GL","...")` -> `false`.
     Edit 3's `|` makes it fire on EVERY version/extension (even when every
     function resolved), flooding "[LWJGL] [GL] ... an entry point is missing".
     It always returns false, so `checkFunctions(...) | false` loads the pointers
     identically, with no output.

Edit 1+2+3+4 applied to the official LWJGL 3.3.3 / 3.4.3 file reproduce our
shipped `deltas/overlay-<gen>/org/lwjgl/opengl/GLCapabilities.java` byte-for-byte
(verified).

Usage:
    gen_glcap.py <official-GLCapabilities.java> <out-GLCapabilities.java>
"""
import re
import sys


def transform(src: str) -> str:
    # (2) remove the version guards, then (3) force-evaluate operators.
    guard = re.compile(
        r'[ \t]*if \(!ext\.contains\("[^"]+"\)\) \{\n'
        r'[ \t]*return false;\n'
        r'[ \t]*\}\n'
    )
    src = guard.sub('', src)
    src = src.replace('||', '|').replace('&&', '&')
    # (4) the de-short-circuit above also makes the *logging* helper
    #     `reportMissing("GL","…")` run unconditionally; neutralise it (it only
    #     logs and always returns false) so `checkFunctions(...) | false` still
    #     loads the pointers without spamming "[GL] … entry point is missing".
    src = re.sub(r'reportMissing\("[^"]*"\s*,\s*"[^"]*"\)', 'false', src)

    # (1) hook our renderer init into the capabilities constructor
    anchor = ('GLCapabilities(FunctionProvider provider, Set<String> ext, '
              'boolean fc, IntFunction<PointerBuffer> bufferFactory) {\n')
    assert anchor in src, 'constructor anchor not found'
    src = src.replace(
        anchor,
        anchor + '        RendererInit.onCreateCapabilities(provider);\n',
        1,
    )
    return src


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    with open(sys.argv[1], 'r', encoding='utf-8') as fh:
        src = fh.read()
    with open(sys.argv[2], 'w', encoding='utf-8') as fh:
        fh.write(transform(src))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
