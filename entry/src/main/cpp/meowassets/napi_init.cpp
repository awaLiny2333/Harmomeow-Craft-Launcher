/*
 * Meowcraft native NAPI entry.
 *
 * Exposes to ArkTS:
 *   installJre(resourceManager: object, filesDir: string): boolean
 *   extractRawTar(resourceManager: object, assetName: string, destDir: string): boolean
 *
 * 本 so 只承载 JRE 数据安装与 rawfile tar 解压工具。
 * JVM 启动与游戏渲染由 meowjre25 HSP（meowcraftlib 并入的桥）负责。
 * 入口侧早期为 GL 预览 / 直启 JVM / dlopen 探针写的导出均已清理（无调用方）。
 */
#include "napi/native_api.h"
#include "hilog/log.h"
#include "rawfile/raw_file_manager.h"

#include <string>
#include <unistd.h>

#include "jre_launcher.h"

#undef LOG_TAG
#define LOG_TAG "MeowcraftNapi"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0001

namespace {

/* ---- JRE install ---- */

napi_value InstallJre(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    NativeResourceManager* mgr = OH_ResourceManager_InitNativeResourceManager(env, args[0]);
    if (mgr == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "init resource manager failed");
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    char dirBuf[512] = {0};
    size_t dirLen = 0;
    napi_get_value_string_utf8(env, args[1], dirBuf, sizeof(dirBuf), &dirLen);
    std::string filesDir(dirBuf, dirLen);
    char idBuf[128] = {0};
    size_t idLen = 0;
    napi_get_value_string_utf8(env, args[2], idBuf, sizeof(idBuf), &idLen);
    std::string jreId(idBuf, idLen);

    bool ok = jre::Install(mgr, filesDir, jreId);
    OH_ResourceManager_ReleaseNativeResourceManager(mgr);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "installJre -> %{public}d",
                 ok ? 1 : 0);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

/* 从 rawfile 解 tar.gz 到指定目录（用于 staging 启动支持 jar，如 lwjgl 桥）。
 * @param resourceManager context.resourceManager（args[0]）。
 * @param assetName rawfile 内文件名（args[1]）。
 * @param destDir 沙箱目标目录（args[2]）。 */
napi_value ExtractRawTar(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_value r = nullptr;
        napi_get_boolean(env, false, &r);
        return r;
    }
    NativeResourceManager* mgr = OH_ResourceManager_InitNativeResourceManager(env, args[0]);
    if (mgr == nullptr) {
        napi_value r = nullptr;
        napi_get_boolean(env, false, &r);
        return r;
    }
    char assetBuf[256] = {0};
    size_t assetLen = 0;
    napi_get_value_string_utf8(env, args[1], assetBuf, sizeof(assetBuf), &assetLen);
    std::string asset(assetBuf, assetLen);
    char dirBuf[512] = {0};
    size_t dirLen = 0;
    napi_get_value_string_utf8(env, args[2], dirBuf, sizeof(dirBuf), &dirLen);
    std::string destDir(dirBuf, dirLen);

    bool ok = jre::ExtractRawTar(mgr, asset, destDir);
    OH_ResourceManager_ReleaseNativeResourceManager(mgr);
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "extractRawTar %{public}s -> %{public}s : %{public}s",
                 asset.c_str(), destDir.c_str(), ok ? "ok" : "fail");
    napi_value r = nullptr;
    napi_get_boolean(env, ok, &r);
    return r;
}

/* 本机在线 CPU 核数（ArkTS 无公开 API，用 sysconf 探测；供高级选项显示/手动参考）。 */
napi_value GetCpuCount(napi_env env, napi_callback_info info) {
    (void)info;
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) {
        n = 1;
    }
    napi_value r = nullptr;
    napi_create_int32(env, static_cast<int32_t>(n), &r);
    return r;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"installJre", nullptr, InstallJre, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"extractRawTar", nullptr, ExtractRawTar, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCpuCount", nullptr, GetCpuCount, nullptr, nullptr, nullptr, napi_default, nullptr},
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
    .nm_modname = "meowassets",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterModule() {
    napi_module_register(&g_module);
}
