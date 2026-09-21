#!/usr/bin/env python3
"""patch_sdl_ohos.py - install Meowcraft's OpenHarmony (OHOS) video driver into SDL3.

Usage:
    python3 patch_sdl_ohos.py <SDL3-source-dir>

The patcher is idempotent: every edit is check-then-insert, so it is safe to run
repeatedly against the same tree. It fails loudly (non-zero exit) if an expected
anchor is missing, so a future SDL version cannot silently skip a change.

What it does:
    1. src/thread/pthread/SDL_systhread.c: guard pthread_setcanceltype()
       (OHOS dynamic libc lacks PTHREAD_CANCEL_ASYNCHRONOUS).
    2. Copy this tool's src/video/ohos/*.c/.h into <src>/src/video/ohos/, and
       src/misc/ohos/*.c/.h into <src>/src/misc/ohos/.
    3. CMakeLists.txt: enable SDL_VIDEO_DRIVER_OHOS + EGL/GL in the unix branch
       (and glob src/misc/ohos/*).
    4. include/build_config/SDL_build_config.h.cmake: emit the driver define.
    5. src/video/SDL_sysvideo.h: extern OHOS_bootstrap.
    6. src/video/SDL_video.c: add OHOS_bootstrap to bootstrap[].
    7. src/video/SDL_egl.c: OHOS EGL/GL library names.
    8. src/video/khronos/EGL/eglplatform.h: OHOS EGLNativeWindowType typedef.
    9. src/misc/unix/SDL_sysurl.c: wrap its body in #if !defined(__OHOS__), so that
       src/misc/ohos/SDL_sysurl.c is the only SDL_SYS_OpenURL in this build (the unix
       one opens URLs by forking xdg-open, which OHOS does not have).
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DRIVER_SRC = os.path.join(HERE, "src", "video", "ohos")
MISC_SRC = os.path.join(HERE, "src", "misc", "ohos")


def die(msg):
    sys.stderr.write("patch_sdl_ohos: error: %s\n" % msg)
    sys.exit(1)


def log(msg):
    print("  - %s" % msg)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc))


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def ensure(cond, msg):
    if not cond:
        die(msg)


def patch_pthread(src):
    path = os.path.join(src, "src", "thread", "pthread", "SDL_systhread.c")
    ensure(os.path.isfile(path), "missing %s" % path)
    text = read_text(path)
    guarded = "#if defined(PTHREAD_CANCEL_ASYNCHRONOUS) && !defined(__OHOS__)"
    if guarded in text:
        log("pthread guard already applied")
        return
    old = "#ifdef PTHREAD_CANCEL_ASYNCHRONOUS"
    ensure(old in text, "pthread anchor '%s' not found in %s" % (old, path))
    text = text.replace(old, guarded, 1)
    write_text(path, text)
    log("guarded pthread_setcanceltype() for OHOS")


def copy_driver(src):
    dst = os.path.join(src, "src", "video", "ohos")
    ensure(os.path.isdir(DRIVER_SRC), "driver sources not found: %s" % DRIVER_SRC)
    os.makedirs(dst, exist_ok=True)
    copied = []
    for name in sorted(os.listdir(DRIVER_SRC)):
        if not name.endswith((".c", ".h")):
            continue
        shutil.copy2(os.path.join(DRIVER_SRC, name), os.path.join(dst, name))
        copied.append(name)
    ensure(copied, "no driver sources found under %s" % DRIVER_SRC)
    log("copied driver sources to src/video/ohos (%s)" % ", ".join(copied))

    # The OHOS URL opener sits next to the driver here, but SDL compiles it from
    # src/misc/<platform>/SDL_sysurl.c, so it is copied to its own directory.
    misc_dst = os.path.join(src, "src", "misc", "ohos")
    ensure(os.path.isdir(MISC_SRC), "misc sources not found: %s" % MISC_SRC)
    os.makedirs(misc_dst, exist_ok=True)
    misc_copied = []
    for name in sorted(os.listdir(MISC_SRC)):
        if not name.endswith((".c", ".h")):
            continue
        shutil.copy2(os.path.join(MISC_SRC, name), os.path.join(misc_dst, name))
        misc_copied.append(name)
    ensure(misc_copied, "no misc sources found under %s" % MISC_SRC)
    log("copied misc sources to src/misc/ohos (%s)" % ", ".join(misc_copied))


def patch_sysurl(src):
    """Keep the unix SDL_sysurl.c out of the OHOS build.

    It opens URLs by forking `xdg-open`, which does not exist on OHOS; the OHOS build
    takes src/misc/ohos/SDL_sysurl.c instead (globbed in from the CMake block below)."""
    path = os.path.join(src, "src", "misc", "unix", "SDL_sysurl.c")
    ensure(os.path.isfile(path), "missing %s" % path)
    text = read_text(path)
    marker = "the unix implementation forks xdg-open"
    if marker in text:
        log("unix SDL_sysurl.c already guarded")
        return
    anchor = '#include "SDL_internal.h"\n'
    ensure(anchor in text, "anchor '%s' not found in %s" % (anchor.strip(), path))
    text = text.replace(
        anchor,
        anchor
        + "\n/* This fork: the OHOS build takes src/misc/ohos/SDL_sysurl.c instead\n"
        + " * (the unix implementation forks xdg-open, which does not exist on OHOS). */\n"
        + "#if !defined(__OHOS__)\n",
        1,
    )
    text = text + "\n#endif /* !__OHOS__ */\n"
    write_text(path, text)
    log("guarded unix SDL_sysurl.c for OHOS")


CMAKE_BLOCK = """    CheckVivante()
    CheckVulkan()
    CheckQNXScreen()

    # OpenHarmony (OHOS): the SDK toolchain re-labels the target as Linux (see
    # tools/sdl/sdl_ohos.toolchain.cmake) so we extend the unix branch here.
    if(OHOS)
      set(SDL_VIDEO_DRIVER_OHOS 1)
      sdl_glob_sources(
        "${SDL3_SOURCE_DIR}/src/video/ohos/*.c"
        "${SDL3_SOURCE_DIR}/src/video/ohos/*.h"
        "${SDL3_SOURCE_DIR}/src/misc/ohos/*.c"
        "${SDL3_SOURCE_DIR}/src/misc/ohos/*.h"
      )
      set(SDL_VIDEO_OPENGL 1)
      set(SDL_VIDEO_OPENGL_ES2 1)
      set(SDL_VIDEO_OPENGL_EGL 1)
      set(HAVE_SDL_VIDEO TRUE)
      # Pin the OHNativeWindow producer buffer geometry to the real client size
      # (SET_BUFFER_GEOMETRY) so the EGL window surface matches the XComponent.
      sdl_link_dependency(ohosnativewindow LIBS native_window)
    endif()
"""


def patch_cmake(src):
    path = os.path.join(src, "CMakeLists.txt")
    text = read_text(path)
    if "SDL_VIDEO_DRIVER_OHOS" not in text:
        anchor = "    CheckVivante()\n    CheckVulkan()\n    CheckQNXScreen()\n"
        ensure(anchor in text, "CMake anchor (CheckVivante/CheckVulkan/CheckQNXScreen) not found")
        text = text.replace(anchor, CMAKE_BLOCK, 1)
        write_text(path, text)
        log("added OHOS video driver branch to CMakeLists.txt")
        return
    # Idempotently ensure the native_window link dependency exists (added later;
    # older trees already have the OHOS block without it).
    if "native_window" not in text:
        anchor2 = "      set(HAVE_SDL_VIDEO TRUE)\n"
        ensure(anchor2 in text, "OHOS CMake block anchor (set(HAVE_SDL_VIDEO TRUE)) not found")
        text = text.replace(
            anchor2,
            anchor2 + "      sdl_link_dependency(ohosnativewindow LIBS native_window)\n",
            1,
        )
        write_text(path, text)
        log("added native_window link dependency to CMakeLists.txt")
    else:
        # Backfill the misc glob for trees patched before the URL opener existed.
        video_globs = (
            '        "${SDL3_SOURCE_DIR}/src/video/ohos/*.c"\n'
            '        "${SDL3_SOURCE_DIR}/src/video/ohos/*.h"\n'
        )
        if "src/misc/ohos/*.c" not in text:
            ensure(video_globs in text, "OHOS video glob anchor not found")
            text = text.replace(
                video_globs,
                video_globs
                + '        "${SDL3_SOURCE_DIR}/src/misc/ohos/*.c"\n'
                + '        "${SDL3_SOURCE_DIR}/src/misc/ohos/*.h"\n',
                1,
            )
            write_text(path, text)
            log("added the src/misc/ohos glob to CMakeLists.txt")
        else:
            log("CMakeLists.txt OHOS branch already present")


def patch_build_config(src):
    path = os.path.join(src, "include", "build_config", "SDL_build_config.h.cmake")
    text = read_text(path)
    if "SDL_VIDEO_DRIVER_OHOS" in text:
        log("SDL_build_config.h.cmake OHOS define already present")
        return
    anchor = "#cmakedefine SDL_VIDEO_DRIVER_OFFSCREEN 1\n"
    ensure(anchor in text, "build-config anchor SDL_VIDEO_DRIVER_OFFSCREEN not found")
    text = text.replace(anchor, anchor + "#cmakedefine SDL_VIDEO_DRIVER_OHOS 1\n", 1)
    write_text(path, text)
    log("added SDL_VIDEO_DRIVER_OHOS to SDL_build_config.h.cmake")


def patch_sysvideo_h(src):
    path = os.path.join(src, "src", "video", "SDL_sysvideo.h")
    text = read_text(path)
    if "OHOS_bootstrap" in text:
        log("SDL_sysvideo.h already declares OHOS_bootstrap")
        return
    anchor = "extern VideoBootStrap OFFSCREEN_bootstrap;\n"
    ensure(anchor in text, "SDL_sysvideo.h anchor OFFSCREEN_bootstrap not found")
    text = text.replace(anchor, anchor + "extern VideoBootStrap OHOS_bootstrap;\n", 1)
    write_text(path, text)
    log("declared OHOS_bootstrap in SDL_sysvideo.h")


def patch_bootstrap(src):
    path = os.path.join(src, "src", "video", "SDL_video.c")
    text = read_text(path)
    if "&OHOS_bootstrap," in text:
        log("SDL_video.c bootstrap[] already lists OHOS_bootstrap")
        return
    anchor = (
        "#ifdef SDL_VIDEO_DRIVER_OFFSCREEN\n"
        "    &OFFSCREEN_bootstrap,\n"
        "#endif\n"
        "#ifdef SDL_VIDEO_DRIVER_DUMMY\n"
    )
    ensure(anchor in text, "SDL_video.c bootstrap anchor (OFFSCREEN/DUMMY) not found")
    replacement = (
        "#ifdef SDL_VIDEO_DRIVER_OFFSCREEN\n"
        "    &OFFSCREEN_bootstrap,\n"
        "#endif\n"
        "#ifdef SDL_VIDEO_DRIVER_OHOS\n"
        "    &OHOS_bootstrap,\n"
        "#endif\n"
        "#ifdef SDL_VIDEO_DRIVER_DUMMY\n"
    )
    text = text.replace(anchor, replacement, 1)
    write_text(path, text)
    log("registered OHOS_bootstrap in SDL_video.c")


EGL_BLOCK = """#elif defined(SDL_VIDEO_DRIVER_OHOS)
// OpenHarmony / OHOS
#define DEFAULT_EGL        "libEGL.so"
#define DEFAULT_OGL        "libGLv4.so"
#define DEFAULT_OGL_ES2    "libGLESv2.so"
#define DEFAULT_OGL_ES_PVR "libGLES_CM.so"
#define DEFAULT_OGL_ES     "libGLESv1_CM.so"

"""


def patch_egl_libs(src):
    path = os.path.join(src, "src", "video", "SDL_egl.c")
    text = read_text(path)
    if "defined(SDL_VIDEO_DRIVER_OHOS)" in text:
        log("SDL_egl.c already has the OHOS library branch")
        return
    anchor = "#elif defined(SDL_VIDEO_DRIVER_WINDOWS)\n// EGL AND OpenGL ES support via ANGLE\n"
    ensure(anchor in text, "SDL_egl.c anchor (SDL_VIDEO_DRIVER_WINDOWS) not found")
    text = text.replace(anchor, EGL_BLOCK + anchor, 1)
    write_text(path, text)
    log("added OHOS EGL/GL library names to SDL_egl.c")


EGLPLATFORM_BLOCK = """#elif defined(__OHOS__)

#include <native_window/external_window.h>

typedef void              *EGLNativeDisplayType;
typedef void              *EGLNativePixmapType;
typedef struct OHNativeWindow *EGLNativeWindowType;

"""


def patch_eglplatform(src):
    path = os.path.join(src, "src", "video", "khronos", "EGL", "eglplatform.h")
    text = read_text(path)
    if "defined(__OHOS__)" in text:
        log("eglplatform.h already has the OHOS typedef")
        return
    anchor = "#elif defined(__unix__)\n"
    ensure(anchor in text, "eglplatform.h anchor (__unix__) not found")
    text = text.replace(anchor, EGLPLATFORM_BLOCK + anchor, 1)
    write_text(path, text)
    log("added OHOS EGLNativeWindowType typedef to eglplatform.h")


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: %s <SDL3-source-dir>\n" % sys.argv[0])
        return 2

    src = os.path.abspath(sys.argv[1])
    ensure(os.path.isfile(os.path.join(src, "CMakeLists.txt")),
           "%s does not look like an SDL3 source tree" % src)

    print("patching SDL3 OHOS video driver in %s" % src)
    patch_pthread(src)
    copy_driver(src)
    patch_sysurl(src)
    patch_cmake(src)
    patch_build_config(src)
    patch_sysvideo_h(src)
    patch_bootstrap(src)
    patch_egl_libs(src)
    patch_eglplatform(src)
    print("patch_sdl_ohos: done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
