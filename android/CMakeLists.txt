# ---------------------------------------------------------------------------
# printing_ffi — Android native build.
#
# CUPS/gutenprint/libusb have no Android system package, so we cross-compile the
# whole stack from pinned sources with the NDK, DURING the consumer's Gradle
# build. build_cups_android.sh does that once per ABI, caches the result under
# ~/.gradle, stages libcups.a + headers for CMake to link, and drops the runtime
# lib*.so + share/ assets into build-dir folders that build.gradle packages into
# the APK. Running it from execute_process (CMake configure) — not a Gradle task
# — guarantees the staged libs exist before add_library/link below, independent
# of Gradle task ordering. Mirrors flutter_fotobox_gphoto's CMakeLists.txt.
#
# The from-source build needs CMake 3.22 (build.gradle pins version "3.22.1").
# ---------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.22)

project(printing_ffi_library VERSION 0.0.1 LANGUAGES C)

# CUPS_STAGE/<ABI>, CUPS_JNILIBS/<ABI>, CUPS_ASSETS, CUPS_CACHE are passed by the
# plugin's build.gradle via externalNativeBuild cmake.arguments.
foreach(v CUPS_STAGE CUPS_JNILIBS CUPS_ASSETS CUPS_CACHE)
  if(NOT DEFINED ${v})
    message(FATAL_ERROR "printing_ffi: ${v} not set (should come from build.gradle).")
  endif()
endforeach()

if(NOT DEFINED CMAKE_ANDROID_NDK)
  set(CMAKE_ANDROID_NDK "$ENV{ANDROID_NDK_HOME}")
endif()

set(STAGE "${CUPS_STAGE}/${ANDROID_ABI}")

# API level: AGP passes ANDROID_PLATFORM=android-<N>. CMAKE_SYSTEM_VERSION is
# unreliable this early in configure (can be 1), which would yield a bogus clang
# wrapper name like aarch64-linux-android1-clang in the cross scripts.
if(DEFINED ANDROID_PLATFORM)
  string(REGEX REPLACE "^android-" "" _MIN_SDK "${ANDROID_PLATFORM}")
else()
  set(_MIN_SDK "${CMAKE_SYSTEM_VERSION}")
endif()
if(NOT _MIN_SDK MATCHES "^[0-9]+$")
  set(_MIN_SDK 24)
endif()

# ---------------------------------------------------------------------------
# Cross-compile the CUPS stack HERE, during CMake configure. Idempotent + cached
# (keyed on the pinned source versions), so this is an instant no-op on rebuilds.
# ---------------------------------------------------------------------------
message(STATUS "printing_ffi: building CUPS stack for ${ANDROID_ABI} (API ${_MIN_SDK}) ...")
execute_process(
  COMMAND ${CMAKE_COMMAND} -E env
    "ABI=${ANDROID_ABI}"
    "MIN_SDK=${_MIN_SDK}"
    "NDK=${CMAKE_ANDROID_NDK}"
    "STAGE_DIR=${STAGE}"
    "JNILIBS_DIR=${CUPS_JNILIBS}/${ANDROID_ABI}"
    "ASSETS_DIR=${CUPS_ASSETS}"
    "CACHE_DIR=${CUPS_CACHE}"
    bash "${CMAKE_CURRENT_SOURCE_DIR}/../tool/android/build_cups_android.sh"
  RESULT_VARIABLE _cups_rc
)
if(NOT _cups_rc EQUAL 0)
  message(FATAL_ERROR "printing_ffi: CUPS native build failed for ${ANDROID_ABI} (rc=${_cups_rc}). See output above.")
endif()

if(NOT EXISTS "${STAGE}/lib/libcups.a")
  message(FATAL_ERROR "printing_ffi: CUPS not staged for ${ANDROID_ABI} at ${STAGE} (missing libcups.a).")
endif()

# ---------------------------------------------------------------------------
# The same C source as desktop/Windows; __ANDROID__ selects the bundled-cupsd
# path. DART_SHARED_LIB is what the desktop build defines too (see
# src/CMakeLists.txt); keep it so the FFI symbols export identically.
# ---------------------------------------------------------------------------
add_library(printing_ffi SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../src/printing_ffi.c")

set_target_properties(printing_ffi PROPERTIES OUTPUT_NAME "printing_ffi")
target_compile_definitions(printing_ffi PUBLIC DART_SHARED_LIB)

target_include_directories(printing_ffi PRIVATE "${STAGE}/include")

# Link the staged static CUPS libs by ABSOLUTE path. find_library() is avoided on
# purpose: the NDK toolchain sets CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY, which
# re-roots explicit PATHS under the NDK sysroot and never finds our staged libs
# (the same lesson as the gphoto plugin). z/m/dl/log are bionic system libs.
foreach(lib libcups.a libcupsimage.a)
  if(NOT EXISTS "${STAGE}/lib/${lib}")
    message(FATAL_ERROR "printing_ffi: expected staged lib missing: ${STAGE}/lib/${lib}")
  endif()
endforeach()

target_link_libraries(printing_ffi
  "${STAGE}/lib/libcups.a"
  "${STAGE}/lib/libcupsimage.a"
  z m dl log)

# Android 15+ requires 16 KB-aligned load segments on every shipped .so.
target_link_options(printing_ffi PRIVATE "-Wl,-z,max-page-size=16384")
