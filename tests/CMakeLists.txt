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

function(add_behaviour_test name)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "" "ARGS")
  add_test(NAME behaviour.${name}
    COMMAND "${CMAKE_COMMAND}"
      "-DSOURCE_DIR=${CMAKE_SOURCE_DIR}"
      "-DWORK_DIR=${CMAKE_CURRENT_BINARY_DIR}/${name}"
      "-DHylo_COMPILER=${Hylo_COMPILER}"
      "-DGENERATOR=${CMAKE_GENERATOR}"
      "-DMAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
      "-DC_COMPILER=${CMAKE_C_COMPILER}"
      "-DNINJA=${HYLO_TEST_NINJA}"
      "-DMAKE=${HYLO_TEST_MAKE}"
      ${arg_ARGS}
      -P "${CMAKE_CURRENT_SOURCE_DIR}/${name}.cmake")
  set_tests_properties(behaviour.${name} PROPERTIES LABELS behaviour TIMEOUT 300)
endfunction()

# The incremental-build tests depend on Ninja's restat and output semantics.
if(CMAKE_GENERATOR MATCHES "Ninja")
  add_behaviour_test(incremental-interface-hash)
  add_behaviour_test(regenerate-deleted-archive)
  add_behaviour_test(mixed-c-partial-rebuild)
  add_behaviour_test(late-target-sources)
endif()
add_behaviour_test(import-visibility)
add_behaviour_test(per-config-flags)
add_behaviour_test(project-manifest)
if(HYLO_TEST_NINJA)
  add_behaviour_test(generator-ninja-multi-config)
endif()
if(HYLO_TEST_MAKE AND NOT WIN32)
  add_behaviour_test(generator-unix-makefiles)
endif()
