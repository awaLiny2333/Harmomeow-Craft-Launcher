cmake_minimum_required(VERSION 3.5.0)
project(meowcraft_native)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# 本 so（libmeowassets.so）仅承载 JRE 数据安装与 rawfile tar 解压工具：
# - installJre    （rawfile meow_jre25.tar.gz -> filesDir/meow-jres/meow_jre25）
# - extractRawTar （staging 启动支持 jar 等）
# JVM 启动与游戏渲染在 meowjre25 HSP（meowcraftlib HAR 并入的桥）内完成；
# entry 侧 GL/EGL/直启 JVM/dlopen 探针等历史代码已清理。
add_library(meowassets SHARED
    meowassets/napi_init.cpp
    meowassets/jre_launcher.cpp
)

target_include_directories(meowassets PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/meowassets)

target_link_libraries(meowassets PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    librawfile.z.so
    libz.so
)
