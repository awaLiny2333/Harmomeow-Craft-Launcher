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

Our overlay differs from the official file by exactly six deterministic edits:

  1. inject  RendererInit.onCreateCapabilities(provider);  as the first statement
     of the package-private capabilities constructor (hooks our renderer/GL init)
  2. keep every advertised-vs-resolvable guard, but make it RUNTIME-conditional:
         if (!ext.contains("OpenGL46")) { ... }
      -> if (RendererInit.strictCapabilities() && !ext.contains("OpenGL46")) { ... }
     (upstream gates each version group and extension on what the driver
      ADVERTISES and then requires the entry points to resolve. We used to delete
      these guards process-wide, which made a version group - and an extension -
      report "supported" merely because Mesa's dispatch table resolves the symbol:
      on this GL 4.2 device `OpenGL46` became true and Flywheel's
      `if (CAPABILITIES.OpenGL46) return true;` shortcut took the compute path
      (measured 2026-09-16). Now the guards are honoured wherever the advertised
      version can be trusted, and skipped ONLY on the gl4es compat path, whose
      context advertises a low version while the higher entry points still resolve.)
  3. force every capability probe to evaluate (no short-circuit):
         `||` -> `|`   and   `&&` -> `&`
  4. neutralise the pure-logging call `reportMissing("GL","...")` -> `false`.
     Edit 3's `|` makes it fire on EVERY version/extension (even when every
     function resolved), flooding "[LWJGL] [GL] ... an entry point is missing".
     It always returns false, so `checkFunctions(...) | false` loads the pointers
     identically, with no output.
  5. inject  ext = RendererInit.filterCapabilities(ext);  right after (1): the
     runtime capability deny-list. It REBINDS the constructor parameter (never
     mutates the caller's set, which may be immutable) so every later probe sees
     the filtered set. The policy is data (-Dmeow.maskExtensions /
     MEOW_MASK_EXTENSIONS), so capabilities can be hidden/unhidden without a
     rebuild; an absent/empty list leaves the official behaviour untouched.
  6. make EVERY capability flag maskable:
         FIELD = check_X(...);            -> FIELD = check_X(...)         && !RendererInit.isMasked("FIELD");
         FIELD = ext.contains("GL_X");    -> FIELD = ext.contains("GL_X") && !RendererInit.isMasked("FIELD");
     Same reason as edit 2's counterpart for probes: a probe such as
     `check_ARB_compute_shader` is a pure function-slot test
     (`checkFunctions(...) | false`) with NO `ext.contains(...)` term, so masking
     the extension set (edit 5) cannot reach it - nor can the Mesa layer
     (`MESA_EXTENSION_OVERRIDE`) nor a GL-layer filter over glGetStringi (all three
     measured INERT on 2026-09-16: Zink does export glDispatchCompute, so the flag
     stays true and the mod still takes the compute path). The `&&` keeps the left
     operand evaluated, so the function slots still load and the native
     address-slot contract is untouched; only the flag is forced false.

Note the division of labour: edits 2/3/4 make our LWJGL report the TRUTH about the
context; edits 5/6 are the runtime POLICY that lets us declare a capability
unusable on a specific device (and take it back without a rebuild).

Edits 1/3/4 applied to the official LWJGL 3.4.3 file reproduced the historical
shipped overlay byte-for-byte (verified 2026-09-16 against tag 3.4.3 of the LWJGL
tree); edits 5+6 are one injected line plus one wrapper per capability flag; edit
2 is 234 in-place guard rewrites.

Usage:
    gen_glcap.py <official-GLCapabilities.java> <out-GLCapabilities.java>
"""
import re
import sys


def transform(src: str) -> str:
    # (3) force-evaluate operators, and (4) neutralise the pure-logging helper
    #     `reportMissing("GL","…")` (it only logs and always returns false, so
    #     `checkFunctions(...) | false` still loads the pointers without spamming
    #     "[GL] … entry point is missing" on every probe).
    #     ⚠️ This pass MUST run BEFORE (2): its blanket `&&` -> `&` replacement would
    #     otherwise mangle the `&&` that (2) injects into the guards.
    src = src.replace('||', '|').replace('&&', '&')
    src = re.sub(r'reportMissing\("[^"]*"\s*,\s*"[^"]*"\)', 'false', src)

    # (2) keep the advertised-vs-resolvable guards, but decide at runtime. Upstream gates
    #     every version group / extension on what the driver advertises; deleting the
    #     guards process-wide made OpenGL46 (and ARB flags) true on a GL 4.2 context.
    expected = len(re.findall(r'if \(!ext\.contains\("', src))
    src, guarded = re.subn(
        r'if \(!ext\.contains\("([^"]+)"\)\) \{',
        r'if (RendererInit.strictCapabilities() && !ext.contains("\1")) {',
        src,
    )
    assert guarded == expected and guarded > 0, (
        'guard rewrite mismatch: expected %d, rewrote %d' % (expected, guarded))
    print('  edit 2: %d advertised-vs-resolvable guards made runtime-conditional'
          % guarded, file=sys.stderr)

    # (1) hook our renderer init into the capabilities constructor, and (5) filter the
    #     extension set the probes are handed. Both go in through the same anchor; (5) is
    #     an assignment to the `ext` parameter (legal, and the caller's set is untouched).
    anchor = ('GLCapabilities(FunctionProvider provider, Set<String> ext, '
              'boolean fc, IntFunction<PointerBuffer> bufferFactory) {\n')
    assert anchor in src, 'constructor anchor not found'
    src = src.replace(
        anchor,
        anchor
        + '        RendererInit.onCreateCapabilities(provider);\n'
        + '        ext = RendererInit.filterCapabilities(ext);\n',
        1,
    )

    # (6) make every capability flag maskable - the edit that reaches the function-slot
    #     probes (see the module docstring: edit 5 / Mesa / GL-layer are all inert for
    #     them). Only single-line assignments are wrapped; the assert keeps the recipe
    #     honest if a future LWJGL version changes the generated shape.
    probe = re.compile(
        r'^(        )([A-Za-z0-9_]+) = '
        r'(check_[A-Za-z0-9_]+\([^\n]*\)|ext\.contains\("[^"]+"\));$',
        re.M,
    )

    def _maskable(match) -> str:
        indent, field, expr = match.group(1), match.group(2), match.group(3)
        return '%s%s = %s && !RendererInit.isMasked("%s");' % (indent, field, expr, field)

    src, wrapped = probe.subn(_maskable, src)
    assert wrapped > 0, 'no capability flags found - did the generated shape change?'
    print('  edit 6: %d capability flags made maskable' % wrapped, file=sys.stderr)
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
