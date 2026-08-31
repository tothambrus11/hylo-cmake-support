# Cross-compile the whole project for aarch64-linux and run the test programs
# under qemu (the cross-aarch64 CI job; needs gcc-aarch64-linux-gnu + qemu-user).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CROSSCOMPILING_EMULATOR "qemu-aarch64;-L;/usr/aarch64-linux-gnu")
set(Hylo_TARGET_TRIPLE "aarch64-unknown-linux-gnu" CACHE STRING "")
