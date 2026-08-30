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
  else()
    # Registering the fixtures against a multi-config generator would fail
    # them all on wrong output paths; skip them loudly instead.
    set(HYLO_TEST_GENERATOR "")
    message(STATUS "${CMAKE_GENERATOR} is multi-config and neither ninja nor "
      "make is on PATH; behaviour tests needing a single-config generator "
      "are not registered")
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
  add_behaviour_test(cross-target)
endif()
if(HYLO_TEST_GENERATOR)
  add_behaviour_test(import-visibility)
  add_behaviour_test(toolchain-swap)
  set_tests_properties(behaviour.toolchain-swap PROPERTIES
    SKIP_REGULAR_EXPRESSION "stdlib outside itself.*skipping")
  add_behaviour_test(per-config-flags)
  add_behaviour_test(transitive-options)
  add_behaviour_test(paths-with-spaces)
  add_behaviour_test(project-manifest)
  add_behaviour_test(install-export)
  if(NOT WIN32)
    add_behaviour_test(package-config)   # uses a symlink to stand in for an installed toolchain
    add_behaviour_test(development-version)   # the stub compiler is a shell script
  endif()
endif()

# Randomized incremental fuzzing: its own CI job, not part of the default
# suite (opt in, own label, no parallel sibling -- it measures rebuild
# minimality).  FUZZ_SEED/-ITERATIONS
# come from the environment at configure time; the seed is printed for replay.
option(HYLO_FUZZ "Register the randomized incremental fuzz test" OFF)
if(HYLO_FUZZ AND HYLO_TEST_GENERATOR STREQUAL "Ninja")
  add_behaviour_test(fuzz-incremental
    ARGS "-DFUZZ_SEED=$ENV{FUZZ_SEED}" "-DFUZZ_ITERATIONS=$ENV{FUZZ_ITERATIONS}")
  set_tests_properties(behaviour.fuzz-incremental PROPERTIES
    LABELS "fuzz" TIMEOUT 3000 RUN_SERIAL TRUE)
endif()
if(HYLO_TEST_NINJA)
  add_behaviour_test(generator-ninja-multi-config)
endif()
if(HYLO_TEST_MAKE AND NOT WIN32)
  add_behaviour_test(generator-unix-makefiles)
endif()

# Visual Studio, if one is installed.  `cmake -E capabilities` lists the
# generator names CMake *supports*, not the VS instances present (bit us on
# windows-latest, which now carries only VS 2026), so probe by configuring a
# trivial project.  The fixture builds both configurations with MSBuild:
# a longer timeout.
if(WIN32)
  set(_hylo_vs_generator "")
  set(_hylo_vs_probe "${CMAKE_CURRENT_BINARY_DIR}/vs-probe")
  foreach(_vs "Visual Studio 18 2026" "Visual Studio 17 2022")
    file(REMOVE_RECURSE "${_hylo_vs_probe}")
    file(WRITE "${_hylo_vs_probe}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.30)\nproject(probe NONE)\n")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -S "${_hylo_vs_probe}" -B "${_hylo_vs_probe}/build" -G "${_vs}"
      RESULT_VARIABLE _hylo_vs_result OUTPUT_QUIET ERROR_QUIET)
    if(_hylo_vs_result EQUAL 0)
      set(_hylo_vs_generator "${_vs}")
      break()
    endif()
  endforeach()
  if(_hylo_vs_generator)
    add_behaviour_test(generator-visual-studio ARGS "-DVS_GENERATOR=${_hylo_vs_generator}")
    set_tests_properties(behaviour.generator-visual-studio PROPERTIES TIMEOUT 600)
  else()
    message(STATUS "No Visual Studio instance found; behaviour.generator-visual-studio not registered")
  endif()
endif()

# Xcode is not supported (no per-config sources); the test asserts the
# curated configure-time diagnostic.  Probe that the generator itself works
# first: on a machine with only the Command Line Tools, `-G Xcode` dies with
# CMake's own error before the curated diagnostic can print.
if(APPLE)
  set(_hylo_xcode_probe "${CMAKE_CURRENT_BINARY_DIR}/xcode-probe")
  file(REMOVE_RECURSE "${_hylo_xcode_probe}")
  file(WRITE "${_hylo_xcode_probe}/CMakeLists.txt"
    "cmake_minimum_required(VERSION 3.30)\nproject(probe NONE)\n")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${_hylo_xcode_probe}" -B "${_hylo_xcode_probe}/build" -G Xcode
    RESULT_VARIABLE _hylo_xcode_result OUTPUT_QUIET ERROR_QUIET)
  if(_hylo_xcode_result EQUAL 0)
    add_behaviour_test(generator-xcode)
  else()
    message(STATUS "Xcode not available; behaviour.generator-xcode not registered")
  endif()
endif()
