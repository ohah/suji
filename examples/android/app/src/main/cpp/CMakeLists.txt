cmake_minimum_required(VERSION 3.22)
project(sujihost C)

# build-lib.sh 가 ABI별로 스테이징한 CEF 무관 Suji 코어 정적 라이브러리.
add_library(suji_core STATIC IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_core.a)

# Rust 백엔드 정적 라이브러리 (suji_rs_* 고유 심볼).
add_library(suji_rs_backend STATIC IMPORTED)
set_target_properties(suji_rs_backend PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_rs_backend.a)

# Go 백엔드 — Android 는 c-archive 미지원이라 c-shared(.so). Gradle 이
# jniLibs/<abi>/ 를 자동 패키징, 여기선 링크용 IMPORTED SHARED 로만 참조.
add_library(suji_go_backend SHARED IMPORTED)
set_target_properties(suji_go_backend PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libsuji_go_backend.so)

# JNI 브리지 .so — Kotlin 이 System.loadLibrary("sujihost") 로 로드.
add_library(sujihost SHARED suji_jni.c)

# 레포 include/ 의 suji_core.h
target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core suji_rs_backend suji_go_backend ${log-lib})
