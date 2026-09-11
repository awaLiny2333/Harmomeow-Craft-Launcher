#!/bin/sh
# Generate LWJGL2's generated Java + JNI C sources for the OHOS build — ANT-FREE.
#
# Why not the official Ant build: it needs Ant + (source/target 1.6 => JDK 8) + the
# removed `javah` task — none of which this environment has. As with the LWJGL3
# natives (tools/lwjgl/build_lwjgl_natives.sh drives clang directly instead of Ant),
# we drive the annotation-processor generator with plain `javac` (it only uses
# javax.annotation.processing / javax.lang.model, so any JDK >= 9 works), and emit
# JNI headers with `javac -h` instead of javah.
#
# The step list mirrors ref/lwjgl/platform_build/build-generator.xml <target name="generate-all">
# and ref/lwjgl/build.xml <target name="headers"> (see notes there for why each is needed).
#
# MUST be run by a human (needs a JDK; the agent shell cannot run a JVM).
#
# Usage: sh tools/lwjgl2/generate_sources.sh
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
WS="$(cd "$PROJ/.." && pwd)"
SRC="$WS/ref/lwjgl"

[ -d "$SRC/.git" ] || { echo "error: LWJGL2 source not found at $SRC" >&2; exit 2; }
command -v javac >/dev/null 2>&1 || { echo "error: 'javac' not found on PATH (need a JDK)" >&2; exit 2; }

JAVAC="javac"
BIN="$SRC/bin-meow"                       # compiled generator + helper classes
GENJ="$SRC/src/generated"                 # generated Java
GENN="$SRC/src/native/generated"          # generated native (C)
HDR="$SRC/src/hdrs-meow"                  # generated JNI headers
JAVA="$SRC/src/java"
TPL="$SRC/src/templates/org/lwjgl"
# Prebuilt LWJGL2 runtime jar + its optional JInput dep, both vendored in-tree. Used only as a
# compile CLASSPATH for the header pass so javac resolves referenced types from compiled classes
# instead of attributing (and failing on) unrelated sources (macosx/JInput/opencl/...).
LWJGL2_JAR="$SRC/eclipse-update/org.lwjgl/lwjgl.jar"
JINPUT_JAR="$SRC/libs/jinput.jar"

echo "=== clean previous generated output ==="
rm -rf "$BIN" "$GENJ" "$GENN" "$HDR"
mkdir -p "$BIN" "$GENJ" "$GENN/opengl" "$GENN/openal" "$GENN/opengles" "$GENN/opencl" "$HDR"

echo "=== (1) compile the generator + template helper classes ==="
# Generator processor classes. -sourcepath lets javac resolve the sibling classes the
# generator imports on demand. -proc:none: don't auto-run annotation processors here.
find "$JAVA/org/lwjgl/util/generator" -name '*.java' > "$BIN/gen.txt"
"$JAVAC" -nowarn -encoding UTF-8 -proc:none -sourcepath "$JAVA" -d "$BIN" @"$BIN/gen.txt"

# Helper classes the templates reference (build-generator.xml:36-56) — OpenGL, OpenGL ES, OpenCL.
: > "$BIN/helpers.txt"
for h in \
  org/lwjgl/PointerWrapper.java org/lwjgl/PointerBuffer.java \
  org/lwjgl/opengl/GLSync.java org/lwjgl/opengl/AMDDebugOutputCallback.java \
  org/lwjgl/opengl/ARBDebugOutputCallback.java org/lwjgl/opengl/KHRDebugCallback.java \
  org/lwjgl/opengles/EGLImageOES.java org/lwjgl/opengles/KHRDebugCallback.java \
  org/lwjgl/opencl/CLPlatform.java org/lwjgl/opencl/CLDevice.java \
  org/lwjgl/opencl/CLContext.java org/lwjgl/opencl/CLCommandQueue.java \
  org/lwjgl/opencl/CLMem.java org/lwjgl/opencl/CLNativeKernel.java \
  org/lwjgl/opencl/CLFunctionAddress.java ; do
  [ -f "$JAVA/$h" ] && printf '%s\n' "$JAVA/$h" >> "$BIN/helpers.txt"
done
for f in "$JAVA/org/lwjgl/opencl/"CL*Callback.java; do
  [ -f "$f" ] && printf '%s\n' "$f" >> "$BIN/helpers.txt"
done
"$JAVAC" -nowarn -encoding UTF-8 -proc:none -sourcepath "$JAVA" -cp "$BIN" -d "$BIN" @"$BIN/helpers.txt"

CP="$BIN"
SP="$JAVA:$BIN"

# The local Filer-bypass patch in GeneratorVisitor.visitTypeAsInterface writes the generated Java
# straight to src/generated, computing that path RELATIVE TO CWD -> run the processor from $SRC.
cd "$SRC"

# One template set + one processor. $1 processor, $2 template argfile, $3 native -d dir, rest: -A opts.
gen() {
  _proc="$1"; _list="$2"; _out="$3"; shift 3
  "$JAVAC" -nowarn -encoding UTF-8 -implicit:none -proc:only -processor "$_proc" \
    -cp "$CP" -sourcepath "$SP" -s "$GENJ" -d "$_out" -Abinpath="$BIN" "$@" @"$_list"
}

# Template file lists (mirror build-definitions.xml include patterns; each dir is uniform).
find "$TPL/opengl"  -maxdepth 1 -name '*.java' > "$BIN/tpl-gl.txt"
find "$TPL/opengles" -maxdepth 1 -name '*.java' > "$BIN/tpl-gles.txt"
find "$TPL/opencl"  -maxdepth 1 -name '*.java' > "$BIN/tpl-cl.txt"
ls "$TPL/openal"/AL*.java "$TPL/openal"/EFX*.java > "$BIN/tpl-al.txt"

echo "=== (2) generate sources (mirror generate-all) ==="
echo "--- (2.1) OpenGL API ---"
gen org.lwjgl.util.generator.GeneratorProcessor "$BIN/tpl-gl.txt" "$GENN/opengl" \
  -Atypemap=org.lwjgl.util.generator.opengl.GLTypeMap -Acontextspecific
echo "--- (2.2) OpenGL ContextCapabilities ---"
gen org.lwjgl.util.generator.opengl.GLGeneratorProcessor "$BIN/tpl-gl.txt" "$GENN/opengl" \
  -Acontextspecific
echo "--- (2.3) OpenGL References ---"
gen org.lwjgl.util.generator.opengl.GLReferencesGeneratorProcessor "$BIN/tpl-gl.txt" "$GENN/opengl"
echo "--- (2.4) OpenAL ---"
gen org.lwjgl.util.generator.GeneratorProcessor "$BIN/tpl-al.txt" "$GENN/openal" \
  -Atypemap=org.lwjgl.util.generator.openal.ALTypeMap
echo "--- (2.5) OpenGL ES API ---"
gen org.lwjgl.util.generator.GeneratorProcessor "$BIN/tpl-gles.txt" "$GENN/opengles" \
  -Atypemap=org.lwjgl.util.generator.opengl.GLESTypeMap
echo "--- (2.6) OpenGL ES capabilities ---"
gen org.lwjgl.util.generator.opengl.GLESGeneratorProcessor "$BIN/tpl-gles.txt" "$GENN/opengles"
echo "--- (2.7) OpenCL API ---"
gen org.lwjgl.util.generator.GeneratorProcessor "$BIN/tpl-cl.txt" "$GENN/opencl" \
  -Atypemap=org.lwjgl.util.generator.opencl.CLTypeMap -Acontextspecific
echo "--- (2.8) OpenCL capabilities ---"
gen org.lwjgl.util.generator.opencl.CLGeneratorProcessor "$BIN/tpl-cl.txt" "$GENN/opencl" \
  -Acontextspecific

echo "=== (3) generate JNI headers (javac -h, replaces javah) ==="
# Mirror build.xml <target name="headers">: javah ran on a FIXED per-platform class list, never
# over the whole tree. We take the platform-independent + OpenGL + Linux(->OHOS) sets.
# -sourcepath is our OWN java + generated tree (authoritative: the vendored prebuilt lwjgl.jar in
# eclipse-update/ is an older build and lacks newer members like DisplayMode.toScreen/ContextGL).
# -cp adds jinput.jar so input.Display->Controllers resolves.
# -XDshould-stop.ifError=GENERATE keeps javac generating outputs even if an unrelated implicitly
# loaded source (macosx/com.apple.eio, MemoryUtilSun/sun.reflect) fails to attribute.
HEADER_CLASSES="
org.lwjgl.DefaultSysImplementation
org.lwjgl.BufferUtils
org.lwjgl.input.Cursor
org.lwjgl.input.Keyboard
org.lwjgl.input.Mouse
org.lwjgl.openal.AL
org.lwjgl.opengl.GLContext
org.lwjgl.opengl.Pbuffer
org.lwjgl.opengl.CallbackUtil
org.lwjgl.opengl.NVPresentVideoUtil
org.lwjgl.opengl.NVVideoCaptureUtil
org.lwjgl.LinuxSysImplementation
org.lwjgl.opengl.LinuxEvent
org.lwjgl.opengl.LinuxMouse
org.lwjgl.opengl.LinuxKeyboard
org.lwjgl.opengl.LinuxDisplay
org.lwjgl.opengl.LinuxPeerInfo
org.lwjgl.opengl.LinuxPbufferPeerInfo
org.lwjgl.opengl.LinuxDisplayPeerInfo
org.lwjgl.opengl.LinuxContextImplementation
org.lwjgl.opengl.LinuxCanvasImplementation
org.lwjgl.opengl.AWTSurfaceLock
org.lwjgl.opencl.CL
org.lwjgl.opencl.CallbackUtil
org.lwjgl.opengles.EGL
org.lwjgl.opengles.EGLKHRFenceSync
org.lwjgl.opengles.EGLKHRReusableSync
org.lwjgl.opengles.EGLNVSync
org.lwjgl.opengles.GLContext
org.lwjgl.opengles.CallbackUtil
"
: > "$BIN/hdr-classes.txt"
for c in $HEADER_CLASSES; do printf '%s\n' "$JAVA/$(echo "$c" | tr '.' '/').java" >> "$BIN/hdr-classes.txt"; done
"$JAVAC" -nowarn -encoding UTF-8 -implicit:none -h "$HDR" -d "$BIN/hdrclasses" \
  -sourcepath "$JAVA:$GENJ" -cp "$BIN:$JINPUT_JAR" -XDshould-stop.ifError=GENERATE \
  @"$BIN/hdr-classes.txt" \
  || echo "WARN: header compile had errors; if the native build later misses a header, adjust HEADER_CLASSES"

echo "=== results ==="
echo "generated JNI C (opengl):   $(ls "$GENN/opengl" 2>/dev/null | wc -l) files"
echo "generated JNI C (openal):   $(ls "$GENN/openal" 2>/dev/null | wc -l) files"
echo "generated JNI C (opengles): $(ls "$GENN/opengles" 2>/dev/null | wc -l) files"
echo "generated JNI C (opencl):   $(ls "$GENN/opencl" 2>/dev/null | wc -l) files"
echo "generated Java:             $(find "$GENJ" -name '*.java' 2>/dev/null | wc -l) files"
echo "JNI headers:                $(ls "$HDR" 2>/dev/null | wc -l) files"
ls "$HDR" 2>/dev/null | head
