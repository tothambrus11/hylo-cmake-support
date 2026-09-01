cmake_minimum_required(VERSION 3.30)

project(HyloExperiment LANGUAGES C)

# Hylo support is a find module plus one helper module, on the module path.
# Nothing here touches CMake's internal language machinery.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
find_package(Hylo 0.0.8 REQUIRED)

# The example programs report their result through the exact exit status,
# matching the "exit-status:N" option in the upstream Hylo test packages; each
# example registers its own test through this.
enable_testing()

function(add_exit_status_test name target expected)
  add_test(NAME ${name} COMMAND ${CMAKE_COMMAND}
    -DEXE=$<TARGET_FILE:${target}> -DEXPECT=${expected}
    # The target's emulator (qemu & co.), so cross-built tests run too.
    "-DEMULATOR=$<TARGET_PROPERTY:${target},CROSSCOMPILING_EMULATOR>"
    -P "${CMAKE_SOURCE_DIR}/cmake/RunExpectExit.cmake")
endfunction()

add_subdirectory(examples)

# Build-system behaviour tests (incremental rebuilds, generators, ...). They
# configure and build the examples in scratch directories, so they are slower
# than the exit-status tests above; run them with `ctest -L behaviour`.
add_subdirectory(tests)
