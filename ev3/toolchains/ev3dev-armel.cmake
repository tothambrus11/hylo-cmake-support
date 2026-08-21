# CMake toolchain file: cross-compile for the LEGO EV3 running ev3dev
# (ARM926EJ-S = ARMv5TEJ, soft-float, Debian "armel").
#
#   cmake -S ev3 -B build-ev3 -G Ninja \
#         -DCMAKE_TOOLCHAIN_FILE=ev3/toolchains/ev3dev-armel.cmake \
#         -DHylo_COMPILER=/path/to/hc-with-ARM-target
#
# C compiler: any arm-linux-gnueabi-gcc. Candidates, in order:
#   1. $EV3_TOOLCHAIN_PREFIX/bin/arm-linux-gnueabi-gcc (or -DEV3_TOOLCHAIN_PREFIX=...)
#   2. ~/hylo-toolchains/arm-linux-gnueabi-ubuntu/bin (Ubuntu cross gcc extracted
#      without root, see ev3/docs/CROSS-COMPILING.md)
#   3. arm-linux-gnueabi-gcc on PATH (e.g. `sudo apt install gcc-arm-linux-gnueabi`)
# Binaries are linked -static so that the host toolchain's glibc version is
# irrelevant on the brick (ev3dev-stretch has glibc 2.24, Ubuntu 24.04's cross
# glibc is 2.39: dynamic linking fails with "GLIBC_2.34 not found").
#
# Hylo: FindHylo passes Hylo_TARGET_TRIPLE to `hc --target`; it is derived from
# CMAKE_C_COMPILER_TARGET below. hc must have been built with LLVM's ARM
# backend (the v0.0.6 release binary only has X86 -- see CROSS-COMPILING.md).

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(_ev3_prefix "$ENV{EV3_TOOLCHAIN_PREFIX}")
if(EV3_TOOLCHAIN_PREFIX)
  set(_ev3_prefix "${EV3_TOOLCHAIN_PREFIX}")
endif()
find_program(EV3_C_COMPILER
  NAMES arm-linux-gnueabi-gcc arm-linux-gnueabi-gcc-13 arm-linux-gnueabi-gcc-12
  HINTS "${_ev3_prefix}/bin" "$ENV{HOME}/hylo-toolchains/arm-linux-gnueabi-ubuntu/bin"
  DOC "ARM EABI (armel) cross C compiler for the EV3")
if(NOT EV3_C_COMPILER)
  message(FATAL_ERROR
    "ev3dev-armel.cmake: no arm-linux-gnueabi-gcc found. Install gcc-arm-linux-gnueabi, "
    "or set EV3_TOOLCHAIN_PREFIX to a prefix containing bin/arm-linux-gnueabi-gcc.")
endif()
set(CMAKE_C_COMPILER "${EV3_C_COMPILER}")
get_filename_component(_ev3_bindir "${EV3_C_COMPILER}" DIRECTORY)
find_program(CMAKE_AR NAMES arm-linux-gnueabi-ar HINTS "${_ev3_bindir}")
find_program(CMAKE_RANLIB NAMES arm-linux-gnueabi-ranlib HINTS "${_ev3_bindir}")
find_program(CMAKE_STRIP NAMES arm-linux-gnueabi-strip HINTS "${_ev3_bindir}")

# What hc is told to generate code for. gnueabi = soft-float ABI.
set(CMAKE_C_COMPILER_TARGET armv5te-unknown-linux-gnueabi)

set(CMAKE_C_FLAGS_INIT "-march=armv5te -mtune=arm926ej-s -mfloat-abi=soft")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")

# Never pick up host libraries/headers.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Lets `ctest` / CMake run the cross binaries under qemu-arm when available
# (qemu-arm-static on PATH, or -DEV3_QEMU=/path/to/qemu-arm-static).
if(NOT EV3_QEMU)
  find_program(EV3_QEMU NAMES qemu-arm-static qemu-arm
    HINTS "$ENV{EV3_QEMU_DIR}" "$ENV{HOME}/hylo-toolchains/bin")
endif()
if(EV3_QEMU)
  set(CMAKE_CROSSCOMPILING_EMULATOR "${EV3_QEMU};-cpu;arm926")
endif()
