#!/usr/bin/env python3
"""Patch OpenAL Soft's OpenSL backend for HarmonyOS (OHOS).

Upstream OpenAL Soft's `alc/backends/opensl.cpp` targets Android: it includes
<SLES/OpenSLES_Android.h>, uses the Android simple buffer queue IID, and (in a
disabled block) JNI. OHOS ships only <SLES/OpenSLES_OpenHarmony.h> with its own
`SL_IID_OH_BUFFERQUEUE` / `SLOHBufferQueueItf`, and no Android headers or jni.h.

This patcher rewrites the backend so it builds and runs on OHOS while staying
buildable for Android (everything OHOS-specific is guarded by `__OHOS__`).

Usage:
    python3 patch_openal_ohos.py <path-to-alc/backends/opensl.cpp>

Anchored, exact-match replacements: if the file does not match the expected
upstream text (wrong version / already patched), the script fails loudly.
"""
import re
import sys


# (old, new, expected_occurrences)
REPLACEMENTS = [
    # jni.h is absent from the OHOS NDK. The only JNI use is inside `#if 0`.
    # 1.24.x reordered the include block (jni.h first, then the std headers).
    (
        [
            "#include <stdlib.h>\n#include <jni.h>\n",
            '#include "opensl.h"\n\n#include <jni.h>\n',
        ],
        [
            "#include <stdlib.h>\n#ifndef __OHOS__\n#include <jni.h>\n#endif\n",
            '#include "opensl.h"\n\n#ifndef __OHOS__\n#include <jni.h>\n#endif\n',
        ],
        1,
    ),
    # OHOS has no Android OpenSL headers.
    (
        "#include <SLES/OpenSLES.h>\n"
        "#include <SLES/OpenSLES_Android.h>\n"
        "#include <SLES/OpenSLES_AndroidConfiguration.h>\n",
        "#include <SLES/OpenSLES.h>\n"
        "#ifndef __OHOS__\n"
        "#include <SLES/OpenSLES_Android.h>\n"
        "#include <SLES/OpenSLES_AndroidConfiguration.h>\n"
        "#endif\n",
        1,
    ),
    # Neutral aliases so the backend body stays source-compatible.
    (
        "SLAndroidSimpleBufferQueueState",
        "MeowBufferQueueState",
        1,
    ),
    (
        "SLDataLocator_AndroidSimpleBufferQueue",
        "MeowDataLocator_BufferQueue",
        2,
    ),
    (
        "SL_IID_ANDROIDSIMPLEBUFFERQUEUE",
        "MEOW_SL_IID_BUFFERQUEUE",
        {8, 11},
    ),
    (
        "SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE",
        "MEOW_SL_DATALOCATOR_BUFFERQUEUE",
        2,
    ),
    (
        "SLAndroidSimpleBufferQueueItf",
        "MeowBufferQueueItf",
        11,
    ),
    # Inserted last (after the renames above) so its `#else` branch keeps the
    # real Android spellings.
    (
        "\nnamespace {\n",
        "\n#ifdef __OHOS__\n"
        "#include <SLES/OpenSLES_OpenHarmony.h>\n"
        "using MeowBufferQueueItf = SLOHBufferQueueItf;\n"
        "using MeowBufferQueueState = SLOHBufferQueueState;\n"
        "using MeowDataLocator_BufferQueue = SLDataLocator_BufferQueue;\n"
        "#define MEOW_SL_IID_BUFFERQUEUE SL_IID_OH_BUFFERQUEUE\n"
        "#define MEOW_SL_DATALOCATOR_BUFFERQUEUE SL_DATALOCATOR_BUFFERQUEUE\n"
        "#else\n"
        "using MeowBufferQueueItf = SLAndroidSimpleBufferQueueItf;\n"
        "using MeowBufferQueueState = SLAndroidSimpleBufferQueueState;\n"
        "using MeowDataLocator_BufferQueue = SLDataLocator_AndroidSimpleBufferQueue;\n"
        "#define MEOW_SL_IID_BUFFERQUEUE SL_IID_ANDROIDSIMPLEBUFFERQUEUE\n"
        "#define MEOW_SL_DATALOCATOR_BUFFERQUEUE SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE\n"
        "#endif\n"
        "\nnamespace {\n",
        1,
    ),
    # Playback: no interfaces at creation on OHOS; the OH buffer queue is fetched
    # via GetInterface (matches the official OpenSL ES sample).
    (
        "    const std::array<SLInterfaceID,2> ids{{ MEOW_SL_IID_BUFFERQUEUE, SL_IID_ANDROIDCONFIGURATION }};\n"
        "    const std::array<SLboolean,2> reqs{{ SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE }};\n",
        "#ifdef __OHOS__\n"
        "    const std::array<SLInterfaceID,0> ids{};\n"
        "    const std::array<SLboolean,0> reqs{};\n"
        "#else\n"
        "    const std::array<SLInterfaceID,2> ids{{ MEOW_SL_IID_BUFFERQUEUE, SL_IID_ANDROIDCONFIGURATION }};\n"
        "    const std::array<SLboolean,2> reqs{{ SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE }};\n"
        "#endif\n",
        1,
    ),
    # Capture: same as playback, deeper indentation.
    (
        "        const std::array<SLInterfaceID,2> ids{{ MEOW_SL_IID_BUFFERQUEUE, SL_IID_ANDROIDCONFIGURATION }};\n"
        "        const std::array<SLboolean,2> reqs{{ SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE }};\n",
        "#ifdef __OHOS__\n"
        "        const std::array<SLInterfaceID,0> ids{};\n"
        "        const std::array<SLboolean,0> reqs{};\n"
        "#else\n"
        "        const std::array<SLInterfaceID,2> ids{{ MEOW_SL_IID_BUFFERQUEUE, SL_IID_ANDROIDCONFIGURATION }};\n"
        "        const std::array<SLboolean,2> reqs{{ SL_BOOLEAN_TRUE, SL_BOOLEAN_FALSE }};\n"
        "#endif\n",
        1,
    ),
    # Android stream type / recording preset configuration is Android-only.
    (
        "    if(SL_RESULT_SUCCESS == result)\n"
        "    {\n"
        "        /* Set the stream type to \"media\" (games, music, etc), if possible. */\n"
        "        SLAndroidConfigurationItf config;\n"
        "        result = VCALL(mBufferQueueObj,GetInterface)(SL_IID_ANDROIDCONFIGURATION, &config);\n"
        "        PrintErr(result, \"bufferQueue->GetInterface SL_IID_ANDROIDCONFIGURATION\");\n"
        "        if(SL_RESULT_SUCCESS == result)\n"
        "        {\n"
        "            SLint32 streamType = SL_ANDROID_STREAM_MEDIA;\n"
        "            result = VCALL(config,SetConfiguration)(SL_ANDROID_KEY_STREAM_TYPE, &streamType,\n"
        "                sizeof(streamType));\n"
        "            PrintErr(result, \"config->SetConfiguration\");\n"
        "        }\n"
        "\n"
        "        /* Clear any error since this was optional. */\n"
        "        result = SL_RESULT_SUCCESS;\n"
        "    }\n",
        "#ifndef __OHOS__\n"
        "    if(SL_RESULT_SUCCESS == result)\n"
        "    {\n"
        "        /* Set the stream type to \"media\" (games, music, etc), if possible. */\n"
        "        SLAndroidConfigurationItf config;\n"
        "        result = VCALL(mBufferQueueObj,GetInterface)(SL_IID_ANDROIDCONFIGURATION, &config);\n"
        "        PrintErr(result, \"bufferQueue->GetInterface SL_IID_ANDROIDCONFIGURATION\");\n"
        "        if(SL_RESULT_SUCCESS == result)\n"
        "        {\n"
        "            SLint32 streamType = SL_ANDROID_STREAM_MEDIA;\n"
        "            result = VCALL(config,SetConfiguration)(SL_ANDROID_KEY_STREAM_TYPE, &streamType,\n"
        "                sizeof(streamType));\n"
        "            PrintErr(result, \"config->SetConfiguration\");\n"
        "        }\n"
        "\n"
        "        /* Clear any error since this was optional. */\n"
        "        result = SL_RESULT_SUCCESS;\n"
        "    }\n"
        "#endif\n",
        1,
    ),
    (
        "    if(SL_RESULT_SUCCESS == result)\n"
        "    {\n"
        "        /* Set the record preset to \"generic\", if possible. */\n"
        "        SLAndroidConfigurationItf config;\n"
        "        result = VCALL(mRecordObj,GetInterface)(SL_IID_ANDROIDCONFIGURATION, &config);\n"
        "        PrintErr(result, \"recordObj->GetInterface SL_IID_ANDROIDCONFIGURATION\");\n"
        "        if(SL_RESULT_SUCCESS == result)\n"
        "        {\n"
        "            SLuint32 preset = SL_ANDROID_RECORDING_PRESET_GENERIC;\n"
        "            result = VCALL(config,SetConfiguration)(SL_ANDROID_KEY_RECORDING_PRESET, &preset,\n"
        "                sizeof(preset));\n"
        "            PrintErr(result, \"config->SetConfiguration\");\n"
        "        }\n"
        "\n"
        "        /* Clear any error since this was optional. */\n"
        "        result = SL_RESULT_SUCCESS;\n"
        "    }\n",
        "#ifndef __OHOS__\n"
        "    if(SL_RESULT_SUCCESS == result)\n"
        "    {\n"
        "        /* Set the record preset to \"generic\", if possible. */\n"
        "        SLAndroidConfigurationItf config;\n"
        "        result = VCALL(mRecordObj,GetInterface)(SL_IID_ANDROIDCONFIGURATION, &config);\n"
        "        PrintErr(result, \"recordObj->GetInterface SL_IID_ANDROIDCONFIGURATION\");\n"
        "        if(SL_RESULT_SUCCESS == result)\n"
        "        {\n"
        "            SLuint32 preset = SL_ANDROID_RECORDING_PRESET_GENERIC;\n"
        "            result = VCALL(config,SetConfiguration)(SL_ANDROID_KEY_RECORDING_PRESET, &preset,\n"
        "                sizeof(preset));\n"
        "            PrintErr(result, \"config->SetConfiguration\");\n"
        "        }\n"
        "\n"
        "        /* Clear any error since this was optional. */\n"
        "        result = SL_RESULT_SUCCESS;\n"
        "    }\n"
        "#endif\n",
        1,
    ),
    # OHOS callback has an extra size argument.
    # 1.23.x registers a named `processC`; 1.24.x registers an inline lambda.
    (
        [
            "    static void processC(MeowBufferQueueItf bq, void *context) noexcept\n"
            "    { static_cast<OpenSLPlayback*>(context)->process(bq); }\n",
            "            [](MeowBufferQueueItf bq, void *context) noexcept\n"
            "            { static_cast<OpenSLPlayback*>(context)->process(bq); }, this);\n",
        ],
        [
            "#ifdef __OHOS__\n"
            "    static void processC(SLOHBufferQueueItf bq, void *context, SLuint32 /*size*/) noexcept\n"
            "    { static_cast<OpenSLPlayback*>(context)->process(bq); }\n"
            "#else\n"
            "    static void processC(MeowBufferQueueItf bq, void *context) noexcept\n"
            "    { static_cast<OpenSLPlayback*>(context)->process(bq); }\n"
            "#endif\n",
            "#ifdef __OHOS__\n"
            "            [](SLOHBufferQueueItf bq, void *context, SLuint32 /*size*/) noexcept\n"
            "            { static_cast<OpenSLPlayback*>(context)->process(bq); }, this);\n"
            "#else\n"
            "            [](MeowBufferQueueItf bq, void *context) noexcept\n"
            "            { static_cast<OpenSLPlayback*>(context)->process(bq); }, this);\n"
            "#endif\n",
        ],
        1,
    ),
    (
        [
            "    static void processC(MeowBufferQueueItf bq, void *context) noexcept\n"
            "    { static_cast<OpenSLCapture*>(context)->process(bq); }\n",
            "            [](MeowBufferQueueItf bq, void *context) noexcept\n"
            "            { static_cast<OpenSLCapture*>(context)->process(bq); }, this);\n",
        ],
        [
            "#ifdef __OHOS__\n"
            "    static void processC(SLOHBufferQueueItf bq, void *context, SLuint32 /*size*/) noexcept\n"
            "    { static_cast<OpenSLCapture*>(context)->process(bq); }\n"
            "#else\n"
            "    static void processC(MeowBufferQueueItf bq, void *context) noexcept\n"
            "    { static_cast<OpenSLCapture*>(context)->process(bq); }\n"
            "#endif\n",
            "#ifdef __OHOS__\n"
            "            [](SLOHBufferQueueItf bq, void *context, SLuint32 /*size*/) noexcept\n"
            "            { static_cast<OpenSLCapture*>(context)->process(bq); }, this);\n"
            "#else\n"
            "            [](MeowBufferQueueItf bq, void *context) noexcept\n"
            "            { static_cast<OpenSLCapture*>(context)->process(bq); }, this);\n"
            "#endif\n",
        ],
        1,
    ),
]


def patch(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()

    for old, new, count in REPLACEMENTS:
        # Upstream reworded some anchors between releases, so `old`/`new` may be
        # parallel lists of version-specific variants and `count` an accepted
        # occurrence count (int) or set of counts. Exactly one variant must match
        # an accepted count, else the tree is not a recognised version.
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
                % (path, counts,
                   "\n".join("  %r" % c[:120] for c, _ in pairs)))
        text = text.replace(hit[0], hit[1])

    # 1.24.x lists the Android-only configuration IID in the dynload symbol table;
    # OHOS has no <SLES/OpenSLES_AndroidConfiguration.h>, so the identifier is
    # undefined. Its only consumers are the Android config blocks, already guarded
    # by `#ifndef __OHOS__` above, so drop the symbol from the table and the alias.
    text = re.sub(r'[ \t]*MAGIC\(SL_IID_ANDROIDCONFIGURATION\);[ \t]*\\\n', '', text)
    text = re.sub(r'#define SL_IID_ANDROIDCONFIGURATION \(\*pSL_IID_ANDROIDCONFIGURATION\)\n',
                  '', text)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("patched %s (OHOS OpenSL backend)" % path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_openal_ohos.py <alc/backends/opensl.cpp>")
    patch(sys.argv[1])
