#!/usr/bin/env python3
"""Export the ALC_SOFT_system_events entry points (OpenAL Soft 1.24.x).

The 1.24.x sources define `alcEventIsSupportedSOFT` (alc/alc.cpp) and
`alcEventControlSOFT` / `alcEventCallbackSOFT` (alc/events.cpp) **without** the
`ALC_API` visibility annotation. OpenAL's own build compiles with
`-fvisibility=hidden` and relies on `ALC_API` to mark exports, so these three
symbols end up hidden in the ELF. Minecraft >= 1.22 (`CallbackDeviceTracker`
via LWJGL) resolves `alcEventIsSupportedSOFT` with dlsym and NPEs when it is
missing, even though the extension string is advertised.

This patcher adds `ALC_API` to the three definitions so they are exported.

Usage:
    python3 patch_openal_events_export.py <openal-soft-src-root>
"""
import os
import sys


def patch_file(path, replacements):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    for old, new, count in replacements:
        pairs = list(zip(old, new)) if isinstance(old, (list, tuple)) else [(old, new)]
        counts = count if isinstance(count, (set, frozenset, list, tuple)) else [count]
        hit = None
        for cand, repl in pairs:
            if text.count(cand) in counts:
                hit = (cand, repl)
                break
        if hit is None:
            raise SystemExit("anchor mismatch in %s: no variant matched %s" % (path, counts))
        text = text.replace(hit[0], hit[1])
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("patched %s" % path)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_openal_events_export.py <openal-soft-src-root>")
    root = sys.argv[1]

    patch_file(os.path.join(root, "alc", "alc.cpp"), [
        (
            "FORCE_ALIGN ALCenum ALC_APIENTRY alcEventIsSupportedSOFT(",
            "FORCE_ALIGN ALC_API ALCenum ALC_APIENTRY alcEventIsSupportedSOFT(",
            1,
        ),
    ])

    patch_file(os.path.join(root, "alc", "events.cpp"), [
        (
            "FORCE_ALIGN ALCboolean ALC_APIENTRY alcEventControlSOFT(",
            "FORCE_ALIGN ALC_API ALCboolean ALC_APIENTRY alcEventControlSOFT(",
            1,
        ),
        (
            "FORCE_ALIGN void ALC_APIENTRY alcEventCallbackSOFT(",
            "FORCE_ALIGN ALC_API void ALC_APIENTRY alcEventCallbackSOFT(",
            1,
        ),
    ])

    # The build links with `-Wl,--version-script=libopenal.version`, whose
    # `local: *;` hides every symbol not listed in `global:`. These three ALC
    # entry points are missing from that list, so add them next to the other
    # ALC SOFT exports.
    patch_file(os.path.join(root, "libopenal.version"), [
        (
            "alcGetStringiSOFT;\n",
            "alcGetStringiSOFT;\n"
            "alcEventIsSupportedSOFT;\n"
            "alcEventControlSOFT;\n"
            "alcEventCallbackSOFT;\n",
            1,
        ),
    ])


if __name__ == "__main__":
    main()
