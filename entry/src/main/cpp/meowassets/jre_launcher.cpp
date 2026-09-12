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
#include <dirent.h>
#include <fstream>
#include <iterator>
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

std::string ReadTextFile(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return std::string();
    }
    std::string s((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) {
        s.pop_back();
    }
    return s;
}

/* 递归删除（不依赖 <filesystem>：OHOS libc++ 的 filesystem 在 std::__fs）。 */
bool RemoveAll(const std::string& path) {
    struct stat st;
    if (lstat(path.c_str(), &st) != 0) {
        return true;
    }
    if (!S_ISDIR(st.st_mode)) {
        return unlink(path.c_str()) == 0;
    }
    DIR* d = opendir(path.c_str());
    if (d != nullptr) {
        struct dirent* e;
        while ((e = readdir(d)) != nullptr) {
            std::string n = e->d_name;
            if (n == "." || n == "..") {
                continue;
            }
            RemoveAll(path + "/" + n);
        }
        closedir(d);
    }
    return rmdir(path.c_str()) == 0;
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
    // 就绪 = 数据关键件 lib/modules 存在（.so 只在 el1，不入数据，不能以 libjli.so 判定）
    //       且 数据令牌一致（否则 in-place 更新会「新 el1 .so + 旧数据」混合）。
    std::string doneMarker = installRoot + "/lib/modules";
    std::string tokenPath = installRoot + "/" + kJreDataTokenFile;
    if (access(doneMarker.c_str(), F_OK) == 0 &&
        ReadTextFile(tokenPath) == std::string(kJreDataToken)) {
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "JRE already installed at %{public}s", installRoot.c_str());
        return true;
    }
    // 先读+解压到内存，成功后再清旧数据（避免 asset/gunzip 失败却已销毁旧数据）。
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
    // 令牌不符 / 缺件 → 清掉旧数据再重解压（避免残留旧文件）；清失败则中止（不写令牌，宁可失败也不 fail-open）。
    if (!RemoveAll(installRoot)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "RemoveAll(%{public}s) failed", installRoot.c_str());
        return false;
    }
    MakeDirs(installRoot);
    if (!Untar(tar, installRoot)) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "untar failed");
        return false;
    }
    if (!WriteFile(tokenPath, kJreDataToken, std::strlen(kJreDataToken))) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "write token failed");
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
