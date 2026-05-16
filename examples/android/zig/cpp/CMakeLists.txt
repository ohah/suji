cmake_minimum_required(VERSION 3.22)
project(sujihost C)

add_library(suji_core STATIC IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_core.a)
add_library(suji_zig_backend STATIC IMPORTED)
set_target_properties(suji_zig_backend PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_zig_backend.a)

add_library(sujihost SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../../_shared/cpp/suji_jni_core.c
    ${CMAKE_CURRENT_SOURCE_DIR}/backends.c)

target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core suji_zig_backend ${log-lib})
