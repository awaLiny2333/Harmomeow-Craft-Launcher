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
  2. keep every advertised-vs-resolvable guard, but make it RUNTIME-conditional, and
     split the two kinds (their sources of truth differ):
         version group:  if (!ext.contains("OpenGL42")) { ... }
           -> if (RendererInit.strictCapabilities() && !RendererInit.allowsVersionGroup(ext, 4, 2)) { ... }
         extension:      if (!ext.contains("GL_ARB_x")) { ... }
           -> if (RendererInit.strictCapabilities() && !ext.contains("GL_ARB_x")) { ... }
     Why the split: LWJGL itself synthesises the ext set - GL.createCapabilities adds exactly
     ONE version name, "OpenGL" + major + minor, from GL_MAJOR_VERSION/GL_MINOR_VERSION
     (ref/lwjgl3: org/lwjgl/opengl/GL.java). So on a GL 4.2 context that family contains only
     "OpenGL42": the guard made OpenGL43..46 false (correct - this is what kills Flywheel's
     `if (CAPABILITIES.OpenGL46) return true;` shortcut) but ALSO made OpenGL11..41 false
     (wrong: the context supports them). Deleting the guards had the opposite error (4.2
     claimed as 4.6). allowsVersionGroup() therefore accepts the advertised name OR the parsed
     GL_VERSION. Extensions keep the upstream contract (advertised name + resolvable entry
     points), which holds because Mesa does advertise them. Both are skipped on the gl4es
     compat path (strict = OFF), whose context advertises a low version while the higher entry
     points still resolve.
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
     What this level buys (note it is NOT the "only" working level - edits 2/5 also reach the
     extension probes when strict is ON): edit 6 is what makes the VERSION GROUPS maskable
     (allowsVersionGroup consults the parsed GL_VERSION, which knows nothing about the deny
     list) and what keeps masking effective when strict is OFF (gl4es). For the record, the
     three things that were measured INERT on 2026-09-16 were measured against the *old*
     guard-deleted overlay: filtering `ext` (edit 5), `MESA_EXTENSION_OVERRIDE`, and a
     GL-layer filter over glGetStringi - none of them can reach a pure
     `checkFunctions(...) | false` probe. The `&&` keeps the left operand evaluated, so the
     function slots still load and the native address-slot contract is untouched; only the
     flag is forced false.

Note the division of labour: edits 2/3/4 make our LWJGL report the TRUTH about the
context; edits 5/6 are the runtime POLICY that lets us declare a capability
unusable on a specific device (and take it back without a rebuild).

The historical (pre-campaign) shipped overlay is reproduced byte-for-byte by the OLD
four-edit recipe (hook, DROP the guards, de-short-circuit, reportMissing->false),
re-verified 2026-09-16 against tag 3.4.3 of the LWJGL tree. The current recipe is that
plus: edit 2 keeps the 234 guards runtime-conditional (18 of them via GL_VERSION),
edits 5/6 add the mask interface.

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

    # (2) keep the advertised-vs-resolvable guards, but decide at runtime - and SPLIT them,
    #     because the two kinds have different sources of truth:
    #       * version groups (`OpenGL42`): LWJGL's own GL.createCapabilities adds exactly ONE
    #         version name ("OpenGL" + major + minor) taken from GL_MAJOR_VERSION/MINOR_VERSION,
    #         so on a 4.2 context the guard made 43..46 false (correct) but also 11..41 false
    #         (wrong - the context supports them). RendererInit.allowsVersionGroup() therefore
    #         accepts the advertised name OR the parsed GL_VERSION.
    #       * extensions (`GL_ARB_*`): "advertised name + resolvable entry points" is the
    #         upstream contract and it holds here, because Mesa does advertise them.
    expected = len(re.findall(r'if \(!ext\.contains\("', src))
    version_guards = len(re.findall(r'if \(!ext\.contains\("OpenGL\d\d"\)\) \{', src))

    def _conditional(match) -> str:
        name = match.group(1)
        groups = re.fullmatch(r'OpenGL(\d)(\d)', name)
        if groups:
            return ('if (RendererInit.strictCapabilities() && '
                    '!RendererInit.allowsVersionGroup(ext, %s, %s)) {'
                    % (groups.group(1), groups.group(2)))
        return 'if (RendererInit.strictCapabilities() && !ext.contains("%s")) {' % name

    src, guarded = re.subn(r'if \(!ext\.contains\("([^"]+)"\)\) \{', _conditional, src)
    # Hard failures (not `assert`, which `python3 -O` strips): a shape change must not silently
    # produce an unverified file whose slot indices could be wrong.
    if guarded != expected or guarded == 0:
        raise SystemExit('guard rewrite mismatch: expected %d, rewrote %d' % (expected, guarded))
    print('  edit 2: %d guards made runtime-conditional (%d version groups take GL_VERSION)'
          % (guarded, version_guards), file=sys.stderr)

    # (1) hook our renderer init into the capabilities constructor, and (5) filter the
    #     extension set the probes are handed. Both go in through the same anchor; (5) is
    #     an assignment to the `ext` parameter (legal, and the caller's set is untouched).
    anchor = ('GLCapabilities(FunctionProvider provider, Set<String> ext, '
              'boolean fc, IntFunction<PointerBuffer> bufferFactory) {\n')
    if anchor not in src:
        raise SystemExit('constructor anchor not found: did the generated shape change?')
    src = src.replace(
        anchor,
        anchor
        + '        RendererInit.onCreateCapabilities(provider);\n'
        + '        ext = RendererInit.filterCapabilities(ext);\n',
        1,
    )

    # (6) make every capability flag maskable. What this level buys: the VERSION GROUPS
    #     (allowsVersionGroup consults the parsed GL_VERSION, which knows nothing about the
    #     deny-list) and masking on the strict-OFF gl4es path. For the record, the three
    #     approaches measured INERT on 2026-09-16 - filtering `ext` (edit 5),
    #     MESA_EXTENSION_OVERRIDE, and a GL-layer filter over glGetStringi - were measured
    #     against the *old* guard-deleted overlay, where a pure `checkFunctions(...) | false`
    #     probe could not be reached by any of them. Only single-line assignments are wrapped.
    probe = re.compile(
        r'^(        )([A-Za-z0-9_]+) = '
        r'(check_[A-Za-z0-9_]+\([^\n]*\)|ext\.contains\("[^"]+"\));$',
        re.M,
    )

    def _maskable(match) -> str:
        indent, field, expr = match.group(1), match.group(2), match.group(3)
        return '%s%s = %s && !RendererInit.isMasked("%s");' % (indent, field, expr, field)

    src, wrapped = probe.subn(_maskable, src)
    if wrapped == 0:
        raise SystemExit('no capability flags found: did the generated shape change?')
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
