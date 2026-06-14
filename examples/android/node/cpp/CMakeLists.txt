cmake_minimum_required(VERSION 3.22)
project(sujihost C CXX)

# 코어 동적 .so (zig LE-TLS↔JNI -shared 회피, build-lib.sh 참고). jniLibs 패키징.
add_library(suji_core SHARED IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libsuji_core.so)

# embedded Node.js — 동적 .so (jniLibs). bridge 의 undefined V8/node 심볼을 링크
# 해소 + 런타임 로드. stage-node-android.sh 가 NDK 크로스빌드(CI/ubuntu).
add_library(libnode SHARED IMPORTED)
set_target_properties(libnode PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libnode.so)

# Node bridge (suji_node_*) — 데스크톱과 *동일한* bridge.cc 를 NDK clang++ 로
# 컴파일(V8/libuv C++ 구현은 플랫폼 무관). node api headers 는 build-lib.sh 가
# cpp/node-include 로 staging. Python 변형의 백엔드 .a 대응 — Node 심볼은
# libnode.so 가 해소.
add_library(suji_node_bridge STATIC
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/platform/node/bridge.cc)
target_include_directories(suji_node_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/node-include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/platform/node)
target_compile_options(suji_node_bridge PRIVATE -std=c++20 -fPIC -fexceptions)

add_library(sujihost SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../../_shared/cpp/suji_jni_core.c
    ${CMAKE_CURRENT_SOURCE_DIR}/backends.c)

target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core suji_node_bridge libnode ${log-lib})
