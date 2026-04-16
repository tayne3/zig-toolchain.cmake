# ==============================================================================
# zig-toolchain.cmake v0.3.0
#
# Copyright (c) 2025 tayne3
# Licensed under the MIT License.
# ==============================================================================
include_guard(GLOBAL)

option(ZIG_USE_CCACHE "Enable ccache optimization for Zig toolchain" OFF)
set(ZIG_MCPU          ""  CACHE STRING "Target CPU (e.g. 'baseline', 'native', 'cortex_a53'). See: zig targets")
set(ZIG_MCPU_FEATURES ""  CACHE STRING "CPU feature modifiers appended directly to -mcpu=<cpu>, e.g. '+avx2-sse4_1'")
set(ZIG_COMPILER_FLAGS "" CACHE STRING "Additional compilation flags")

if(ZIG_MCPU_FEATURES AND NOT ZIG_MCPU)
  message(WARNING "Zig Toolchain: ZIG_MCPU_FEATURES='${ZIG_MCPU_FEATURES}' is set but ZIG_MCPU is empty.")
endif()

if(CMAKE_GENERATOR MATCHES "Visual Studio")
  message(FATAL_ERROR "Zig Toolchain: Visual Studio generator is not supported. Please use '-G Ninja' or '-G MinGW Makefiles'.")
endif()

unset(_zig_compiler_exe CACHE)
find_program(_zig_compiler_exe zig)
if(NOT _zig_compiler_exe)
  message(FATAL_ERROR "Zig Toolchain: Zig compiler not found. Please install Zig and ensure it is in your PATH.")
endif()

execute_process(
  COMMAND "${_zig_compiler_exe}" version
  OUTPUT_VARIABLE ZIG_COMPILER_VERSION
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE _zig_version_result
)
if(NOT _zig_version_result EQUAL 0)
  message(FATAL_ERROR "Zig Toolchain: Zig compiler found at '${_zig_compiler_exe}' but failed to retrieve its version.")
endif()

# Parse version string — handles both release ("0.16.0") and dev ("0.16.0-dev.1484+abc") formats
if(ZIG_COMPILER_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)")
  set(ZIG_VERSION_MAJOR "${CMAKE_MATCH_1}")
  set(ZIG_VERSION_MINOR "${CMAKE_MATCH_2}")
  set(ZIG_VERSION_PATCH "${CMAKE_MATCH_3}")
else()
  message(WARNING "Zig Toolchain: Could not parse version '${ZIG_COMPILER_VERSION}'. Proceeding anyway.")
  set(ZIG_VERSION_MAJOR 0)
  set(ZIG_VERSION_MINOR 0)
  set(ZIG_VERSION_PATCH 0)
endif()
if(ZIG_COMPILER_VERSION MATCHES "-(.+)$")
  set(ZIG_VERSION_DEV "${CMAKE_MATCH_1}")
else()
  set(ZIG_VERSION_DEV "")
endif()

if(ZIG_COMPILER_VERSION VERSION_LESS "0.15.0")
  message(WARNING
    "Zig Toolchain: Zig ${ZIG_COMPILER_VERSION} predates the recommended minimum (0.15.0). "
    "Toolchain behaviour is untested on this version.")
endif()

set(_zig_cc_prefix "")

unset(_zig_ccache_exe CACHE)
if(ZIG_USE_CCACHE)
  find_program(_zig_ccache_exe ccache)
  if(_zig_ccache_exe)
    message(STATUS "Zig Toolchain: ccache enabled at ${_zig_ccache_exe}")
    set(_zig_cc_prefix "\"${_zig_ccache_exe}\" ")
  else()
    message(WARNING "Zig Toolchain: ZIG_USE_CCACHE is ON but 'ccache' was not found in PATH.")
  endif()
endif()

if(NOT ZIG_TARGET)
  if(NOT CMAKE_SYSTEM_NAME)
    set(CMAKE_SYSTEM_NAME "${CMAKE_HOST_SYSTEM_NAME}")
  endif()
  if(NOT CMAKE_SYSTEM_PROCESSOR)
    set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_HOST_SYSTEM_PROCESSOR}")
  endif()

  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" ZIG_ARCH)
  if(ZIG_ARCH MATCHES "arm64|aarch64")
    set(ZIG_ARCH "aarch64")
  elseif(ZIG_ARCH MATCHES "x64|x86_64|amd64")
    set(ZIG_ARCH "x86_64")
  endif()

  string(TOLOWER "${CMAKE_SYSTEM_NAME}" ZIG_OS)
  set(ZIG_ABI "gnu")
  if(ZIG_OS MATCHES "darwin|macos")
    set(ZIG_OS  "macos")
    set(ZIG_ABI "none") # macOS uses its own ABI, not GNU
  elseif(ZIG_OS MATCHES "windows")
    set(ZIG_OS "windows")
  elseif(ZIG_OS MATCHES "linux")
    set(ZIG_OS "linux")
  endif()

  set(ZIG_TARGET "${ZIG_ARCH}-${ZIG_OS}-${ZIG_ABI}")
else()
  if(NOT ZIG_TARGET MATCHES "^([^-]+)-([^-]+)(-(.+))?$")
    message(FATAL_ERROR "Zig Toolchain: ZIG_TARGET '${ZIG_TARGET}' is invalid. Expected format: <arch>-<os>[-<abi>]")
  endif()
  set(ZIG_ARCH "${CMAKE_MATCH_1}")
  set(ZIG_OS   "${CMAKE_MATCH_2}")
endif()

# Satisfy CMake cross-compilation bookkeeping
set(CMAKE_SYSTEM_VERSION   1)
set(CMAKE_SYSTEM_PROCESSOR "${ZIG_ARCH}")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(ZIG_OS STREQUAL "linux")
  set(CMAKE_SYSTEM_NAME "Linux")
elseif(ZIG_OS STREQUAL "windows")
  set(CMAKE_SYSTEM_NAME "Windows")
elseif(ZIG_OS STREQUAL "macos")
  set(CMAKE_SYSTEM_NAME "Darwin")
else()
  set(CMAKE_SYSTEM_NAME "${ZIG_OS}")
  message(WARNING "Zig Toolchain: Unknown target OS '${ZIG_OS}'; CMAKE_SYSTEM_NAME set verbatim.")
endif()

message(STATUS "Zig Toolchain: v${ZIG_COMPILER_VERSION} → ${ZIG_TARGET}")

# Build the flags string that gets baked into every cc/c++ wrapper
set(_zig_target_flags "-target ${ZIG_TARGET}")
if(ZIG_MCPU)
  string(APPEND _zig_target_flags " -mcpu=${ZIG_MCPU}${ZIG_MCPU_FEATURES}")
endif()
if(ZIG_COMPILER_FLAGS)
  string(APPEND _zig_target_flags " ${ZIG_COMPILER_FLAGS}")
endif()
string(STRIP "${_zig_target_flags}" _zig_target_flags)

if(_zig_target_flags AND NOT _zig_target_flags STREQUAL "-target ${ZIG_TARGET}")
  message(STATUS "Zig Toolchain: Extra compiler flags → ${_zig_target_flags}")
endif()

set(_zig_shims_dir "${CMAKE_BINARY_DIR}/.zig-shims")
file(MAKE_DIRECTORY "${_zig_shims_dir}")

if(CMAKE_HOST_WIN32)
  set(_zig_wrapper_ext ".cmd")
else()
  set(_zig_wrapper_ext "")
endif()

function(_zig_write_script name subcommand inject_flags use_ccache)
  if(use_ccache AND _zig_cc_prefix)
    set(_prefix "${_zig_cc_prefix}")
  else()
    set(_prefix "")
  endif()

  if(inject_flags)
    set(_flags " ${_zig_target_flags}")
  else()
    set(_flags "")
  endif()

  if(CMAKE_HOST_WIN32)
    set(_script_path "${_zig_shims_dir}/${name}${_zig_wrapper_ext}")
    file(WRITE "${_script_path}"
      "@echo off\n"
      "${_prefix}\"${_zig_compiler_exe}\" ${subcommand}${_flags} %*\n"
    )
  else()
    set(_script_path "${_zig_shims_dir}/${name}${_zig_wrapper_ext}")
    file(WRITE "${_script_path}"
      "#!/bin/sh\n"
      "${_prefix}\"${_zig_compiler_exe}\" ${subcommand}${_flags} \"$@\"\n"
    )
    execute_process(
      COMMAND chmod +x "${_script_path}"
      OUTPUT_QUIET ERROR_QUIET
    )
  endif()
endfunction()

_zig_write_script("zig-cc"      "cc"      TRUE  TRUE)
_zig_write_script("zig-c++"     "c++"     TRUE  TRUE)
_zig_write_script("zig-ar"      "ar"      FALSE FALSE)
_zig_write_script("zig-rc"      "rc"      FALSE FALSE)
_zig_write_script("zig-ranlib"  "ranlib"  FALSE FALSE)
_zig_write_script("zig-nm"      "nm"      FALSE FALSE)
_zig_write_script("zig-objcopy" "objcopy" FALSE FALSE)
_zig_write_script("zig-strip"   "strip"   FALSE FALSE)

set(CMAKE_C_COMPILER   "${_zig_shims_dir}/zig-cc${_zig_wrapper_ext}")
set(CMAKE_CXX_COMPILER "${_zig_shims_dir}/zig-c++${_zig_wrapper_ext}")
set(CMAKE_AR           "${_zig_shims_dir}/zig-ar${_zig_wrapper_ext}"      CACHE FILEPATH "Archiver"          FORCE)
set(CMAKE_RANLIB       "${_zig_shims_dir}/zig-ranlib${_zig_wrapper_ext}"  CACHE FILEPATH "Ranlib"            FORCE)
set(CMAKE_NM           "${_zig_shims_dir}/zig-nm${_zig_wrapper_ext}"      CACHE FILEPATH "NM"                FORCE)
set(CMAKE_OBJCOPY      "${_zig_shims_dir}/zig-objcopy${_zig_wrapper_ext}" CACHE FILEPATH "Objcopy"           FORCE)
set(CMAKE_STRIP        "${_zig_shims_dir}/zig-strip${_zig_wrapper_ext}"   CACHE FILEPATH "Strip"             FORCE)

if(CMAKE_HOST_WIN32)
  # Unsupported linker arg: --dependency-file. See https://github.com/ziglang/zig/issues/22213
  set(CMAKE_C_LINKER_DEPFILE_SUPPORTED   FALSE)
  set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)
endif()

if(CMAKE_SYSTEM_NAME MATCHES "Windows")
  set(CMAKE_RC_COMPILER "${_zig_shims_dir}/zig-rc${_zig_wrapper_ext}" CACHE FILEPATH "Resource Compiler" FORCE)
  # Explicitly specify MSVC syntax because zig rc only supports this format
  set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> /fo <OBJECT> <SOURCE>")
elseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")
  # Prevent CMake from searching for Xcode SDKs since Zig provides its own sysroot
  set(CMAKE_OSX_SYSROOT           "" CACHE PATH   "Force empty sysroot for Zig"           FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "Force empty deployment target for Zig" FORCE)
endif()
