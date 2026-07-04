# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(printing_ffi_library VERSION 0.0.1 LANGUAGES C)

add_library(printing_ffi SHARED
  "printing_ffi.c"
)

set_target_properties(printing_ffi PROPERTIES
  PUBLIC_HEADER printing_ffi.h
  OUTPUT_NAME "printing_ffi"
)

target_compile_definitions(printing_ffi PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(printing_ffi PRIVATE "-Wl,-z,max-page-size=16384")

  # Bundled-CUPS integration: link the statically-built libcups so the existing
  # libcups IPP client (#include <cups/cups.h>) compiles + links on Android and
  # can talk to the in-app cupsd. The static libs + headers were cross-compiled
  # for arm64-v8a (see tool/android/NOTES.md "App packaging"). Only arm64-v8a was
  # built, so guard to that ABI; for any other ABI we skip CUPS linking and define
  # PRINTING_FFI_NO_CUPS so the C falls back to no-CUPS stubs (build won't break).
  set(CUPS_ANDROID_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../tool/android/out/arm64")
  if(ANDROID_ABI STREQUAL "arm64-v8a" AND EXISTS "${CUPS_ANDROID_ROOT}/lib/libcups.a")
    message(STATUS "printing_ffi: linking bundled static CUPS for arm64-v8a from ${CUPS_ANDROID_ROOT}")
    target_include_directories(printing_ffi PUBLIC "${CUPS_ANDROID_ROOT}/include")
    target_link_libraries(printing_ffi PUBLIC
      "${CUPS_ANDROID_ROOT}/lib/libcups.a"
      "${CUPS_ANDROID_ROOT}/lib/libcupsimage.a"
      z m dl log)
  else()
    # The bundled CUPS static libs were only cross-compiled for arm64-v8a
    # (tool/android/out/arm64). The plugin's whole Android implementation depends
    # on libcups, so fail loudly rather than emit a half-built library. Restrict
    # the app to arm64-v8a (ndk { abiFilters += "arm64-v8a" }) or cross-build CUPS
    # for the requested ABI under tool/android/out/<abi>.
    message(FATAL_ERROR "printing_ffi: bundled CUPS is only available for arm64-v8a, "
                        "but ABI '${ANDROID_ABI}' was requested. Restrict the Android "
                        "build to arm64-v8a (abiFilters) or cross-build CUPS for this ABI.")
  endif()
elseif(WIN32)
  # On Windows, link against Pdfium and the Graphics Device Interface library.
  # Use an absolute path to ensure the compiler can always find the headers.
  if(NOT IS_ABSOLUTE "${PDFIUM_INCLUDE_DIR}")
    set(PDFIUM_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/windows/${PDFIUM_INCLUDE_DIR}")
  endif()
  target_include_directories(printing_ffi PUBLIC "${PDFIUM_INCLUDE_DIR}")
  target_link_libraries(printing_ffi PUBLIC "gdi32.lib")
endif()

if(APPLE)
    # On macOS, find CUPS framework
    find_library(CUPS_LIBRARY cups)
    if(CUPS_LIBRARY)
        target_link_libraries(printing_ffi PUBLIC ${CUPS_LIBRARY})
    endif()
elseif(UNIX AND NOT ANDROID)
    # On Linux, find CUPS headers and library manually, most distributions
    find_path(CUPS_INCLUDE_DIR NAMES cups/cups.h)
    find_library(CUPS_LIBRARY NAMES cups)
    if(CUPS_INCLUDE_DIR AND CUPS_LIBRARY)
        target_include_directories(printing_ffi PUBLIC ${CUPS_INCLUDE_DIR})
        target_link_libraries(printing_ffi PUBLIC ${CUPS_LIBRARY})
    else()
        message(FATAL_ERROR "Could not find CUPS headers or library")
    endif()
endif()
