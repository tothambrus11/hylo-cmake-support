# Build-system behaviour tests.
#
# Each test is a `cmake -P` script that configures and builds a fixture project
# (copies of the examples) in a scratch directory, mutates it, rebuilds, and
# asserts on what was recompiled and on the programs' exit codes. They verify
# the properties README.md claims: real multi-output compile edges, restat-based
# pruning of dependents, import visibility through target_link_libraries, and
# that the other generators work. Run with `ctest -L behaviour`.

find_program(HYLO_TEST_NINJA ninja)
find_program(HYLO_TEST_MAKE NAMES gmake make)

# The fixtures assume a single-config command-line generator; under a
# multi-config one (Ninja Multi-Config, Visual Studio, Xcode) run them with
# plain Ninja or Makefiles instead -- those generators have dedicated tests.
set(HYLO_TEST_GENERATOR "${CMAKE_GENERATOR}")
set(HYLO_TEST_MAKE_PROGRAM "${CMAKE_MAKE_PROGRAM}")
if(NOT CMAKE_GENERATOR MATCHES "^(Ninja|Unix Makefiles)$")
  if(HYLO_TEST_NINJA)
    set(HYLO_TEST_GENERATOR "Ninja")
    set(HYLO_TEST_MAKE_PROGRAM "${HYLO_TEST_NINJA}")
  elseif(HYLO_TEST_MAKE)
    set(HYLO_TEST_GENERATOR "Unix Makefiles")
    set(HYLO_TEST_MAKE_PROGRAM "${HYLO_TEST_MAKE}")
  endif()
endif()

function(add_behaviour_test name)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "ARGS")
  add_test(NAME behaviour.${name}
    COMMAND "${CMAKE_COMMAND}"
      "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
      "-DWORK_DIR=${CMAKE_CURRENT_BINARY_DIR}/${name}"
      "-DHylo_COMPILER=${Hylo_COMPILER}"
      "-DGENERATOR=${HYLO_TEST_GENERATOR}"
      "-DMAKE_PROGRAM=${HYLO_TEST_MAKE_PROGRAM}"
      "-DC_COMPILER=${CMAKE_C_COMPILER}"
      "-DNINJA=${HYLO_TEST_NINJA}"
      "-DMAKE=${HYLO_TEST_MAKE}"
      ${arg_ARGS}
      -P "${CMAKE_CURRENT_SOURCE_DIR}/${name}.cmake")
  set_tests_properties(behaviour.${name} PROPERTIES LABELS behaviour TIMEOUT 300)
endfunction()

# The incremental-build tests depend on Ninja's restat and output semantics.
if(HYLO_TEST_GENERATOR STREQUAL "Ninja")
  add_behaviour_test(incremental-interface-hash)
  add_behaviour_test(regenerate-deleted-archive)
  add_behaviour_test(mixed-c-partial-rebuild)
  add_behaviour_test(late-target-sources)
  add_behaviour_test(flag-change-rebuild)
endif()
add_behaviour_test(import-visibility)
add_behaviour_test(toolchain-swap)
add_behaviour_test(per-config-flags)
add_behaviour_test(transitive-options)
add_behaviour_test(project-manifest)
add_behaviour_test(install-export)
if(NOT WIN32)
  add_behaviour_test(package-config)   # uses a symlink to stand in for an installed toolchain
endif()
if(HYLO_TEST_NINJA)
  add_behaviour_test(generator-ninja-multi-config)
endif()
if(HYLO_TEST_MAKE AND NOT WIN32)
  add_behaviour_test(generator-unix-makefiles)
endif()

# The IDE generators, where CMake can produce them (their fixtures build both
# configurations and MSBuild/xcodebuild are slow: a longer timeout).
execute_process(COMMAND "${CMAKE_COMMAND}" -E capabilities
  OUTPUT_VARIABLE _hylo_cmake_capabilities ERROR_QUIET)
if(WIN32 AND _hylo_cmake_capabilities MATCHES "Visual Studio 17 2022")
  add_behaviour_test(generator-visual-studio)
  set_tests_properties(behaviour.generator-visual-studio PROPERTIES TIMEOUT 600)
endif()
if(APPLE AND _hylo_cmake_capabilities MATCHES "Xcode")
  add_behaviour_test(generator-xcode)
  set_tests_properties(behaviour.generator-xcode PROPERTIES TIMEOUT 600)
endif()
