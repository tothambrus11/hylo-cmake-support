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

# The fixtures assume a single-config command-line generator; one of those
# runs them with itself.  Under a multi-config generator (Ninja Multi-Config,
# Visual Studio, Xcode -- each has a dedicated test) they run with plain Ninja
# or, failing that, Makefiles.
get_property(_hylo_multi_config GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(NOT _hylo_multi_config)
  set(HYLO_TEST_GENERATOR "${CMAKE_GENERATOR}")
  set(HYLO_TEST_MAKE_PROGRAM "${CMAKE_MAKE_PROGRAM}")
elseif(CMAKE_GENERATOR STREQUAL "Ninja Multi-Config")
  # The build's own ninja drives the single-config Ninja generator too --
  # important when it is an IDE-bundled ninja that is not on PATH.
  set(HYLO_TEST_GENERATOR "Ninja")
  set(HYLO_TEST_MAKE_PROGRAM "${CMAKE_MAKE_PROGRAM}")
elseif(HYLO_TEST_NINJA)
  set(HYLO_TEST_GENERATOR "Ninja")
  set(HYLO_TEST_MAKE_PROGRAM "${HYLO_TEST_NINJA}")
elseif(HYLO_TEST_MAKE AND NOT WIN32)
  set(HYLO_TEST_GENERATOR "Unix Makefiles")
  set(HYLO_TEST_MAKE_PROGRAM "${HYLO_TEST_MAKE}")
else()
  # Registering the fixtures against a multi-config generator would fail
  # them all on wrong output paths; skip them loudly instead.
  set(HYLO_TEST_GENERATOR "")
  message(STATUS "${CMAKE_GENERATOR} is multi-config and no single-config "
    "build tool was found; behaviour tests needing one are not registered")
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
  add_behaviour_test(package-config)
  if(NOT WIN32)
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

# Whether `cmake -G <generator>` can configure a trivial project -- the only
# way to detect a *usable* generator: `cmake -E capabilities` lists the names
# CMake supports, not the toolchains present (bit us on windows-latest, which
# now carries only VS 2026).  Memoized in the cache; the answer cannot change
# within a build tree's life, like FindHylo's works-check.
function(hylo_generator_works out generator)
  string(MAKE_C_IDENTIFIER "_HYLO_GENERATOR_WORKS_${generator}" _key)
  if(NOT DEFINED ${_key})
    set(_probe "${CMAKE_CURRENT_BINARY_DIR}/generator-probe")
    file(REMOVE_RECURSE "${_probe}")
    file(WRITE "${_probe}/CMakeLists.txt"
      "cmake_minimum_required(VERSION 3.30)\nproject(probe NONE)\n")
    execute_process(
      COMMAND "${CMAKE_COMMAND}" -S "${_probe}" -B "${_probe}/build" -G "${generator}"
      RESULT_VARIABLE _r OUTPUT_QUIET ERROR_QUIET)
    if(_r EQUAL 0)
      set(${_key} TRUE CACHE INTERNAL "cmake -G ${generator} works")
    else()
      set(${_key} FALSE CACHE INTERNAL "cmake -G ${generator} works")
    endif()
  endif()
  set(${out} ${${_key}} PARENT_SCOPE)
endfunction()

# Visual Studio, if one is installed: probe every VS generator this CMake
# supports, newest first, and test against the newest usable one.  The
# fixture builds both configurations with MSBuild: a longer timeout.
if(WIN32)
  set(_hylo_vs_generator "")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E capabilities
    OUTPUT_VARIABLE _hylo_caps ERROR_QUIET)
  string(REGEX MATCHALL "\"Visual Studio [0-9]+ [0-9]+\"" _hylo_vs_candidates "${_hylo_caps}")
  list(REMOVE_DUPLICATES _hylo_vs_candidates)
  list(SORT _hylo_vs_candidates COMPARE NATURAL ORDER DESCENDING)
  foreach(_vs IN LISTS _hylo_vs_candidates)
    string(REPLACE "\"" "" _vs "${_vs}")
    hylo_generator_works(_hylo_vs_works "${_vs}")
    if(_hylo_vs_works)
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
  hylo_generator_works(_hylo_xcode_works Xcode)
  if(_hylo_xcode_works)
    add_behaviour_test(generator-xcode)
  else()
    message(STATUS "Xcode not available; behaviour.generator-xcode not registered")
  endif()
endif()
