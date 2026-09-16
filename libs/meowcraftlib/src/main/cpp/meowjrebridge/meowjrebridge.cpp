/*
 * meowjre HSP native bridge (source lives in the meowcraftlib HAR).
 *
 * Runs INSIDE the meowjre HSP so its native-lib namespace can dlopen the JRE
 * .so set that ships in the same HSP (entry's namespace cannot see them).
 * Entry calls us via `import('meowjre')` -> libmeowjrebridge.so NAPI.
 *
 * Launch flow: dlopen <jreLibsDir>/libjli.so (JRE module el1) -> JLI_Launch with
 * OHOS_JAVA_HOME=<filesDir>/meow-jres/meow_jre (data unpacked by entry), OHOS_DL_DIR=<jreLibsDir>.
 *
 * 渲染后端：按 MC 版本二选一（单一事实源 = ArkTS `RendererPolicy`，经 launchJvm 传入）：
 *   - ≥1.17：系统桌面 OpenGL（libGLv4.so / openglv4，Mesa Zink 直通）；
 *   - ≤1.16：自编 gl4es（libgl4es.so / gl4es，原生 GLES + 固定管线翻译）。
 * 本文件不硬编码；只按 env 设 gl4es 专用 LIBGL_* 并预 dlopen 渲染器。
 */
#include "napi/native_api.h"
#include "hilog/log.h"

#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <pthread.h>
#include <signal.h>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

#include <window_manager/oh_window.h>

#include "../meowcraftbridge/meowqos.h"

#include <arkui/native_interface.h>
#include <arkui/native_node.h>
#include <arkui/native_node_napi.h>
#include <arkui/ui_input_event.h>

#undef LOG_TAG
#define LOG_TAG "JreBridge"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0001

// Minimal JNI typedefs (no jni.h in OHOS NDK).
typedef int jint;
typedef unsigned char jboolean;
typedef unsigned int jsize;
#ifndef JNI_FALSE
#define JNI_FALSE 0
#endif
#ifndef JNI_TRUE
#define JNI_TRUE 1
#endif

namespace {

/* Dir of this .so (meowjre libs dir) — where the JRE .so live too. */
std::string SelfDir() {
    Dl_info info;
    if (dladdr(reinterpret_cast<void*>(&SelfDir), &info) != 0 && info.dli_fname != nullptr) {
        std::string p(info.dli_fname);
        size_t pos = p.find_last_of('/');
        if (pos != std::string::npos) {
            return p.substr(0, pos);
        }
    }
    return std::string();
}

/* Read a `KEY="value"` line from a JRE `release` file (empty if missing). */
std::string ReadReleaseValue(const std::string& releasePath, const std::string& key) {
    std::ifstream in(releasePath);
    if (!in) {
        return std::string();
    }
    const std::string prefix = key + "=";
    std::string line;
    while (std::getline(in, line)) {
        if (line.compare(0, prefix.size(), prefix) == 0) {
            std::string v = line.substr(prefix.size());
            if (v.size() >= 2 && v.front() == '"' && v.back() == '"') {
                v = v.substr(1, v.size() - 2);
            }
            return v;
        }
    }
    return std::string();
}

bool GetStringArray(napi_env env, napi_value arr, std::vector<std::string>& out) {
    bool isArray = false;
    napi_is_array(env, arr, &isArray);
    if (!isArray) {
        return false;
    }
    uint32_t len = 0;
    napi_get_array_length(env, arr, &len);
    out.reserve(len);
    for (uint32_t i = 0; i < len; ++i) {
        napi_value item = nullptr;
        napi_get_element(env, arr, i, &item);
        size_t n = 0;
        if (napi_get_value_string_utf8(env, item, nullptr, 0, &n) != napi_ok) {
            continue;
        }
        std::string buf(n + 1, '\0');
        size_t written = 0;
        if (napi_get_value_string_utf8(env, item, &buf[0], buf.size(), &written) == napi_ok) {
            out.emplace_back(buf, 0, written);
        }
    }
    return true;
}

/**
 * headless（NeoForge 安装期）JVM 的**跨进程结果通道**：把阶段标记/退出码追加到
 * <filesDir>/meow-neo-jvm-result.txt。现状 native 只有 hilog + _exit（主进程拿不到退出码），
 * 安装编排需要它来判断 processor 成败。仅 headless 模式写；游戏路径零影响。
 */
void WriteHeadlessResult(const std::string& filesDir, const std::string& line) {
    if (filesDir.empty()) {
        return;
    }
    FILE* f = fopen((filesDir + "/meow-neo-jvm-result.txt").c_str(), "a");
    if (f == nullptr) {
        return;
    }
    fprintf(f, "%s\n", line.c_str());
    fflush(f);
    fclose(f);
}

napi_value LaunchJvm(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return nullptr;
    }
    // filesDir：同样两段式（固定 buffer 会静默截断）。
    std::string filesDir;
    {
        size_t dirLen = 0;
        if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &dirLen) == napi_ok) {
            std::string dirBuf(dirLen + 1, '\0');
            size_t written = 0;
            if (napi_get_value_string_utf8(env, args[0], &dirBuf[0], dirBuf.size(), &written) == napi_ok) {
                filesDir.assign(dirBuf, 0, written);
            }
        }
    }
    std::vector<std::string> javaArgs;
    GetStringArray(env, args[1], javaArgs);
    if (javaArgs.empty()) {
        javaArgs.push_back("java");
    }
    // args[2]=jreHome（java.home 数据目录）, args[3]=jreLibsDir（JRE 运行时 el1 libs）。
    // 可选：缺省回退旧布局（filesDir/meow-jres/meow_jre + 本模块 SelfDir，仅兼容）。
    auto getStr = [&](napi_value v, std::string& out) {
        if (v == nullptr) {
            return;
        }
        // Two-pass (size first, then fetch): a fixed 1024B buffer SILENTLY TRUNCATED long
        // strings, which would eat user overrides appended at the end of the extra render
        // env (e.g. an explicit MEOW_GUARD_SYNC=flush rollback).
        size_t n = 0;
        if (napi_get_value_string_utf8(env, v, nullptr, 0, &n) != napi_ok) {
            return;
        }
        std::string buf(n + 1, '\0');
        size_t written = 0;
        if (napi_get_value_string_utf8(env, v, &buf[0], buf.size(), &written) == napi_ok) {
            out.assign(buf, 0, written);
        }
    };
    std::string jreHome;
    std::string jreLibs;
    if (argc >= 4) {
        getStr(args[2], jreHome);
        getStr(args[3], jreLibs);
    }
    // 渲染后端由 ArkTS 传入（单一事实源 LaunchDefaults.RENDERER_LIB/ENV），必须成对非空。
    std::string rendererSo;
    std::string rendererEnv;
    if (argc >= 6) {
        getStr(args[4], rendererSo);
        getStr(args[5], rendererEnv);
    }
    // 渲染器可**整段省略**：rendererSo 为空即「headless 模式」（由 NeoForge 安装编排驱动，通用能力）
    // （无窗口、无 surface、不需要 GL/Mesa 环境）。该模式下跳过渲染器预 dlopen、渲染相关 env 与
    // glthread 失效安全，并把 JVM 退出码落到 <filesDir>/meow-neo-jvm-result.txt（跨进程回报；现状只有 hilog）。
    const bool headless = rendererSo.empty();
    if (!headless && rendererEnv.empty()) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "launchJvm: renderer so=%{public}s but env empty, abort", rendererSo.c_str());
        return nullptr;
    }
    if (headless) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "launchJvm: headless mode (no renderer)");
    }
    // GL profile：ArkTS 按 MC 版本传（<1.17 → "compat" 固定管线；否则 "core"）。
    std::string glProfile = "core";
    if (argc >= 7) {
        getStr(args[6], glProfile);
    }
    if (glProfile.empty()) {
        glProfile = "core";
    }
    // 额外渲染 env（实验/调优）：ArkTS 传 "K=V"（换行或 ';' 分隔）；在 JLI 前、预 dlopen 渲染器前
    // setenv（Mesa 在 screen init 时读环境），可覆盖内置默认（GALLIUM_THREAD / ZINK_* / vblank_mode…）。
    std::string extraRenderEnv;
    if (argc >= 8) {
        getStr(args[7], extraRenderEnv);
    }

    // JLI_Launch 会阻塞到 JVM 退出，且内部可能 exit() 带走整个进程：
    // 必须在独立线程跑；任何局部 std::thread 都不能在 joinable 时析构
    // （否则 ~thread -> terminate -> SIGABRT）。全部用 detach 线程。
    std::thread([filesDir, javaArgs, jreHome, jreLibs, rendererSo, rendererEnv, glProfile,
                 extraRenderEnv, headless]() mutable {
        std::string libsDir = SelfDir(); // meowcraftlib libs（meowcraftbridge 等自研 so）
        // java.home（数据目录）与 JRE 运行时 el1 libs（libjli/libjvm…）由调用方指定，
        // 桥与 JRE 版本解耦。缺省回退旧布局（兼容）。
        std::string javaHome = jreHome.empty() ? filesDir + "/meow-jres/meow_jre" : jreHome;
        std::string jreLibsDir = jreLibs.empty() ? libsDir : jreLibs;
        std::string libPath = javaHome + "/lib";
        std::string ldPath = libsDir + ":" + jreLibsDir + ":" + libPath;
        setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
        // 版本横幅：区分新旧 HSP（确认 meowcraftlib 部署生效）。
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "JreBridge v3 (meowcraftlib) libsDir=%{public}s jreLibs=%{public}s",
                     libsDir.c_str(), jreLibsDir.c_str());
        // Huawei JLI: java.home is normally inferred from libjli.so's own path
        // (needs the standard <home>/lib/... layout). JRE .so 平铺在 JRE 模块 el1，
        // 推断失效 -> 用 OHOS_JAVA_HOME 显式覆盖。
        setenv("OHOS_JAVA_HOME", javaHome.c_str(), 1);
        // 让 JLI/VM 到 JRE 模块 el1 libs 目录 dlopen JVM 组件。
        setenv("OHOS_DL_DIR", jreLibsDir.c_str(), 1);

        // ---- 渲染环境（必须在 JLI 前设置）----
        // meowcraftbridge 读取这些变量选择渲染后端；缺失时 meowInitOpenGL
        // 会拿到空函数表并在 Render thread 上 NULL 调用崩溃（SIGSEGV@0xc）。
        // el2 cache 路径由 filesDir（.../files）同级推导为 .../cache。
        std::string cacheDir = filesDir;
        {
            std::string marker = "/files";
            size_t pos = cacheDir.rfind(marker);
            if (pos != std::string::npos) {
                cacheDir = cacheDir.substr(0, pos) + "/cache";
            }
        }
        setenv("HOME", filesDir.c_str(), 1);
        // 进程 CWD：能力进程的 CWD 通常是 "/"，而 MC（log4j 的 logs/latest.log、部分库）用**相对路径**。
        // 官方启动器/HMCL 都以「游戏运行目录」为 CWD ⇒ 这里按 argv 的 -Duser.dir=<gameDir> 切过去
        // （best-effort；失败仅告警）。headless（安装期）argv 无该参数 → 不动 CWD。
        {
            const std::string udPrefix = "-Duser.dir=";
            for (const auto& a : javaArgs) {
                if (a.compare(0, udPrefix.size(), udPrefix) == 0) {
                    const std::string ud = a.substr(udPrefix.size());
                    if (!ud.empty()) {
                        const bool cwdOk = (chdir(ud.c_str()) == 0);
                        OH_LOG_Print(LOG_APP, cwdOk ? LOG_INFO : LOG_WARN, LOG_DOMAIN, LOG_TAG,
                                     cwdOk ? "cwd -> %{public}s" : "chdir(%{public}s) failed",
                                     ud.c_str());
                    }
                    break;
                }
            }
        }
        // 渲染后端按 MC 版本选（ArkTS RendererPolicy）：桌面 GL(openglv4) 或 GLES+gl4es(gl4es)。
        // headless（安装期）不需要任何渲染 env：跳过，避免把 Mesa/GL 配置带进纯工具 JVM。
        if (!headless) {
            setenv("MEOWCRAFT_RENDERER", rendererEnv.c_str(), 1);
            setenv("MEOWCRAFT_GL_PROFILE", glProfile.c_str(), 1);
            setenv("MEOWCRAFT_NATIVEDIR", libsDir.c_str(), 1);
            setenv("NGG_DIR_PATH", (cacheDir + "/").c_str(), 1);
        }
        // gl4es 专用环境（仅 ≤1.16 后端消费；桌面 GL 路径忽略这些 LIBGL_*）：
        // ES2 后端、声称 GL 2.1（gl4es 能力上限，勿谎报 3.x）、规避已知驱动坑。
        if (!headless && rendererEnv == "gl4es") {
            setenv("LIBGL_GL", "21", 1);
            setenv("LIBGL_ES", "2", 1);
            setenv("LIBGL_NORMALIZE", "1", 1);
            setenv("LIBGL_NOINTOVLHACK", "1", 1);
            setenv("LIBGL_NOERROR", "0", 1);
            setenv("LIBGL_NOBANNER", "1", 1);
            setenv("LIBGL_SILENTSTUB", "1", 1);
        }
        setenv("ALSOFT_LOGLEVEL", "0", 1);
        // present 配置（A+B）：让 Mesa/Zink 走非 vsync present（vblank_mode=0 → interval 0
        // 映射 IMMEDIATE，否则 MAILBOX），并去掉 threaded-context 中转线程。
        // 必须在预 dlopen libGLv4 之前设置（Mesa 在 screen init 时读 env）。
        if (!headless) {
            setenv("vblank_mode", "0", 1);
        }
        // GALLIUM_THREAD 基值 = 0（**关**）。要用 glthread 由**上层**覆盖（高级选项「线程化渲染」
        // 默认开 → launcher 拼 `GALLIUM_THREAD=1`，仅现代路径）。本平台 glthread 会触发 Mesa
        // `tc_texture_subdata` 的 UAF，由随包 **GL guard**（libmeowglguard.so）对 `glTexSubImage2D`
        // 加后置同步兜底修复；**下方 pre-dlopen 后有失效安全**（guard 未武装则强制回 0）。
        // 详见 notes 20-design/glthread-B方案-GL-guard.md。
        if (!headless) {
            setenv("GALLIUM_THREAD", "0", 1);
        }
        // 额外渲染 env（实验/调优）：最后应用，覆盖以上默认；**必须在预 dlopen 渲染器之前**
        // （Mesa 在 screen init 时读 env）。格式 "K=V"，换行/';' 分隔，逐个 setenv。
        if (!extraRenderEnv.empty()) {
            std::string cur;
            for (size_t i = 0; i <= extraRenderEnv.size(); ++i) {
                char c = (i < extraRenderEnv.size()) ? extraRenderEnv[i] : '\n';
                if (c == '\n' || c == '\r' || c == ';') {
                    size_t eq = cur.find('=');
                    if (eq != std::string::npos && eq > 0) {
                        std::string k = cur.substr(0, eq);
                        std::string v = cur.substr(eq + 1);
                        // key 与 value 都去首尾空白（与注释一致；中间空白保留）。
                        while (!k.empty() && (k.back() == ' ' || k.back() == '\t')) k.pop_back();
                        while (!k.empty() && (k.front() == ' ' || k.front() == '\t')) k.erase(k.begin());
                        while (!v.empty() && (v.back() == ' ' || v.back() == '\t')) v.pop_back();
                        while (!v.empty() && (v.front() == ' ' || v.front() == '\t')) v.erase(v.begin());
                        if (!k.empty()) {
                            setenv(k.c_str(), v.c_str(), 1);
                            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                                         "extra render env: %{public}s=%{public}s", k.c_str(), v.c_str());
                        }
                    }
                    cur.clear();
                } else {
                    cur.push_back(c);
                }
            }
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "env set: MEOWCRAFT_RENDERER=%{public}s so=%{public}s NGG=%{public}s",
                     rendererEnv.c_str(), rendererSo.c_str(), (cacheDir + "/").c_str());

        // 线程调度（实验，env 驱动，均可降级）：在 JVM 起线程之前，对**启动线程**做
        // 绑核（MEOW_AFFINITY，如 "8-19"；JVM 线程/渲染线程继承该 mask）与 QoS
        // （MEOW_QOS=1）。失败/未配置只是 no-op，见 meowqos.c。
        meow_affinity_apply_current_thread();
        meow_qos_apply_current_thread();

        // ---- 预 dlopen 渲染器（历史件行为：dl_open 在 JVM 前）----
        // RTLD_GLOBAL 使 meowcraftbridge 随后能 dlsym 到渲染器的 GL/EGL 符号。
        // libGLv4 是系统库 → 按名；gl4es(libgl4es.so) 随包在模块 libs → 先按名、失败再按绝对路径。
        void* rlib = nullptr;
        if (!headless) {
            rlib = dlopen(rendererSo.c_str(), RTLD_NOW | RTLD_GLOBAL);
            if (rlib == nullptr && rendererSo.find('/') == std::string::npos) {
                std::string abs = libsDir + "/" + rendererSo;
                rlib = dlopen(abs.c_str(), RTLD_NOW | RTLD_GLOBAL);
            }
            if (rlib == nullptr) {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "pre-dlopen %{public}s failed: %{public}s", rendererSo.c_str(), dlerror());
            } else {
                OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                             "pre-dlopen %{public}s ok", rendererSo.c_str());
            }
        }

        // 失效安全：现代路径（openglv4）且 glthread 为开时，**只有"已武装的 GL guard"**才安全。
        // 若渲染器不是 guard（未加载 / 回滚 / 缺件），或 guard 报告未武装 → 强制 GALLIUM_THREAD=0，
        // 避免在无保护配置下复现 Mesa glthread 的 UAF。
        // （用户刻意 `MEOW_GUARD_SYNC=none` 做对照时 armed() 返回 1，不阻止。）
        if (rendererEnv == "openglv4") {
            const char* gt = getenv("GALLIUM_THREAD");
            bool glthreadOn = (gt != nullptr && gt[0] != '\0' && !(gt[0] == '0' && gt[1] == '\0'));
            int (*armed)(void) = nullptr;
            if (rlib != nullptr) {
                armed = reinterpret_cast<int (*)(void)>(dlsym(rlib, "meow_glguard_armed"));
            }
            if (glthreadOn && (armed == nullptr || armed() == 0)) {
                if (!headless) {
            setenv("GALLIUM_THREAD", "0", 1);
        }
                OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                             "glthread requested but GL guard not armed (so=%{public}s) -> forced GALLIUM_THREAD=0",
                             rendererSo.c_str());
            }
        }

        // JVM stdout/stderr 直接 pipe 到 hilog：不落盘。两个 reader 线程各阻塞
        // 读一个管道，把内容逐行上抛；JLI exit()/进程退出时管道关闭 read 返回 0，
        // 线程自退出（detach，无 joinable 析构）。
        int errPipe[2] = {-1, -1};
        int outPipe[2] = {-1, -1};
        if (pipe(errPipe) == 0 && pipe(outPipe) == 0) {
            // 重定向：JLI/JVM 写到 fd 1/2 的内容进管道。
            dup2(errPipe[1], STDERR_FILENO);
            dup2(outPipe[1], STDOUT_FILENO);
            close(errPipe[1]);
            close(outPipe[1]);
            // 行缓冲 reader：按 \n 切分逐行上抛，保证每行都带前缀；
            // 不完整行留到下次 read，避免"有的行有前缀有的没有"。
            // 两处健壮化（2026-09-16，实测踩到）：
            //   ① 清洗控制符：Java 侧若打印了含 NUL 的字符串（例：`MemoryUtil.memASCII(addr, len)`
            //      会连 NUL 终止符与其后的字节一起解出来），`%s` 会在 NUL 处**静默截断**——实测一行
            //      142 字符只剩 85、后面的内容整段丢失 ✗。这里把控制符换成空格，绝不吞后续内容。
            //   ② 按 hilog 的单条上限分段（平台文档 faqs-performance-analysis-kit-58：最多 4096 字节，
            //      超出截断）；取 1024 一块，给前缀留余量。
            auto sanitize = [](std::string s) {
                for (char& c : s) {
                    unsigned char u = static_cast<unsigned char>(c);
                    if (u < 0x20 && c != '\t') {
                        c = ' ';
                    }
                }
                return s;
            };
            const size_t kChunk = 1024;        // 远低于 hilog 的单条上限（4096 字节）
            const size_t kMaxPending = 65536;  // 无换行时的缓冲上界（见 pump 内的冲刷）
            auto emit = [sanitize](const char* tag, const std::string& raw) {
                std::string line = sanitize(raw);
                if (line.empty()) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "[%{public}s]", tag);
                    return;
                }
                for (size_t off = 0; off < line.size(); off += kChunk) {
                    std::string part = line.substr(off, kChunk);
                    if (off == 0) {
                        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                                     "[%{public}s] %{public}s", tag, part.c_str());
                    } else {
                        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                                     "[%{public}s] +%{public}d %{public}s", tag,
                                     static_cast<int>(off), part.c_str());
                    }
                }
            };
            auto pump = [emit](int fd, const char* tag) {
                std::string pending;
                char buf[2048] = {0};
                ssize_t n = 0;
                while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
                    pending.append(buf, static_cast<size_t>(n));
                    size_t pos = 0;
                    size_t nl = std::string::npos;
                    while ((nl = pending.find('\n', pos)) != std::string::npos) {
                        std::string line = pending.substr(pos, nl - pos);
                        if (!line.empty() && line.back() == '\r') {
                            line.pop_back();
                        }
                        emit(tag, line);
                        pos = nl + 1;
                    }
                    pending.erase(0, pos);  // 保留未换行的残段
                    // 有界化（2026-09-16 独立复核发现）：换行迟迟不来时 pending 会**无限增长** ✗ ——
                    // 一段无换行的巨量输出足以把游戏进程撑爆。超限就**带标记冲刷**并清空；
                    // 内容不丢，只是这条"行"被打断一次 ✓。
                    if (pending.size() > kMaxPending) {
                        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                                     "[%{public}s] (no newline within %{public}d bytes; flushing)",
                                     tag, static_cast<int>(kMaxPending));
                        emit(tag, pending);
                        pending.clear();
                    }
                }
                if (!pending.empty()) {
                    emit(tag, pending);
                }
                close(fd);
            };
            int errFd = errPipe[0];
            int outFd = outPipe[0];
            std::thread(pump, errFd, "jre_stderr").detach();
            std::thread(pump, outFd, "jre_stdout").detach();
        } else {
            // pipe 失败极罕见：退回 /dev/null 避免输出乱入 hilog。
            if (errPipe[0] >= 0) {
                close(errPipe[0]);
                close(errPipe[1]);
            }
            if (outPipe[0] >= 0) {
                close(outPipe[0]);
                close(outPipe[1]);
            }
            int devNull = open("/dev/null", O_WRONLY);
            if (devNull >= 0) {
                dup2(devNull, STDERR_FILENO);
                dup2(devNull, STDOUT_FILENO);
                close(devNull);
            }
        }

        std::string jliPath = jreLibsDir + "/libjli.so";
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "dlopen %{public}s",
                     jliPath.c_str());
        void* libjli = dlopen(jliPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (libjli == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "dlopen libjli failed: %{public}s", dlerror());
            return;
        }
        typedef jint (*JliLaunchFunc)(int, char**, int, const char**, int, const char**,
                                      const char*, const char*, const char*, const char*,
                                      jboolean, jboolean, jboolean, jint);
        auto* launch = reinterpret_cast<JliLaunchFunc>(dlsym(libjli, "JLI_Launch"));
        if (launch == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "dlsym JLI_Launch failed");
            return;
        }

        std::vector<char*> argv;
        for (auto& a : javaArgs) {
            argv.push_back(const_cast<char*>(a.c_str()));
        }
        argv.push_back(nullptr);

        // 启动前自检：argv 的 -Dorg.lwjgl.opengl.libname 必须与预 dlopen 目标一致，
        // 否则 LWJGL 从另一库取 GL 函数指针 → Render thread 崩溃。不一致直接中止启动。
        const std::string libFlag = "-Dorg.lwjgl.opengl.libname=";
        for (const auto& a : javaArgs) {
            if (a.compare(0, libFlag.size(), libFlag) == 0) {
                const std::string want = a.substr(libFlag.size());
                if (want != rendererSo) {
                    OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                                 "renderer mismatch: argv=%{public}s dlopen=%{public}s, abort",
                                 want.c_str(), rendererSo.c_str());
                    return;
                }
                break;
            }
        }

        // fullversion/dotversion 仅用于 `java -fullversion` / launcher debug dump
        // （dotversion 自 JDK9 起未使用）；从 JRE 自己的 release 文件取，避免硬编码。
        const std::string releaseFile = javaHome + "/release";
        std::string fullVersion = ReadReleaseValue(releaseFile, "JAVA_RUNTIME_VERSION");
        std::string dotVersion = ReadReleaseValue(releaseFile, "JAVA_VERSION");
        if (fullVersion.empty()) {
            fullVersion = "unknown";
        }
        if (dotVersion.empty()) {
            dotVersion = "unknown";
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "JLI_Launch begin (%{public}zu args) full=%{public}s dot=%{public}s",
                     javaArgs.size(), fullVersion.c_str(), dotVersion.c_str());
        if (headless) {
            WriteHeadlessResult(filesDir, "JLI_BEGIN args=" + std::to_string(javaArgs.size()));
        }
        jint code = launch(static_cast<int>(argv.size() - 1), argv.data(),
                           0, nullptr, 0, nullptr,
                           fullVersion.c_str(), dotVersion.c_str(), argv[0], argv[0],
                           JNI_FALSE, JNI_TRUE, JNI_FALSE, 0);
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "JLI_Launch returned %{public}d", code);
        if (headless) {
            WriteHeadlessResult(filesDir, "JLI_RETURNED code=" + std::to_string(static_cast<int>(code)));
        }
        // 老版本：JLI_Launch 跑完会内部 exit() 直接带走整个 :game 进程（窗口随之消失，
        // 启动器探测到进程结束）。26.2 起改为「正常返回」→ 若这里只关管道就返回，
        // :game 进程与游戏窗口会残留，启动器误判"仍在运行"。
        // 故显式结束本进程，与老版本行为对齐（:game 是游戏专用独立进程，主进程不受影响）。
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        // 给管道 reader 线程一点时间把尾巴日志上抛 hilog，再结束进程。
        usleep(200 * 1000);
        _exit(code == 0 ? 0 : code);
    }).detach();
    return nullptr;
}

// libmeowcraftbridge.so ships in the same meowjre libs dir. dlopen once,
// reused by setGameSurface / resizeGameSurface / requestGameWindowClose.
void* MeowCraftBridgeLib() {
    static void* sMeowCraftBridgeLib = nullptr;
    if (sMeowCraftBridgeLib == nullptr) {
        sMeowCraftBridgeLib = dlopen((SelfDir() + "/libmeowcraftbridge.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (sMeowCraftBridgeLib == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "dlopen libmeowcraftbridge.so failed: %{public}s", dlerror());
        } else {
            // Stage B：外部 bridge 已摘除。原由其 send_screen_size 触发的
            // critical_set_stackqueue(1)（输入走 ring+pump、由 pump 线程派发）
            // 改由 dlopen 时一次性开启，保持与旧运行时的 ring 语义一致。
            typedef void (*SetStackQueueFn)(int);
            auto* sf = reinterpret_cast<SetStackQueueFn>(
                dlsym(sMeowCraftBridgeLib, "critical_set_stackqueue"));
            if (sf != nullptr) {
                sf(1);
            } else {
                OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                             "dlsym critical_set_stackqueue failed");
            }
        }
    }
    return sMeowCraftBridgeLib;
}

napi_value SetGameSurface(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_value r = nullptr;
        napi_get_boolean(env, false, &r);
        return r;
    }
    int64_t sid = 0;
    int32_t w = 0;
    int32_t h = 0;
    napi_get_value_int64(env, args[0], &sid);
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);

    // 调自研 meowcraftbridge 的 meowSetSurfaceId：创建 OH_NativeWindow 并写回
    // meow_environ->window（env+0x000）。
    bool ok = false;
    void* sMeowCraftBridgeLib = MeowCraftBridgeLib();
    if (sMeowCraftBridgeLib != nullptr) {
        typedef int (*SetSurfaceFn)(int64_t, int, int);
        auto* fn = reinterpret_cast<SetSurfaceFn>(dlsym(sMeowCraftBridgeLib, "meowSetSurfaceId"));
        if (fn != nullptr) {
            ok = fn(sid, w, h) == 0;
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "setGameSurface sid=%{public}lld %{public}dx%{public}d -> %{public}d",
                         static_cast<long long>(sid), w, h, ok ? 1 : 0);
        } else {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "setGameSurface: dlsym meowSetSurfaceId failed");
        }
    }
    napi_value r = nullptr;
    napi_get_boolean(env, ok, &r);
    return r;
}

// Resize: same-sid -> meowResizeSurface only marks env size (UI thread writes
// env only, never touches EGL/NativeWindow); sid change falls through to the
// full window-create path inside meowResizeSurface.
napi_value ResizeGameSurface(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_value r = nullptr;
        napi_get_boolean(env, false, &r);
        return r;
    }
    int64_t sid = 0;
    int32_t w = 0;
    int32_t h = 0;
    napi_get_value_int64(env, args[0], &sid);
    napi_get_value_int32(env, args[1], &w);
    napi_get_value_int32(env, args[2], &h);

    bool ok = false;
    void* sMeowCraftBridgeLib = MeowCraftBridgeLib();
    if (sMeowCraftBridgeLib != nullptr) {
        typedef int (*ResizeFn)(int64_t, int, int);
        auto* fn = reinterpret_cast<ResizeFn>(dlsym(sMeowCraftBridgeLib, "meowResizeSurface"));
        if (fn != nullptr) {
            ok = fn(sid, w, h) == 0;
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "resizeGameSurface sid=%{public}lld %{public}dx%{public}d -> %{public}d",
                         static_cast<long long>(sid), w, h, ok ? 1 : 0);
        } else {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "resizeGameSurface: dlsym meowResizeSurface failed");
        }
    }
    napi_value r = nullptr;
    napi_get_boolean(env, ok, &r);
    return r;
}

// Close: ask our libmeowcraftbridge to flip GLFW shouldClose so MC exits gracefully.
napi_value RequestGameWindowClose(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    bool ok = false;
    void* sMeowCraftBridgeLib = MeowCraftBridgeLib();
    if (sMeowCraftBridgeLib != nullptr) {
        typedef int (*CloseFn)(void);
        auto* fn = reinterpret_cast<CloseFn>(dlsym(sMeowCraftBridgeLib, "meowGlfwRequestClose"));
        if (fn != nullptr) {
            ok = fn() != 0;
            OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                         "requestGameWindowClose -> %{public}d", ok ? 1 : 0);
        } else {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "requestGameWindowClose: dlsym meowGlfwRequestClose failed");
        }
    }
    napi_value r = nullptr;
    napi_get_boolean(env, ok, &r);
    return r;
}

// ---- input forwarding: self libmeowcraftbridge critical_send_* + cursor lock ----
// critical_send_* real signatures (meowcraftbridge/input_bridge.c):
//   int  critical_send_char(int) / int critical_send_char_mods(int,int)
//   void critical_send_cursor_pos(float,float) / critical_send_key(int,int,int,int)
//   void critical_send_mouse_button(int,int,int) / critical_send_scroll(double,double)
//   int  meowGetGrabbing(void)
typedef int (*MeowCharFn)(int codepoint);
typedef int (*MeowCharModsFn)(int codepoint, int mods);
typedef void (*MeowCursorPosFn)(float x, float y);
typedef void (*MeowKeyFn)(int key, int scancode, int action, int mods);
typedef void (*MeowMouseButtonFn)(int button, int action, int mods);
typedef void (*MeowScrollFn)(double xoffset, double yoffset);
typedef int (*MeowGetGrabbingFn)(void);

struct MeowSenders {
    MeowCharModsFn charMods;
    MeowCharFn ch;
    MeowCursorPosFn cursorPos;
    MeowKeyFn key;
    MeowMouseButtonFn mouseButton;
    MeowScrollFn scroll;
    MeowGetGrabbingFn getGrabbing;
    bool resolved;
};

static MeowSenders gSenders = {nullptr, nullptr, nullptr, nullptr,
                               nullptr, nullptr, nullptr, false};

static void ResolveSenders() {
    if (gSenders.resolved) {
        return;
    }
    void* lib = MeowCraftBridgeLib();
    if (lib == nullptr) {
        return; /* meowcraftbridge not loaded yet; retry on the next call */
    }
    gSenders.charMods = reinterpret_cast<MeowCharModsFn>(dlsym(lib, "critical_send_char_mods"));
    gSenders.ch = reinterpret_cast<MeowCharFn>(dlsym(lib, "critical_send_char"));
    gSenders.cursorPos = reinterpret_cast<MeowCursorPosFn>(dlsym(lib, "critical_send_cursor_pos"));
    gSenders.key = reinterpret_cast<MeowKeyFn>(dlsym(lib, "critical_send_key"));
    gSenders.mouseButton = reinterpret_cast<MeowMouseButtonFn>(dlsym(lib, "critical_send_mouse_button"));
    gSenders.scroll = reinterpret_cast<MeowScrollFn>(dlsym(lib, "critical_send_scroll"));
    gSenders.getGrabbing = reinterpret_cast<MeowGetGrabbingFn>(dlsym(lib, "meowGetGrabbing"));
    gSenders.resolved = true;
    if (gSenders.charMods == nullptr || gSenders.ch == nullptr || gSenders.cursorPos == nullptr ||
        gSenders.key == nullptr || gSenders.mouseButton == nullptr || gSenders.scroll == nullptr ||
        gSenders.getGrabbing == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "input senders: some dlsym failed charMods=%{public}p ch=%{public}p "
                     "cursor=%{public}p key=%{public}p mouse=%{public}p scroll=%{public}p "
                     "grab=%{public}p",
                     reinterpret_cast<void*>(gSenders.charMods), reinterpret_cast<void*>(gSenders.ch),
                     reinterpret_cast<void*>(gSenders.cursorPos), reinterpret_cast<void*>(gSenders.key),
                     reinterpret_cast<void*>(gSenders.mouseButton), reinterpret_cast<void*>(gSenders.scroll),
                     reinterpret_cast<void*>(gSenders.getGrabbing));
    }
}

static napi_value MkBool(napi_env env, bool value) {
    napi_value r = nullptr;
    napi_get_boolean(env, value, &r);
    return r;
}

static napi_value MkInt32(napi_env env, int32_t value) {
    napi_value r = nullptr;
    napi_create_int32(env, value, &r);
    return r;
}

static napi_value MeowSendKey(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        return MkBool(env, false);
    }
    int32_t key = 0;
    int32_t scancode = 0;
    int32_t action = 0;
    int32_t mods = 0;
    if (napi_get_value_int32(env, args[0], &key) != napi_ok ||
        napi_get_value_int32(env, args[1], &scancode) != napi_ok ||
        napi_get_value_int32(env, args[2], &action) != napi_ok ||
        napi_get_value_int32(env, args[3], &mods) != napi_ok) {
        return MkBool(env, false);
    }
    ResolveSenders();
    if (gSenders.key == nullptr) {
        return MkBool(env, false);
    }
    gSenders.key(key, scancode, action, mods);
    if (action == 1) { /* press: debug level, don't spam on move/axis */
        OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, "meowSendKey k=%{public}d a=%{public}d",
                     key, action);
    }
    return MkBool(env, true);
}

static napi_value MeowSendMouseButton(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MkBool(env, false);
    }
    int32_t button = 0;
    int32_t action = 0;
    int32_t mods = 0;
    if (napi_get_value_int32(env, args[0], &button) != napi_ok ||
        napi_get_value_int32(env, args[1], &action) != napi_ok ||
        napi_get_value_int32(env, args[2], &mods) != napi_ok) {
        return MkBool(env, false);
    }
    ResolveSenders();
    if (gSenders.mouseButton == nullptr) {
        return MkBool(env, false);
    }
    gSenders.mouseButton(button, action, mods);
    return MkBool(env, true);
}

static napi_value MeowSendCursorPos(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MkBool(env, false);
    }
    double x = 0.0;
    double y = 0.0;
    if (napi_get_value_double(env, args[0], &x) != napi_ok ||
        napi_get_value_double(env, args[1], &y) != napi_ok) {
        return MkBool(env, false);
    }
    ResolveSenders();
    if (gSenders.cursorPos == nullptr) {
        return MkBool(env, false);
    }
    gSenders.cursorPos(static_cast<float>(x), static_cast<float>(y));
    return MkBool(env, true);
}

static napi_value MeowSendScroll(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MkBool(env, false);
    }
    double x = 0.0;
    double y = 0.0;
    if (napi_get_value_double(env, args[0], &x) != napi_ok ||
        napi_get_value_double(env, args[1], &y) != napi_ok) {
        return MkBool(env, false);
    }
    ResolveSenders();
    if (gSenders.scroll == nullptr) {
        return MkBool(env, false);
    }
    gSenders.scroll(x, y);
    return MkBool(env, true);
}

static napi_value MeowSendChar(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MkBool(env, false);
    }
    int32_t codepoint = 0;
    int32_t mods = 0;
    if (napi_get_value_int32(env, args[0], &codepoint) != napi_ok ||
        napi_get_value_int32(env, args[1], &mods) != napi_ok) {
        return MkBool(env, false);
    }
    ResolveSenders();
    if (gSenders.charMods == nullptr || gSenders.ch == nullptr) {
        return MkBool(env, false);
    }
    /* order matters: LWJGL char callback needs the mods variant first */
    gSenders.charMods(codepoint, mods);
    gSenders.ch(codepoint);
    OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, "char cp=%{public}d", codepoint);
    return MkBool(env, true);
}

static napi_value MeowGetGrabbing(napi_env env, napi_callback_info info) {
    (void)info;
    ResolveSenders();
    if (gSenders.getGrabbing == nullptr) {
        return MkInt32(env, 0);
    }
    return MkInt32(env, gSenders.getGrabbing());
}

static napi_value LockCursor(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MkInt32(env, -1);
    }
    int32_t windowId = 0;
    bool follow = false;
    if (napi_get_value_int32(env, args[0], &windowId) != napi_ok ||
        napi_get_value_bool(env, args[1], &follow) != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "lockCursor: bad args (need int windowId + boolean follow)");
        return MkInt32(env, -1);
    }
    int32_t rc = OH_WindowManager_LockCursor(windowId, follow);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "lockCursor windowId=%{public}d rc=%{public}d",
                 windowId, rc);
    return MkInt32(env, rc);
}

static napi_value UnlockCursor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MkInt32(env, -1);
    }
    int32_t windowId = 0;
    if (napi_get_value_int32(env, args[0], &windowId) != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "unlockCursor: bad arg");
        return MkInt32(env, -1);
    }
    int32_t rc = OH_WindowManager_UnlockCursor(windowId);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "unlockCursor windowId=%{public}d rc=%{public}d",
                 windowId, rc);
    return MkInt32(env, rc);
}

// 参数：windowId, ox(组件左上角 display px), oy, scale(渲染缩放 S)。
// 本端 local = (displayPx - origin) / S；S=1 时退化为 local = displayPx - origin。
static napi_value MouseFilterStart(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MkInt32(env, -1);
    }
    int32_t windowId = 0;
    double ox = 0, oy = 0, scale = 1.0;
    napi_get_value_int32(env, args[0], &windowId);
    napi_get_value_double(env, args[1], &ox);
    napi_get_value_double(env, args[2], &oy);
    if (argc >= 4) {
        napi_get_value_double(env, args[3], &scale);
    }
    if (!(scale > 0.0)) {
        scale = 1.0;
    }
    int rc = -1;
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        typedef int (*Fn)(int32_t, double, double, double);
        auto* fn = reinterpret_cast<Fn>(dlsym(lib, "meowMouseFilterStart"));
        if (fn != nullptr) {
            rc = fn(windowId, ox, oy, scale);
        }
    }
    if (rc != 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "mouseFilterStart(win=%{public}d ox=%{public}f oy=%{public}f scale=%{public}f) -> %{public}d",
                     windowId, ox, oy, scale, rc);
    }
    return MkInt32(env, rc);
}

static napi_value MouseFilterStop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t windowId = 0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &windowId);
    }
    int rc = -1;
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        typedef int (*Fn)(int32_t);
        auto* fn = reinterpret_cast<Fn>(dlsym(lib, "meowMouseFilterStop"));
        if (fn != nullptr) {
            rc = fn(windowId);
        }
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "mouseFilterStop(win=%{public}d) -> %{public}d", windowId, rc);
    return MkInt32(env, rc);
}

/* ===== 原生鼠标增量输入（NDK 覆盖节点）=====
 * ArkTS 侧放 ContentSlot(NodeContent)；native 用 createNode(ARKUI_NODE_STACK) 建节点，
 * 100% 尺寸 + HitTestMode.Transparent（自己响应且不挡下层 XComponent），注册 NODE_ON_MOUSE。
 * grab 时把 rawDelta 交给 libmeowcraftbridge 的 meowGrabDelta（采样率 = 显示帧率，
 * 与窗口/FPS 无关）；非 grab 由窗口 filter + ArkTS 绝对坐标负责。 */
static ArkUI_NativeNodeAPI_1* g_nodeApi = nullptr;
static void (*g_grabDeltaFn)(float, float) = nullptr;
static ArkUI_NodeContentHandle g_boundContent = nullptr;

static void MeowNodeEventReceiver(ArkUI_NodeEvent* event) {
    if (event == nullptr) {
        return;
    }
    ArkUI_UIInputEvent* ev = OH_ArkUI_NodeEvent_GetInputEvent(event);
    if (ev == nullptr || OH_ArkUI_UIInputEvent_GetType(ev) != ARKUI_UIINPUTEVENT_TYPE_MOUSE) {
        return;
    }
    float dx = OH_ArkUI_MouseEvent_GetRawDeltaX(ev);
    float dy = OH_ArkUI_MouseEvent_GetRawDeltaY(ev);
    if (dx == 0.0f && dy == 0.0f) {
        return;
    }
    if (g_grabDeltaFn == nullptr) {
        void* lib = MeowCraftBridgeLib();
        if (lib != nullptr) {
            g_grabDeltaFn = reinterpret_cast<void (*)(float, float)>(dlsym(lib, "meowGrabDelta"));
        }
    }
    if (g_grabDeltaFn != nullptr) {
        g_grabDeltaFn(dx, dy); /* lib 内部仅在 env->grabbing 时累加并下发 */
    }
}

// 建常驻覆盖节点并挂到 ContentSlot；sens=抓取灵敏度（与 ArkTS CURSOR_SENS 一致）。
napi_value BindNodeContent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MkInt32(env, -1);
    }
    ArkUI_NodeContentHandle content = nullptr;
    int32_t rc = OH_ArkUI_GetNodeContentFromNapiValue(env, args[0], &content);
    if (rc != 0 || content == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "bindNodeContent: GetNodeContentFromNapiValue rc=%{public}d", (int)rc);
        return MkInt32(env, -1);
    }
    if (content == g_boundContent) {
        return MkInt32(env, 0); /* 同一 ContentSlot 已挂载，勿重复建节点/注册接收器 */
    }
    if (g_nodeApi == nullptr) {
        OH_ArkUI_GetModuleInterface(ARKUI_NATIVE_NODE, ArkUI_NativeNodeAPI_1, g_nodeApi);
    }
    if (g_nodeApi == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "bindNodeContent: node API null");
        return MkInt32(env, -1);
    }
    double sens = 1.0;
    if (argc >= 2) {
        napi_get_value_double(env, args[1], &sens);
    }
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        auto setSens = reinterpret_cast<void (*)(float)>(dlsym(lib, "meowGrabSetSens"));
        if (setSens != nullptr) {
            setSens((float)sens);
        }
    }
    ArkUI_NodeHandle node = g_nodeApi->createNode(ARKUI_NODE_STACK);
    if (node == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "bindNodeContent: createNode null");
        return MkInt32(env, -1);
    }
    ArkUI_NumberValue w;
    w.f32 = 100.0f;
    ArkUI_AttributeItem wi = {&w, 1, nullptr, nullptr};
    g_nodeApi->setAttribute(node, NODE_WIDTH_PERCENT, &wi);
    ArkUI_NumberValue h;
    h.f32 = 100.0f;
    ArkUI_AttributeItem hi = {&h, 1, nullptr, nullptr};
    g_nodeApi->setAttribute(node, NODE_HEIGHT_PERCENT, &hi);
    ArkUI_NumberValue ht;
    ht.i32 = ARKUI_HIT_TEST_MODE_TRANSPARENT;
    ArkUI_AttributeItem hti = {&ht, 1, nullptr, nullptr};
    g_nodeApi->setAttribute(node, NODE_HIT_TEST_BEHAVIOR, &hti);

    int32_t a = g_nodeApi->addNodeEventReceiver(node, MeowNodeEventReceiver);
    int32_t b = g_nodeApi->registerNodeEvent(node, NODE_ON_MOUSE, 0, nullptr);
    int32_t d = OH_ArkUI_NodeContent_AddNode(content, node);
    if (d == 0) {
        g_boundContent = content;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "bindNodeContent node=%{public}p add=%{public}d mouse=%{public}d "
                 "contentAdd=%{public}d sens=%{public}f",
                 (void*)node, (int)a, (int)b, (int)d, sens);
    return MkInt32(env, (a == 0 && b == 0 && d == 0) ? 0 : -1);
}

// 进入 grab：重置原生虚拟光标到中心并下发一次。
napi_value MeowGrabReset(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MkInt32(env, -1);
    }
    double cx = 0.0;
    double cy = 0.0;
    napi_get_value_double(env, args[0], &cx);
    napi_get_value_double(env, args[1], &cy);
    int rc = -1;
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        auto fn = reinterpret_cast<void (*)(float, float)>(dlsym(lib, "meowGrabReset"));
        if (fn != nullptr) {
            fn((float)cx, (float)cy);
            rc = 0;
        }
    }
    return MkInt32(env, rc);
}

// 当前有效鼠标采样率（次/秒），供左下角 overlay 显示。
napi_value MeowGetInputRate(napi_env env, napi_callback_info info) {
    (void)info;
    int rate = 0;
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        auto fn = reinterpret_cast<int (*)(void)>(dlsym(lib, "meowRateGet"));
        if (fn != nullptr) {
            rate = fn();
        }
    }
    return MkInt32(env, rate);
}

napi_value TakeFullscreenRequest(napi_env env, napi_callback_info info) {
    (void)info;
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
    int request = 0;
    void* lib = MeowCraftBridgeLib();
    if (lib != nullptr) {
        auto fn = reinterpret_cast<int (*)(int*, int*, int*, int*)>(
            dlsym(lib, "meowTakeFullscreenRequest"));
        if (fn != nullptr) {
            request = fn(&x, &y, &w, &h);
        }
    }
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    napi_value v = nullptr;
    napi_create_int32(env, request, &v);
    napi_set_named_property(env, obj, "request", v);
    napi_create_int32(env, x, &v);
    napi_set_named_property(env, obj, "x", v);
    napi_create_int32(env, y, &v);
    napi_set_named_property(env, obj, "y", v);
    napi_create_int32(env, w, &v);
    napi_set_named_property(env, obj, "w", v);
    napi_create_int32(env, h, &v);
    napi_set_named_property(env, obj, "h", v);
    return obj;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {        {"launchJvm", nullptr, LaunchJvm, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGameSurface", nullptr, SetGameSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resizeGameSurface", nullptr, ResizeGameSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestGameWindowClose", nullptr, RequestGameWindowClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowSendKey", nullptr, MeowSendKey, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowSendMouseButton", nullptr, MeowSendMouseButton, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowSendCursorPos", nullptr, MeowSendCursorPos, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowSendScroll", nullptr, MeowSendScroll, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowSendChar", nullptr, MeowSendChar, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"meowGetGrabbing", nullptr, MeowGetGrabbing, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lockCursor", nullptr, LockCursor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unlockCursor", nullptr, UnlockCursor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"mouseFilterStart", nullptr, MouseFilterStart, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"mouseFilterStop", nullptr, MouseFilterStop, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"bindNodeContent", nullptr, BindNodeContent, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"meowGrabReset", nullptr, MeowGrabReset, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"meowGetInputRate", nullptr, MeowGetInputRate, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"takeFullscreenRequest", nullptr, TakeFullscreenRequest, nullptr, nullptr, nullptr,
         napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "meowjrebridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule() {
    napi_module_register(&g_module);
}
