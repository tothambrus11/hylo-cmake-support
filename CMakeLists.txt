cmake_minimum_required(VERSION 3.28)

# Adding a language out-of-tree only requires putting the CMakeDetermine/
# Information/Test modules on the module path before the language is enabled.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# C is enabled because Hylo's C interop is just... C. CMake compiles the .c
# sources with its own C support and links them alongside the Hylo module.
project(HyloExperiment LANGUAGES C Hylo)

include(AddHylo)
include(HyloProjectManifest)

# 1. A plain multi-source Hylo module. Both files belong to one module; hc
#    compiles them together and cross-file references resolve. Exits 42.
hylo_add_executable(hello
  MODULE_NAME Hello
  src/main.hylo
  src/support.hylo)

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

# Emit the LSP-facing project manifest describing every Hylo module declared
# above (including the examples).
hylo_write_project_manifest()
