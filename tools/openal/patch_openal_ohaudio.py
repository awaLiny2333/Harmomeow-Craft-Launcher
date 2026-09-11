#!/usr/bin/env python3
"""Install the Meowcraft OHAudio backend into an OpenAL Soft source tree.

Adds `alc/backends/ohaudio.{cpp,h}` (kept next to this script under `ohaudio/`)
and wires it into the build so it is selectable as an OpenAL backend:

  - alc/backends/ohaudio.cpp / .h   (copied in)
  - CMakeLists.txt                  (HAVE_OHAUDIO + backend detection block)
  - config_backends.h.in (1.24+)    (#cmakedefine01 HAVE_OHAUDIO)
    config.h.in         (1.23.x)    (#cmakedefine HAVE_OHAUDIO)
  - alc/alc.cpp                     (guarded include + BackendList entry, before opensl)

The backend source targets OpenAL Soft **1.24.x** (fmt-formatted diagnostics,
`BackendFactory::enumerate`, `BackendBase::open(std::string_view)`, the
`BackendBase::mDeviceName` member). The earlier 1.23.x OHAudio build is retired;
its artifact remains in git history.

Anchored, exact-match edits: if the tree matches neither a known 1.23.x nor
1.24.x text, the script fails loudly.

Usage:
    python3 patch_openal_ohaudio.py <openal-soft-src-root>
"""
import os
import shutil
import sys


def patch_file(path, replacements):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    for old, new, count in replacements:
        # `old`/`new` may be version variants (parallel lists) or a single `new`
        # broadcast across several `old` candidates; `count` is an accepted
        # occurrence count or set of counts.
        if isinstance(old, (list, tuple)):
            pairs = list(zip(old, new)) if isinstance(new, (list, tuple)) \
                else [(cand, new) for cand in old]
        else:
            pairs = [(old, new)]
        counts = count if isinstance(count, (set, frozenset, list, tuple)) else [count]
        hit = None
        for cand, repl in pairs:
            if text.count(cand) in counts:
                hit = (cand, repl)
                break
        if hit is None:
            raise SystemExit(
                "anchor mismatch in %s: no variant matched counts %s\n%s"
                % (path, counts, "\n".join("  %r" % c[:160] for c, _ in pairs)))
        text = text.replace(hit[0], hit[1])
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("patched %s" % path)


CMAKE_BLOCK = """if(ALSOFT_REQUIRE_OPENSL AND NOT HAVE_OPENSL)
    message(FATAL_ERROR "Failed to enable required OpenSL backend")
endif()

# Check for OHAudio (OpenHarmony) backend
option(ALSOFT_BACKEND_OHAUDIO "Enable OHAudio backend" ON)
option(ALSOFT_REQUIRE_OHAUDIO "Require OHAudio backend" OFF)
if(ALSOFT_BACKEND_OHAUDIO)
    find_path(OHAUDIO_INCLUDE_DIR NAMES ohaudio/native_audiostream_base.h)
    find_library(OH_AUDIO_LIBRARY NAMES ohaudio)
    find_library(HILOG_LIBRARY NAMES hilog_ndk.z)
    if(OHAUDIO_INCLUDE_DIR AND OH_AUDIO_LIBRARY)
        set(HAVE_OHAUDIO 1)
        set(ALC_OBJS  ${ALC_OBJS} alc/backends/ohaudio.cpp alc/backends/ohaudio.h)
        set(BACKENDS  "${BACKENDS} OHAudio,")
        set(EXTRA_LIBS "${OH_AUDIO_LIBRARY}" "${HILOG_LIBRARY}" ${EXTRA_LIBS})
        list(APPEND INC_PATHS ${OHAUDIO_INCLUDE_DIR})
    endif()
endif()
if(ALSOFT_REQUIRE_OHAUDIO AND NOT HAVE_OHAUDIO)
    message(FATAL_ERROR "Failed to enable required OHAudio backend")
endif()
"""

# The OpenSL require block this patch anchors on (1.23.x vs 1.24.x wording).
OPENSL_REQUIRE_BLOCK = [
    'if(ALSOFT_REQUIRE_OPENSL AND NOT HAVE_OPENSL)\n'
    '    message(FATAL_ERROR "Failed to enabled required OpenSL backend")\n'
    'endif()\n',
    'if(ALSOFT_REQUIRE_OPENSL AND NOT HAVE_OPENSL)\n'
    '    message(FATAL_ERROR "Failed to enable required OpenSL backend")\n'
    'endif()\n',
]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_openal_ohaudio.py <openal-soft-src-root>")
    root = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    src_dir = os.path.join(here, "ohaudio")

    backends = os.path.join(root, "alc", "backends")
    if not os.path.isdir(backends):
        raise SystemExit("not an openal-soft tree (missing alc/backends): %s" % root)

    for name in ("ohaudio.cpp", "ohaudio.h"):
        shutil.copyfile(os.path.join(src_dir, name), os.path.join(backends, name))
        print("installed alc/backends/%s" % name)

    patch_file(os.path.join(root, "CMakeLists.txt"), [
        (
            "set(HAVE_OBOE       0)\n",
            "set(HAVE_OBOE       0)\nset(HAVE_OHAUDIO    0)\n",
            1,
        ),
        (
            OPENSL_REQUIRE_BLOCK,
            CMAKE_BLOCK,
            1,
        ),
    ])

    # 1.24+ moved the backend feature macros to config_backends.h.in (0/1 form).
    backends_h_in = os.path.join(root, "config_backends.h.in")
    if os.path.exists(backends_h_in):
        patch_file(backends_h_in, [
            (
                "#cmakedefine01 HAVE_OBOE\n",
                "#cmakedefine01 HAVE_OBOE\n\n#cmakedefine01 HAVE_OHAUDIO\n",
                1,
            ),
        ])
    else:
        patch_file(os.path.join(root, "config.h.in"), [
            (
                "/* Define if we have the Oboe backend */\n#cmakedefine HAVE_OBOE\n",
                "/* Define if we have the Oboe backend */\n#cmakedefine HAVE_OBOE\n\n"
                "/* Define if we have the OHAudio backend */\n#cmakedefine HAVE_OHAUDIO\n",
                1,
            ),
        ])

    patch_file(os.path.join(root, "alc", "alc.cpp"), [
        (
            [
                "#ifdef HAVE_OBOE\n#include \"backends/oboe.h\"\n#endif\n",
                "#if HAVE_OBOE\n#include \"backends/oboe.h\"\n#endif\n",
            ],
            [
                "#ifdef HAVE_OBOE\n#include \"backends/oboe.h\"\n#endif\n"
                "#ifdef HAVE_OHAUDIO\n#include \"backends/ohaudio.h\"\n#endif\n",
                "#if HAVE_OBOE\n#include \"backends/oboe.h\"\n#endif\n"
                "#if HAVE_OHAUDIO\n#include \"backends/ohaudio.h\"\n#endif\n",
            ],
            1,
        ),
        (
            [
                "#ifdef HAVE_OPENSL\n    { \"opensl\", OSLBackendFactory::getFactory },\n#endif\n",
                "#if HAVE_OPENSL\n    BackendInfo{\"opensl\", OSLBackendFactory::getFactory},\n#endif\n",
            ],
            [
                "#ifdef HAVE_OHAUDIO\n    { \"ohaudio\", OHAudioBackendFactory::getFactory },\n#endif\n"
                "#ifdef HAVE_OPENSL\n    { \"opensl\", OSLBackendFactory::getFactory },\n#endif\n",
                "#if HAVE_OHAUDIO\n    BackendInfo{\"ohaudio\", OHAudioBackendFactory::getFactory},\n#endif\n"
                "#if HAVE_OPENSL\n    BackendInfo{\"opensl\", OSLBackendFactory::getFactory},\n#endif\n",
            ],
            1,
        ),
    ])


if __name__ == "__main__":
    main()
