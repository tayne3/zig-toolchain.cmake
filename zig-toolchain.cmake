# ==============================================================================
# zig-toolchain.cmake v0.2.1
#
# Copyright (c) 2025 tayne3
# Licensed under the MIT License.
# ==============================================================================
include_guard(GLOBAL)

option(ZIG_USE_CCACHE "Enable ccache optimization for Zig toolchain" OFF)
set(ZIG_MCPU "" CACHE STRING "Target CPU (e.g. 'baseline', 'native', 'cortex_a53'). See: zig targets")
set(ZIG_MCPU_FEATURES "" CACHE STRING "CPU feature modifiers appended directly to -mcpu=<cpu>, e.g. '+avx2-sse4_1'")
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
  message(FATAL_ERROR "Zig Toolchain: Zig compiler found but failed to get version.")
endif()

unset(_zig_ccache_exe CACHE)
if(ZIG_USE_CCACHE)
  find_program(_zig_ccache_exe ccache)
  if(_zig_ccache_exe)
    message(STATUS "Zig Toolchain: ccache enabled at ${_zig_ccache_exe}")
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
    set(ZIG_OS "macos")
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
  set(ZIG_ARCH ${CMAKE_MATCH_1})
  set(ZIG_OS ${CMAKE_MATCH_2})
endif()

# Dummy version satisfies CMake's cross-compilation requirements without affecting Zig's behavior
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR ${ZIG_ARCH})
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

if(ZIG_OS STREQUAL "linux")
  set(CMAKE_SYSTEM_NAME "Linux")
elseif(ZIG_OS STREQUAL "windows")
  set(CMAKE_SYSTEM_NAME "Windows")
elseif(ZIG_OS STREQUAL "macos")
  set(CMAKE_SYSTEM_NAME "Darwin")
else()
  set(CMAKE_SYSTEM_NAME ${ZIG_OS})
  message(WARNING "Unknown OS: ${ZIG_OS}")
endif()

message(STATUS "Zig Toolchain: v${ZIG_COMPILER_VERSION} → ${ZIG_TARGET}")

# Build base compilation flags list
set(_zig_target_flags "-target" "${ZIG_TARGET}")
if(ZIG_MCPU)
  list(APPEND _zig_target_flags "-mcpu=${ZIG_MCPU}${ZIG_MCPU_FEATURES}")
endif()
if(ZIG_COMPILER_FLAGS)
  separate_arguments(_zig_extra_flags NATIVE_COMMAND "${ZIG_COMPILER_FLAGS}")
  list(APPEND _zig_target_flags ${_zig_extra_flags})
endif()

if(CMAKE_HOST_WIN32)
  set(_zig_wrapper_ext ".exe")
  set(_zig_host_win32 1)
else()
  set(_zig_wrapper_ext "")
  set(_zig_host_win32 0)
endif()

set(_zig_shims_dir "${CMAKE_BINARY_DIR}/.zig-shims")
file(MAKE_DIRECTORY "${_zig_shims_dir}")

# Use Bracket Argument [=[ ... ]=] to avoid escaping hell
set(_zig_shim_template [=[
// @_zig_tool_name@ wrapper for Zig toolchain
#include <stdio.h>
#include <stdlib.h>

#if @_zig_host_win32@
#include <process.h>
#else
#include <unistd.h>
#endif

int main(int argc, char** argv) {
  // User args (argc - 1) + NULL terminator (1) + Injected args count
  const char* exargv[argc + @_zig_extra_args_count@];
  const char **p = exargv;
@_zig_ccache_stmt@
  *p++ = "@_zig_compiler_exe_escaped@";
  *p++ = "@_zig_subcommand@";
@_zig_flags_stmts@
  for (int i = 1; i < argc; ++i) { *p++ = argv[i]; }
  *p = NULL;

#if @_zig_host_win32@
  return (int)_spawnvp(_P_WAIT, exargv[0], (const char* const*)exargv);
#else
  execvp(exargv[0], (char* const*)exargv);
  perror("execvp failed");
  return 1;
#endif
}
]=])

function(_zig_generate_shim tool_name subcommand inject_flags use_ccache)
  set(_zig_tool_name "${tool_name}")
  set(_zig_subcommand "${subcommand}")

  # 2 injected args baseline: zig executable + subcommand
  set(_zig_extra_args_count 2) 
  set(_zig_ccache_stmt "")
  set(_zig_flags_stmts "")

  # Escape executable paths for C string literal
  string(REPLACE "\\" "\\\\" _zig_compiler_exe_escaped "${_zig_compiler_exe}")

  # Process ccache injection
  if(use_ccache AND _zig_ccache_exe)
    string(REPLACE "\\" "\\\\" _zig_ccache_exe_escaped "${_zig_ccache_exe}")
    set(_zig_ccache_stmt "  *p++ = \"${_zig_ccache_exe_escaped}\";")
    math(EXPR _zig_extra_args_count "${_zig_extra_args_count} + 1")
  endif()

  # Process target flags injection
  if(inject_flags)
    foreach(_flag IN LISTS _zig_target_flags)
      string(REPLACE "\\" "\\\\" _flag_escaped "${_flag}")
      string(REPLACE "\"" "\\\"" _flag_escaped "${_flag_escaped}")
      string(APPEND _zig_flags_stmts "  *p++ = \"${_flag_escaped}\";\n")
      math(EXPR _zig_extra_args_count "${_zig_extra_args_count} + 1")
    endforeach()
  endif()

  # Render C template
  string(CONFIGURE "${_zig_shim_template}" _shim_content @ONLY)

  set(_shim_src  "${_zig_shims_dir}/${tool_name}.c")
  set(_shim_exe  "${_zig_shims_dir}/${tool_name}${_zig_wrapper_ext}")
  set(_shim_hash "${_zig_shims_dir}/${tool_name}.hash")

  # Avoid recompilation using MD5 hash check
  string(MD5 _new_hash "${_shim_content}")
  if(EXISTS "${_shim_hash}" AND EXISTS "${_shim_exe}")
    file(READ "${_shim_hash}" _old_hash)
    string(STRIP "${_old_hash}" _old_hash)
    if(_old_hash STREQUAL _new_hash)
      return()
    endif()
  endif()

  file(WRITE "${_shim_src}" "${_shim_content}")
  message(STATUS "Zig Toolchain: Compiling native wrapper for '${tool_name}'...")

  if(CMAKE_HOST_APPLE)
    set(_shim_strip_flag "")
  else()
    set(_shim_strip_flag "-s")
  endif()
  execute_process(
    COMMAND "${_zig_compiler_exe}" cc -O2 ${_shim_strip_flag} "${_shim_src}" -o "${_shim_exe}"
    RESULT_VARIABLE _compile_result
    ERROR_VARIABLE  _compile_stderr
    OUTPUT_QUIET
  )
  if(NOT _compile_result EQUAL 0)
    message(FATAL_ERROR
      "Zig Toolchain: Failed to compile wrapper executable for '${tool_name}'.\n"
      "${_compile_stderr}"
    )
  endif()

  if(NOT CMAKE_HOST_WIN32)
    execute_process(COMMAND chmod +x "${_shim_exe}" OUTPUT_QUIET)
  endif()

  file(WRITE "${_shim_hash}" "${_new_hash}")
endfunction()

_zig_generate_shim("zig-cc"      "cc"      TRUE  TRUE)
_zig_generate_shim("zig-c++"     "c++"     TRUE  TRUE)
_zig_generate_shim("zig-ar"      "ar"      FALSE FALSE)
_zig_generate_shim("zig-rc"      "rc"      FALSE FALSE)
_zig_generate_shim("zig-ranlib"  "ranlib"  FALSE FALSE)
_zig_generate_shim("zig-nm"      "nm"      FALSE FALSE)
_zig_generate_shim("zig-objcopy" "objcopy" FALSE FALSE)
_zig_generate_shim("zig-strip"   "strip"   FALSE FALSE)

set(CMAKE_C_COMPILER   "${_zig_shims_dir}/zig-cc${_zig_wrapper_ext}")
set(CMAKE_CXX_COMPILER "${_zig_shims_dir}/zig-c++${_zig_wrapper_ext}")
set(CMAKE_AR           "${_zig_shims_dir}/zig-ar${_zig_wrapper_ext}"      CACHE FILEPATH "Archiver" FORCE)
set(CMAKE_RANLIB       "${_zig_shims_dir}/zig-ranlib${_zig_wrapper_ext}"  CACHE FILEPATH "Ranlib" FORCE)
set(CMAKE_NM           "${_zig_shims_dir}/zig-nm${_zig_wrapper_ext}"      CACHE FILEPATH "NM" FORCE)
set(CMAKE_OBJCOPY      "${_zig_shims_dir}/zig-objcopy${_zig_wrapper_ext}" CACHE FILEPATH "Objcopy" FORCE)
set(CMAKE_STRIP        "${_zig_shims_dir}/zig-strip${_zig_wrapper_ext}"   CACHE FILEPATH "Strip" FORCE)

if(CMAKE_HOST_WIN32)
  # Unsupported linker arg: --dependency-file. See https://github.com/ziglang/zig/issues/22213
  set(CMAKE_C_LINKER_DEPFILE_SUPPORTED FALSE)
  set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)
endif()

if(CMAKE_SYSTEM_NAME MATCHES "Windows")
  set(CMAKE_RC_COMPILER "${_zig_shims_dir}/zig-rc${_zig_wrapper_ext}" CACHE FILEPATH "Resource Compiler" FORCE)
  # Explicitly specify MSVC syntax because zig rc only supports this format
  set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> /fo <OBJECT> <SOURCE>")
elseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")
  # Prevent CMake from searching for Xcode SDKs since Zig provides its own sysroot
  set(CMAKE_OSX_SYSROOT "" CACHE PATH "Force empty sysroot for Zig" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "Force empty deployment target" FORCE)
endif()
