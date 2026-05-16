cmake_minimum_required(VERSION 3.22)
project(sujihost C)

# build-lib.sh 가 ABI별로 스테이징한 CEF 무관 Suji 코어 정적 라이브러리.
add_library(suji_core STATIC IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_core.a)

# JNI 브리지 .so — Kotlin 이 System.loadLibrary("sujihost") 로 로드.
add_library(sujihost SHARED suji_jni.c)

# 레포 include/ 의 suji_core.h
target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core ${log-lib})
