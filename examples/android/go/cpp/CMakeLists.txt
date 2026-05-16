cmake_minimum_required(VERSION 3.22)
project(sujihost C)

# 코어는 동적 .so (zig LE-TLS↔JNI -shared 회피, build-lib.sh 참고). jniLibs 패키징.
add_library(suji_core SHARED IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libsuji_core.so)
# Go 는 Android c-archive 미지원 → c-shared(.so), Gradle jniLibs 자동 패키징.
add_library(suji_go_backend SHARED IMPORTED)
set_target_properties(suji_go_backend PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libsuji_go_backend.so)

add_library(sujihost SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../../_shared/cpp/suji_jni_core.c
    ${CMAKE_CURRENT_SOURCE_DIR}/backends.c)

target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core suji_go_backend ${log-lib})
