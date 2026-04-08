include_guard(GLOBAL)

set(ZIG_TOOLCHAIN_VERSION "0.1.3")

if(CMAKE_GENERATOR MATCHES "Visual Studio")
  message(FATAL_ERROR "Zig Toolchain: Visual Studio generator is not supported. Please use '-G Ninja' or '-G MinGW Makefiles'.")
endif()

find_program(ZIG_COMPILER zig)
if(NOT ZIG_COMPILER)
  message(FATAL_ERROR "Zig Toolchain: Zig compiler not found. Please install Zig and ensure it is in your PATH.")
endif()
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
  if(NOT ZIG_TARGET MATCHES "^([a-zA-Z0-9_]+)-([a-zA-Z0-9_]+)(-([a-zA-Z0-9_.]+))?$")
    message(FATAL_ERROR "Zig Toolchain: ZIG_TARGET is invalid. Please specify it manually using -DZIG_TARGET=<arch>-<os>[-<abi>]")
  endif()
  set(ZIG_ARCH ${CMAKE_MATCH_1})
  set(ZIG_OS ${CMAKE_MATCH_2})
  if(CMAKE_MATCH_4)
    set(ZIG_ABI ${CMAKE_MATCH_4})
  else()
    set(ZIG_ABI "none")
  endif()
endif()

# Dummy version satisfies CMake's cross-compilation requirements without affecting Zig's behavior
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR ${ZIG_ARCH})
if(ZIG_OS STREQUAL "linux")
  set(CMAKE_SYSTEM_NAME "Linux")
elseif(ZIG_OS STREQUAL "windows")
  set(CMAKE_SYSTEM_NAME "Windows")
elseif(ZIG_OS STREQUAL "macos")
  set(CMAKE_SYSTEM_NAME "Darwin")
else()
  message(FATAL_ERROR "Unknown OS: ${ZIG_OS}")
endif()
message(STATUS "Zig Toolchain: v${ZIG_COMPILER_VERSION} → ${ZIG_TARGET}")

set(ZIG_MCPU "" CACHE STRING "Target CPU (e.g. 'baseline', 'native', 'cortex_a53'). See: zig targets")
set(ZIG_MCPU_FEATURES "" CACHE STRING "CPU feature modifiers appended directly to -mcpu=<cpu>, e.g. '+avx2-sse4_1'. Each feature must start with + or -.")
set(ZIG_COMPILER_FLAGS "" CACHE STRING "Additional compilation flags")

set(ZIG_WRAPPER_ARGS "")
if(ZIG_MCPU)
  string(APPEND ZIG_WRAPPER_ARGS " -mcpu=${ZIG_MCPU}")
  if(ZIG_MCPU_FEATURES)
    string(APPEND ZIG_WRAPPER_ARGS "${ZIG_MCPU_FEATURES}")
  endif()
endif()
if(ZIG_COMPILER_FLAGS)
  string(APPEND ZIG_WRAPPER_ARGS " ${ZIG_COMPILER_FLAGS}")
endif()
string(STRIP "${ZIG_WRAPPER_ARGS}" ZIG_WRAPPER_ARGS)
if(ZIG_WRAPPER_ARGS)
  message(STATUS "Zig Toolchain: Compiler flags → ${ZIG_WRAPPER_ARGS}")
endif()

option(ZIG_USE_CCACHE "Enable ccache optimization for Zig toolchain" OFF)
set(ZIG_CC_PREFIX "")
if(ZIG_USE_CCACHE)
  find_program(CCACHE_TOOL ccache)
  if(CCACHE_TOOL)
    set(ZIG_CC_PREFIX "\"${CCACHE_TOOL}\" ")
    message(STATUS "Zig Toolchain: ccache enabled at ${CCACHE_TOOL}")
  else()
    message(WARNING "Zig Toolchain: ZIG_USE_CCACHE is ON but 'ccache' was not found in PATH.")
  endif()
endif()

# Generate wrapper scripts to inject -target flag and ccache prefix transparently
set(ZIG_SHIMS_DIR "${CMAKE_BINARY_DIR}/.zig-shims")
file(MAKE_DIRECTORY "${ZIG_SHIMS_DIR}")
if(CMAKE_HOST_WIN32)
  set(EXT ".cmd")
  set(HEADER "@echo off")
  set(ARGS "%*")
else()
  set(EXT "")
  set(HEADER "#!/bin/sh")
  set(ARGS "\"$@\"")
endif()

file(WRITE "${ZIG_SHIMS_DIR}/zig-cc${EXT}" "${HEADER}\n${ZIG_CC_PREFIX}\"${ZIG_COMPILER}\" cc -target ${ZIG_TARGET} ${ZIG_WRAPPER_ARGS} ${ARGS}\n")
file(WRITE "${ZIG_SHIMS_DIR}/zig-c++${EXT}" "${HEADER}\n${ZIG_CC_PREFIX}\"${ZIG_COMPILER}\" c++ -target ${ZIG_TARGET} ${ZIG_WRAPPER_ARGS} ${ARGS}\n")
file(WRITE "${ZIG_SHIMS_DIR}/zig-ar${EXT}" "${HEADER}\n\"${ZIG_COMPILER}\" ar ${ARGS}\n")
file(WRITE "${ZIG_SHIMS_DIR}/zig-rc${EXT}" "${HEADER}\n\"${ZIG_COMPILER}\" rc ${ARGS}\n")
file(WRITE "${ZIG_SHIMS_DIR}/zig-ranlib${EXT}" "${HEADER}\n\"${ZIG_COMPILER}\" ranlib ${ARGS}\n")
if(NOT CMAKE_HOST_WIN32)
  execute_process(COMMAND chmod +x 
    "${ZIG_SHIMS_DIR}/zig-cc${EXT}" 
    "${ZIG_SHIMS_DIR}/zig-c++${EXT}"
    "${ZIG_SHIMS_DIR}/zig-ar${EXT}"
    "${ZIG_SHIMS_DIR}/zig-rc${EXT}"
    "${ZIG_SHIMS_DIR}/zig-ranlib${EXT}"
  )
endif()

set(CMAKE_C_COMPILER "${ZIG_SHIMS_DIR}/zig-cc${EXT}")
set(CMAKE_CXX_COMPILER "${ZIG_SHIMS_DIR}/zig-c++${EXT}")
set(CMAKE_AR "${ZIG_SHIMS_DIR}/zig-ar${EXT}" CACHE FILEPATH "Archiver" FORCE)
set(CMAKE_RANLIB "${ZIG_SHIMS_DIR}/zig-ranlib${EXT}" CACHE FILEPATH "Ranlib" FORCE)

if(CMAKE_HOST_WIN32)
  # unsupported linker arg: --dependency-file
	set(CMAKE_C_LINKER_DEPFILE_SUPPORTED FALSE)
	set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)
endif()

if(CMAKE_SYSTEM_NAME MATCHES "Windows")
  set(CMAKE_RC_COMPILER "${ZIG_SHIMS_DIR}/zig-rc${EXT}" CACHE FILEPATH "Resource Compiler" FORCE)
  # Explicitly specify MSVC syntax because zig rc only supports this format
  set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> /fo <OBJECT> <SOURCE>")
elseif(CMAKE_SYSTEM_NAME MATCHES "Darwin")
  # Prevent CMake from searching for Xcode SDKs since Zig provides its own sysroot
  set(CMAKE_OSX_SYSROOT "" CACHE PATH "Force empty sysroot for Zig" FORCE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "Force empty deployment target" FORCE)
endif()
