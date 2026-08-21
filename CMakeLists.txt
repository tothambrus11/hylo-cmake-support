cmake_minimum_required(VERSION 3.30)

project(HyloExperiment LANGUAGES C)

# Hylo support is a find module plus one helper module, on the module path.
# Nothing here touches CMake's internal language machinery.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(Hylo 0.0.6 REQUIRED)

# A plain multi-source Hylo module: both files belong to one module, hc compiles
# them together, and cross-file references resolve. Exits 42.
hylo_add_executable(hello
  MODULE_NAME Hello
  SOURCES src/main.hylo src/support.hylo)

# These programs report their result through the exact exit status, matching the
# "exit-status:N" option in the upstream Hylo test packages. Defined before the
# examples are added so they can register their own tests.
enable_testing()

function(add_exit_status_test name target expected)
  add_test(NAME ${name} COMMAND ${CMAKE_COMMAND}
    -DEXE=$<TARGET_FILE:${target}> -DEXPECT=${expected}
    -P "${CMAKE_SOURCE_DIR}/cmake/RunExpectExit.cmake")
endfunction()

add_exit_status_test(hello_exits_42 hello 42)

add_subdirectory(examples)

# Build-system behaviour tests (incremental rebuilds, generators, ...). They
# configure and build the examples in scratch directories, so they are slower
# than the exit-status tests above; run them with `ctest -L behaviour`.
add_subdirectory(tests)
