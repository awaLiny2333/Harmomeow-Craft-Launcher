cmake_minimum_required(VERSION 3.5.0)
project(meowcraftlib)

# MeowJreBridge：Meowcraft 自研 ArkTS→JVM 桥（进程内 dlopen JRE 的 libjli 起 JVM）。
# meowqos.c 编进两个 target：各自给“调用它的线程”设 QoS / 绑核（jre 侧 = 启动线程，
# craftbridge 侧 = 渲染线程）；env 驱动、缺库可降级。
add_library(meowjrebridge SHARED
    meowjrebridge/meowjrebridge.cpp
    meowcraftbridge/meowqos.c
)

target_link_libraries(meowjrebridge PUBLIC
    libhilog_ndk.z.so
    libace_napi.z.so
    libace_ndk.z.so
    libnative_window_manager.so
)

# meowcraftbridge：Meowcraft 自研的鸿蒙 GLFW/GL 桥（净室实现，
# 替代外部闭源 so）。CMake target 用 meow 前缀区分自研/拿来；产物 libmeowcraftbridge.so，
# 由 meowjrebridge dlopen，且随包 lwjgl.jar 的 GLFW stub 已按此名加载（见 tools/lwjgl overlay）。
# 目录内为扁平布局：源文件 + vendored jni.h/jni_md.h（OHOS NDK 无 jni.h，OpenJDK GPL+CE 拷贝）。
add_library(meowcraftbridge SHARED
    meowcraftbridge/egl_gl.c
    meowcraftbridge/input_bridge.c
    meowcraftbridge/meowcraftbridge_environ.c
    meowcraftbridge/meowqos.c)

target_include_directories(meowcraftbridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/meowcraftbridge)

target_link_libraries(meowcraftbridge PUBLIC
    libhilog_ndk.z.so libnative_window.so libnative_window_manager.so libohinput.so libEGL.so)
