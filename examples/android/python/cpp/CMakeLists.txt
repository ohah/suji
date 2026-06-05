cmake_minimum_required(VERSION 3.22)
project(sujihost C)

# 코어는 동적 .so (zig LE-TLS↔JNI -shared 회피, build-lib.sh 참고). jniLibs 패키징.
add_library(suji_core SHARED IMPORTED)
set_target_properties(suji_core PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libsuji_core.so)

# Python 백엔드는 정적 .a (suji_python_backend_*). Py* 심볼은 libpython.so 가 해소.
add_library(suji_python_backend STATIC IMPORTED)
set_target_properties(suji_python_backend PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libsuji_python_backend.a)

# embedded CPython — 동적 .so (jniLibs). 백엔드 .a 의 undefined Py* 를 링크 해소 +
# 런타임 로드. lib-dynload(.so 확장 모듈)는 PYTHONHOME/lib-dynload 에서 dlopen.
add_library(libpython SHARED IMPORTED)
set_target_properties(libpython PROPERTIES
    IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libpython3.13.so)

add_library(sujihost SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../../_shared/cpp/suji_jni_core.c
    ${CMAKE_CURRENT_SOURCE_DIR}/backends.c)

target_include_directories(sujihost PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../include)

find_library(log-lib log)
target_link_libraries(sujihost suji_core suji_python_backend libpython ${log-lib})
