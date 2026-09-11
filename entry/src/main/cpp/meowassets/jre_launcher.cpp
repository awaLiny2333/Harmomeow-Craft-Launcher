/*
 * Meowcraft JRE 数据工具实现（Install / ExtractRawTar）。
 * 历史代码 LaunchJava（entry 直启链）与 ProbeFilesDirExec（dlopen 探针）
 * 已移除：JVM 启动统一走 jrelib HSP 的 libmeowjrebridge.so。
 */
#include "jre_launcher.h"

#include <zlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <vector>

#include "hilog/log.h"
#include "rawfile/raw_file.h"
#include "rawfile/raw_file_manager.h"

#undef LOG_TAG
#define LOG_TAG "MeowcraftJre"
#undef LOG_DOMAIN
#define LOG_DOMAIN 0x0001

namespace jre {

namespace {

bool WriteFile(const std::string& path, const char* data, size_t size) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        return false;
    }
    out.write(data, static_cast<std::streamsize>(size));
    return out.good();
}

bool ReadRawAsset(void* mgrVoid, const std::string& assetName, std::string& out) {
    auto* mgr = static_cast<NativeResourceManager*>(mgrVoid);
    RawFile* f = OH_ResourceManager_OpenRawFile(mgr, assetName.c_str());
    if (f == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "OpenRawFile failed: %{public}s", assetName.c_str());
        return false;
    }
    long size = OH_ResourceManager_GetRawFileSize(f);
    if (size <= 0) {
        OH_ResourceManager_CloseRawFile(f);
        return false;
    }
    out.resize(static_cast<size_t>(size));
    long got = OH_ResourceManager_ReadRawFile(f, &out[0], static_cast<size_t>(size));
    OH_ResourceManager_CloseRawFile(f);
    return got == size;
}

bool Gunzip(const std::string& src, std::string& dst) {
    z_stream zs;
    std::memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 15 + 32) != Z_OK) {
        return false;
    }
    dst.clear();
    std::vector<char> inBuf(64 * 1024);
    std::vector<char> outBuf(256 * 1024);
    size_t srcPos = 0;
    int ret = Z_OK;
    do {
        if (zs.avail_in == 0 && srcPos < src.size()) {
            size_t n = std::min(inBuf.size(), src.size() - srcPos);
            std::memcpy(inBuf.data(), src.data() + srcPos, n);
            srcPos += n;
            zs.next_in = reinterpret_cast<Bytef*>(inBuf.data());
            zs.avail_in = static_cast<uInt>(n);
        }
        zs.next_out = reinterpret_cast<Bytef*>(outBuf.data());
        zs.avail_out = static_cast<uInt>(outBuf.size());
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) {
            inflateEnd(&zs);
            return false;
        }
        size_t produced = outBuf.size() - zs.avail_out;
        dst.append(outBuf.data(), produced);
    } while (ret != Z_STREAM_END);
    inflateEnd(&zs);
    return true;
}

unsigned long ParseOctal(const char* p, size_t len) {
    unsigned long v = 0;
    for (size_t i = 0; i < len; ++i) {
        if (p[i] >= '0' && p[i] <= '7') {
            v = v * 8 + static_cast<unsigned long>(p[i] - '0');
        } else if (p[i] == ' ' || p[i] == '\0') {
            break;
        }
    }
    return v;
}

bool MakeDirs(const std::string& path) {
    std::string cur;
    for (size_t i = 0; i < path.size(); ++i) {
        cur.push_back(path[i]);
        if (path[i] == '/') {
            if (cur.size() > 1) {
                mkdir(cur.c_str(), 0755);
            }
        }
    }
    if (cur.size() > 0) {
        mkdir(cur.c_str(), 0755);
    }
    return true;
}

std::string DirName(const std::string& path) {
    size_t pos = path.find_last_of('/');
    if (pos == std::string::npos) {
        return ".";
    }
    return path.substr(0, pos);
}

/* Untar pure regular files (no symlinks in our asset). */
bool Untar(const std::string& tarData, const std::string& destDir) {
    const size_t BLOCK = 512;
    size_t pos = 0;
    size_t total = tarData.size();
    while (pos + BLOCK <= total) {
        const char* hdr = tarData.data() + pos;
        bool allZero = true;
        for (size_t i = 0; i < BLOCK; ++i) {
            if (hdr[i] != 0) {
                allZero = false;
                break;
            }
        }
        if (allZero) {
            break;
        }
        std::string name(hdr, 100);
        name = name.c_str();
        char type = hdr[156];
        unsigned long size = ParseOctal(hdr + 124, 12);
        pos += BLOCK;
        if (name.rfind("./", 0) == 0) {
            name = name.substr(2);
        }
        std::string full = destDir + "/" + name;
        if (type == '5') {
            mkdir(full.c_str(), 0755);
        } else if (type == '\0' || type == '0') {
            MakeDirs(DirName(full));
            if (pos + size <= total) {
                WriteFile(full, tarData.data() + pos, size);
            }
        }
        pos += (size + BLOCK - 1) / BLOCK * BLOCK;
        if (pos > total) {
            break;
        }
    }
    return true;
}

} // namespace

bool Install(void* resourceMgr, const std::string& filesDir, const std::string& jreId) {
    if (jreId.empty()) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Install: empty jreId");
        return false;
    }
    const std::string assetName = jreId + ".tar.gz";
    std::string installRoot = filesDir + "/" + kJresRoot + "/" + jreId;
    // 就绪标记 = 数据镜像关键件 lib/modules（JRE 可执行 .so 只在 el1，不入数据，故不能以 libjli.so 判定）。
    std::string doneMarker = installRoot + "/lib/modules";
    if (access(doneMarker.c_str(), F_OK) == 0) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "JRE already installed at %{public}s", installRoot.c_str());
        return true;
    }

    std::string gz;
    if (!ReadRawAsset(resourceMgr, assetName, gz)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "Failed to read raw asset %{public}s", assetName.c_str());
        return false;
    }
    std::string tar;
    if (!Gunzip(gz, tar)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "gunzip failed");
        return false;
    }
    MakeDirs(installRoot);
    if (!Untar(tar, installRoot)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "untar failed");
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "JRE installed (%{public}zu bytes uncompressed)", tar.size());
    return true;
}

bool ExtractRawTar(void* resourceMgr, const std::string& assetName,
                   const std::string& destDir) {
    std::string gz;
    if (!ReadRawAsset(resourceMgr, assetName, gz)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "ExtractRawTar: asset %{public}s not found", assetName.c_str());
        return false;
    }
    std::string tar;
    if (!Gunzip(gz, tar)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "ExtractRawTar: gunzip failed");
        return false;
    }
    mkdir(destDir.c_str(), 0755);
    if (!Untar(tar, destDir)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "ExtractRawTar: untar failed");
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                 "ExtractRawTar %{public}s -> %{public}s ok", assetName.c_str(),
                 destDir.c_str());
    return true;
}

} // namespace jre
