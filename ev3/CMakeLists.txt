cmake_minimum_required(VERSION 3.30)

# EV3 line follower: a tiny C hardware library (ev3c), a C program and a Hylo
# program using it, and a simulator test. Configurable as its own project:
#
#   host build (runs in the simulator):
#     cmake -S ev3 -B build-ev3-host -G Ninja && cmake --build build-ev3-host && ctest --test-dir build-ev3-host
#   cross build for the brick (ev3dev):
#     cmake -S ev3 -B build-ev3 -G Ninja -DCMAKE_TOOLCHAIN_FILE=ev3/toolchains/ev3dev-armel.cmake \
#           -DHylo_COMPILER=$HOME/hylo-toolchains/v0.0.6-cross-src/.build/release/hc
#     cmake --build build-ev3 && ctest --test-dir build-ev3      # tests run under qemu-arm
#
# It reuses the repository's Hylo CMake support (../cmake: FindHylo + HyloTargets).
project(EV3LineFollower LANGUAGES C)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake")
find_package(Hylo 0.0.6 REQUIRED)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# --- the C hardware library -------------------------------------------------
# One backend: ev3dev sysfs. It is also the simulator backend (EV3C_SYSFS_ROOT).
add_library(ev3c STATIC
  libev3c/src/ev3c_sysfs.c
  libev3c/src/ev3c_hylo.c)        # @extern_c_indirect thunks for Hylo callers
target_include_directories(ev3c PUBLIC libev3c/include)
target_compile_options(ev3c PRIVATE -Wall -Wextra)

# --- programs ---------------------------------------------------------------
add_executable(linefollower-c linefollower-c/main.c)
target_link_libraries(linefollower-c PRIVATE ev3c)

hylo_add_executable(linefollower-hylo
  MODULE_NAME LineFollower
  SOURCES linefollower-hylo/LineFollower.hylo linefollower-hylo/EV3.hylo)
target_link_libraries(linefollower-hylo PRIVATE ev3c)

# --- simulator tests ----------------------------------------------------------
# Each program must complete a lap of the track in the simulated world without
# losing the line. When cross-compiling, CMAKE_CROSSCOMPILING_EMULATOR (set by
# the toolchain file to qemu-arm) runs the ARM binary -- the very file you copy
# to the brick.
enable_testing()
find_package(Python3 COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
  set(_sim "${CMAKE_CURRENT_SOURCE_DIR}/sim/ev3sim.py")
  set(_runner)
  if(CMAKE_CROSSCOMPILING_EMULATOR)
    list(GET CMAKE_CROSSCOMPILING_EMULATOR 0 _emu)
    set(_emu_args ${CMAKE_CROSSCOMPILING_EMULATOR})
    list(REMOVE_AT _emu_args 0)
    set(_runner --runner "${_emu}" -- ${_emu_args})
  endif()
  foreach(prog IN ITEMS linefollower-c linefollower-hylo)
    add_test(NAME sim_${prog}
      COMMAND "${Python3_EXECUTABLE}" "${_sim}" --robot "$<TARGET_FILE:${prog}>"
              --track kidney --duration 60 --laps 1
              --svg "${CMAKE_CURRENT_BINARY_DIR}/sim_${prog}.svg" ${_runner})
    set_tests_properties(sim_${prog} PROPERTIES TIMEOUT 120 LABELS simulation)
  endforeach()
endif()
