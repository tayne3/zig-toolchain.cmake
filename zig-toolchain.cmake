include_guard(GLOBAL)

set(ZIG_TOOLCHAIN_VERSION "0.2.0")

if(CMAKE_GENERATOR MATCHES "Visual Studio")
  message(FATAL_ERROR "Zig Toolchain: Visual Studio generator is not supported. Please use '-G Ninja' or '-G MinGW Makefiles'.")
endif()

find_program(ZIG_COMPILER zig)
if(NOT ZIG_COMPILER)
  message(FATAL_ERROR "Zig Toolchain: Zig compiler not found. Please install Zig and ensure it is in your PATH.")
endif()
string(REPLACE "\\" "\\\\" _ZIG_COMPILER_EXE "${ZIG_COMPILER}")

execute_process(
  COMMAND "${ZIG_COMPILER}" version
  OUTPUT_VARIABLE ZIG_COMPILER_VERSION
  OUTPUT_STRIP_TRAILING_WHITESPACE
  RESULT_VARIABLE ZIG_VERSION_RESULT
)
if(NOT ZIG_VERSION_RESULT EQUAL 0)
  message(FATAL_ERROR "Zig Toolchain: Zig compiler found but failed to get version.")
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

option(ZIG_USE_CCACHE "Enable ccache optimization for Zig toolchain" OFF)
if(ZIG_USE_CCACHE)
  find_program(ZIG_CCACHE_EXECUTABLE ccache)
  if(ZIG_CCACHE_EXECUTABLE)
    message(STATUS "Zig Toolchain: ccache enabled at ${ZIG_CCACHE_EXECUTABLE}")
  else()
    message(WARNING "Zig Toolchain: ZIG_USE_CCACHE is ON but 'ccache' was not found in PATH.")
  endif()
endif()
if(ZIG_USE_CCACHE AND ZIG_CCACHE_EXECUTABLE)
  string(REPLACE "\\" "\\\\" _ZIG_CCACHE_EXE "${ZIG_CCACHE_EXECUTABLE}")
else()
  set(_ZIG_CCACHE_EXE "")
endif()

set(ZIG_MCPU "" CACHE STRING "Target CPU (e.g. 'baseline', 'native', 'cortex_a53'). See: zig targets")
set(ZIG_MCPU_FEATURES "" CACHE STRING "CPU feature modifiers appended directly to -mcpu=<cpu>, e.g. '+avx2-sse4_1'. Each feature must start with + or -.")
set(ZIG_COMPILER_FLAGS "" CACHE STRING "Additional compilation flags")

if(ZIG_MCPU_FEATURES AND NOT ZIG_MCPU)
  message(WARNING "Zig Toolchain: ZIG_MCPU_FEATURES='${ZIG_MCPU_FEATURES}' is set but ZIG_MCPU is empty.")
endif()
set(_ZIG_EXTRA_FLAGS_LIST "")
if(ZIG_MCPU)
  list(APPEND _ZIG_EXTRA_FLAGS_LIST "-mcpu=${ZIG_MCPU}${ZIG_MCPU_FEATURES}")
endif()
if(ZIG_COMPILER_FLAGS)
  separate_arguments(_ZIG_COMPILER_FLAGS NATIVE_COMMAND "${ZIG_COMPILER_FLAGS}")
  list(APPEND _ZIG_EXTRA_FLAGS_LIST ${_ZIG_COMPILER_FLAGS})
endif()

set(_ZIG_COMPILER_INJECTED_FLAGS "-target" "${ZIG_TARGET}" ${_ZIG_EXTRA_FLAGS_LIST})
list(LENGTH _ZIG_COMPILER_INJECTED_FLAGS _ZIG_INJECT_COUNT)
set(_ZIG_INJECTED_C_CODE "")
foreach(_arg IN LISTS _ZIG_COMPILER_INJECTED_FLAGS)
  string(REPLACE "\\" "\\\\" _arg_escaped "${_arg}")
  string(REPLACE "\"" "\\\"" _arg_escaped "${_arg_escaped}")
  string(APPEND _ZIG_INJECTED_C_CODE "\"${_arg_escaped}\", ")
endforeach()

if(CMAKE_HOST_WIN32)
  set(_ZIG_WRAPPER_EXT ".exe")
  set(_ZIG_IS_WIN32 1)
else()
  set(_ZIG_WRAPPER_EXT "")
  set(_ZIG_IS_WIN32 0)
endif()

if(CMAKE_HOST_APPLE)
  set(_ZIG_SHIM_STRIP_FLAG "")
else()
  set(_ZIG_SHIM_STRIP_FLAG "-s")
endif()

set(ZIG_SHIMS_DIR "${CMAKE_BINARY_DIR}/.zig-shims")
file(MAKE_DIRECTORY "${ZIG_SHIMS_DIR}")

function(generate_shim_binary TOOL_NAME ZIG_SUBCOMMAND INJECT_FLAGS USE_CCACHE)
  set(WRAPPER_SOURCE "${ZIG_SHIMS_DIR}/${TOOL_NAME}.c")
  set(WRAPPER_EXE    "${ZIG_SHIMS_DIR}/${TOOL_NAME}${_ZIG_WRAPPER_EXT}")
  set(WRAPPER_HASH   "${ZIG_SHIMS_DIR}/${TOOL_NAME}.hash")

  if(${INJECT_FLAGS})
    set(WRAPPER_INJECT_CODE "${_ZIG_INJECTED_C_CODE}")
    set(WRAPPER_INJECT_COUNT ${_ZIG_INJECT_COUNT})
  else()
    set(WRAPPER_INJECT_CODE "")
    set(WRAPPER_INJECT_COUNT 0)
  endif()
  
  if(${USE_CCACHE} AND _ZIG_CCACHE_EXE)
    set(WRAPPER_USE_CCACHE 1)
  else()
    set(WRAPPER_USE_CCACHE 0)
  endif()

  set(C_CODE_CONTENT "
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if ${_ZIG_IS_WIN32}
#include <process.h>
#else
#include <unistd.h>
#endif

#define ZIG_EXE      \"${_ZIG_COMPILER_EXE}\"
#define ZIG_CMD      \"${ZIG_SUBCOMMAND}\"
#define CCACHE_EXE   \"${_ZIG_CCACHE_EXE}\"
#define USE_CCACHE   ${WRAPPER_USE_CCACHE}
#define INJECT_COUNT ${WRAPPER_INJECT_COUNT}

int main(int argc, char** argv) {
  const char*  ijlist[] = {${WRAPPER_INJECT_CODE} NULL};
  const int    exargc   = USE_CCACHE + 2 + INJECT_COUNT + (argc - 1);
  const char** exargv   = (const char**)malloc(sizeof(char*) * (size_t)(exargc + 1));

  if (!exargv) {
    fprintf(stderr, \"malloc failed\\n\");
    return 1;
  }

  const char **p = exargv;
  if (USE_CCACHE) { *p++ = CCACHE_EXE; }
  *p++ = ZIG_EXE;
  *p++ = ZIG_CMD;
  for (int i = 0; i < INJECT_COUNT; ++i) { *p++ = ijlist[i]; }
  for (int i = 1; i < argc; ++i) { *p++ = argv[i]; }
  *p = NULL;

  #if ${_ZIG_IS_WIN32}
    intptr_t ret = _spawnvp(_P_WAIT, exargv[0], (const char* const*)exargv);
    free(exargv);
    return (int)ret;
  #else
    execvp(exargv[0], (char* const*)exargv);
    perror(\"execvp failed\");
    free(exargv);
    return 1;
  #endif
}")

  string(MD5 _new_hash "${C_CODE_CONTENT}")
  if(EXISTS "${WRAPPER_HASH}" AND EXISTS "${WRAPPER_EXE}")
    file(READ "${WRAPPER_HASH}" _old_hash)
    string(STRIP "${_old_hash}" _old_hash)
    if(_old_hash STREQUAL _new_hash)
      return()
    endif()
  endif()

  file(WRITE "${WRAPPER_SOURCE}" "${C_CODE_CONTENT}")
  message(STATUS "Zig Toolchain: Compiling native wrapper for '${TOOL_NAME}'...")

  execute_process(
    COMMAND "${ZIG_COMPILER}" cc -O2 ${_ZIG_SHIM_STRIP_FLAG} "${WRAPPER_SOURCE}" -o "${WRAPPER_EXE}"
    RESULT_VARIABLE COMPILE_RESULT
    ERROR_VARIABLE  COMPILE_STDERR
    OUTPUT_QUIET
  )
  if(NOT COMPILE_RESULT EQUAL 0)
    message(FATAL_ERROR
      "Zig Toolchain: Failed to compile wrapper executable for '${TOOL_NAME}'.\n"
      "${COMPILE_STDERR}")
  endif()

  if(NOT CMAKE_HOST_WIN32)
    execute_process(COMMAND chmod +x "${WRAPPER_EXE}" OUTPUT_QUIET)
  endif()

  file(WRITE "${WRAPPER_HASH}" "${_new_hash}")
endfunction()

generate_shim_binary("zig-cc"      "cc"      TRUE TRUE)
generate_shim_binary("zig-c++"     "c++"     TRUE TRUE)
generate_shim_binary("zig-ar"      "ar"      FALSE FALSE)
generate_shim_binary("zig-rc"      "rc"      FALSE FALSE)
generate_shim_binary("zig-ranlib"  "ranlib"  FALSE FALSE)
generate_shim_binary("zig-nm"      "nm"      FALSE FALSE)
generate_shim_binary("zig-objcopy" "objcopy" FALSE FALSE)
generate_shim_binary("zig-strip"   "strip"   FALSE FALSE)

set(CMAKE_C_COMPILER   "${ZIG_SHIMS_DIR}/zig-cc${_ZIG_WRAPPER_EXT}")
set(CMAKE_CXX_COMPILER "${ZIG_SHIMS_DIR}/zig-c++${_ZIG_WRAPPER_EXT}")
set(CMAKE_AR           "${ZIG_SHIMS_DIR}/zig-ar${_ZIG_WRAPPER_EXT}"      CACHE FILEPATH "Archiver" FORCE)
set(CMAKE_RANLIB       "${ZIG_SHIMS_DIR}/zig-ranlib${_ZIG_WRAPPER_EXT}"  CACHE FILEPATH "Ranlib" FORCE)
set(CMAKE_NM           "${ZIG_SHIMS_DIR}/zig-nm${_ZIG_WRAPPER_EXT}"      CACHE FILEPATH "NM" FORCE)
set(CMAKE_OBJCOPY      "${ZIG_SHIMS_DIR}/zig-objcopy${_ZIG_WRAPPER_EXT}" CACHE FILEPATH "Objcopy" FORCE)
set(CMAKE_STRIP        "${ZIG_SHIMS_DIR}/zig-strip${_ZIG_WRAPPER_EXT}"   CACHE FILEPATH "Strip" FORCE)

if(CMAKE_HOST_WIN32)
  # unsupported linker arg: --dependency-file. see https://github.com/ziglang/zig/issues/22213
  set(CMAKE_C_LINKER_DEPFILE_SUPPORTED FALSE)
  set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)
endif()

if(CMAKE_SYSTEM_NAME MATCHES "Windows")
  set(CMAKE_RC_COMPILER "${ZIG_SHIMS_DIR}/zig-rc${_ZIG_WRAPPER_EXT}" CACHE FILEPATH "Resource Compiler" FORCE)
  # Explicitly specify MSVC syntax because zig rc only supports this format
  set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> /fo <OBJECT> <SOURCE>")
elseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")
  # Prevent CMake from searching for Xcode SDKs since Zig provides its own sysroot
  set(CMAKE_OSX_SYSROOT "" CACHE PATH "Force empty sysroot for Zig" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "Force empty deployment target" FORCE)
endif()
