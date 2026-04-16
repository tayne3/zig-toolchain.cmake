<div align="center">

![zig-toolchain.cmake](assets/logo.svg)

# zig-toolchain.cmake

[![Release](https://img.shields.io/github/v/release/tayne3/zig-toolchain.cmake?include_prereleases&label=release&logo=github&logoColor=white)](https://github.com/tayne3/zig-toolchain.cmake/releases)
[![Tag](https://img.shields.io/github/v/tag/tayne3/zig-toolchain.cmake?color=%23ff8936&style=flat-square&logo=git&logoColor=white)](https://github.com/tayne3/zig-toolchain.cmake/tags)
[![Tests](https://github.com/tayne3/zig-toolchain.cmake/actions/workflows/test.yml/badge.svg)](https://github.com/tayne3/zig-toolchain.cmake/actions/workflows/test.yml)
![CMake](https://img.shields.io/badge/CMake-3.14%2B-brightgreen?logo=cmake&logoColor=white)

</div>

A lightweight CMake toolchain file that enables cross-compilation of C/C++ projects using Zig, eliminating the need to install platform-specific GCC toolchains.

## Usage

**Requirements**:

- CMake 3.14+
- Zig 0.15+

**Integration**:

Download `zig-toolchain.cmake` to your project root or a `cmake/` subdirectory.

```bash
curl -o zig-toolchain.cmake https://github.com/tayne3/zig-toolchain.cmake/releases/download/v0.3.0/zig-toolchain.cmake
```

**Cross-Compilation**:

Use standard CMake variables for common targets, or specify `ZIG_TARGET` directly when you need precise ABI control (e.g., `musl` vs `gnu`).

_Compile for Linux ARM64:_

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=zig-toolchain.cmake \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64

cmake --build build
```

_Compile for Windows x64:_

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=zig-toolchain.cmake \
  -DCMAKE_SYSTEM_NAME=Windows \
  -DCMAKE_SYSTEM_PROCESSOR=x86_64
```

_Compile for Linux x86_64 (Musl/Static):_

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=zig-toolchain.cmake \
  -DZIG_TARGET=x86_64-linux-musl
```
