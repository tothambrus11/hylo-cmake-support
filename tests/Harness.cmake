# Shared helpers for the behaviour tests (cmake -P scripts).
#
# Expects: SOURCE_DIR (repo root), WORK_DIR (scratch dir for this test),
# Hylo_COMPILER, GENERATOR, MAKE_PROGRAM, C_COMPILER, NINJA, MAKE.

# Creates a fresh fixture project in ${WORK_DIR}/src made of copies of the
# named example directories, with a top-level CMakeLists that finds Hylo.
function(fixture_create)
  file(REMOVE_RECURSE "${WORK_DIR}")
  file(MAKE_DIRECTORY "${WORK_DIR}/src")
  set(_subdirs "")
  foreach(_example IN LISTS ARGN)
    file(COPY "${SOURCE_DIR}/examples/${_example}" DESTINATION "${WORK_DIR}/src")
    string(APPEND _subdirs "add_subdirectory(${_example})\n")
  endforeach()
  file(WRITE "${WORK_DIR}/src/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.30)
project(Fixture LANGUAGES C)
list(APPEND CMAKE_MODULE_PATH \"${SOURCE_DIR}/cmake\")
find_package(Hylo REQUIRED)
# The examples register exit-status tests through this; not needed here.
function(add_exit_status_test)
endfunction()
${_subdirs}")
endfunction()

# Configures ${WORK_DIR}/src into ${WORK_DIR}/build (or BUILD_DIR) with the
# test's generator unless GENERATOR <g> is given; extra args are passed on.
function(fixture_configure)
  cmake_parse_arguments(PARSE_ARGV 0 arg "" "GENERATOR;BUILD_DIR;MAKE_PROGRAM" "ARGS")
  set(_gen "${GENERATOR}")
  if(arg_GENERATOR)
    set(_gen "${arg_GENERATOR}")
  endif()
  set(_build "${WORK_DIR}/build")
  if(arg_BUILD_DIR)
    set(_build "${arg_BUILD_DIR}")
  endif()
  set(_make)
  if(arg_MAKE_PROGRAM)
    set(_make "-DCMAKE_MAKE_PROGRAM=${arg_MAKE_PROGRAM}")
  elseif(NOT arg_GENERATOR AND MAKE_PROGRAM)
    set(_make "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src" -B "${_build}" -G "${_gen}"
      "-DHylo_COMPILER=${Hylo_COMPILER}" "-DCMAKE_C_COMPILER=${C_COMPILER}" ${_make} ${arg_ARGS}
    RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
  if(NOT _r EQUAL 0)
    message(FATAL_ERROR "configure failed (${_r}):\n${_o}\n${_e}")
  endif()
endfunction()

# Builds; stores the combined output in ${out} and the exit code in ${out}_RESULT.
function(fixture_build out)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "BUILD_DIR;CONFIG" "ARGS")
  set(_build "${WORK_DIR}/build")
  if(arg_BUILD_DIR)
    set(_build "${arg_BUILD_DIR}")
  endif()
  set(_cfg)
  if(arg_CONFIG)
    set(_cfg --config "${arg_CONFIG}")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${_build}" ${_cfg} ${arg_ARGS}
    RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
  set(${out} "${_o}${_e}" PARENT_SCOPE)
  set(${out}_RESULT "${_r}" PARENT_SCOPE)
endfunction()

# The parameter must not be named like the caller's variable (conventionally
# `out`), or it would shadow the very variable it is meant to dereference.
function(assert_build_ok _abo_var)
  if(NOT ${_abo_var}_RESULT EQUAL 0)
    message(FATAL_ERROR "build failed (${${_abo_var}_RESULT}):\n${${_abo_var}}")
  endif()
endfunction()

function(assert_build_fails _abf_var)
  if(${_abf_var}_RESULT EQUAL 0)
    message(FATAL_ERROR "build unexpectedly succeeded:\n${${_abf_var}}")
  endif()
endfunction()

function(assert_contains text needle why)
  string(FIND "${text}" "${needle}" _i)
  if(_i EQUAL -1)
    message(FATAL_ERROR "${why}: expected to find '${needle}' in:\n${text}")
  endif()
endfunction()

function(assert_not_contains text needle why)
  string(FIND "${text}" "${needle}" _i)
  if(NOT _i EQUAL -1)
    message(FATAL_ERROR "${why}: did not expect '${needle}' in:\n${text}")
  endif()
endfunction()

function(assert_exit exe expected)
  execute_process(COMMAND "${exe}" RESULT_VARIABLE _r)
  if(NOT _r STREQUAL expected)
    message(FATAL_ERROR "${exe}: expected exit status ${expected}, got ${_r}")
  endif()
endfunction()

function(assert_exists path why)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${why}: '${path}' does not exist")
  endif()
endfunction()

# The compiled-module message for <module>, as printed by the custom command.
function(compile_message out module)
  set(${out} "Compiling Hylo module ${module} (" PARENT_SCOPE)
endfunction()

# Builds again and asserts the build is a no-op: nothing compiled, nothing
# linked.  Catches always-dirty edges, restat loops, and commands that touch
# their own inputs.  Accepts fixture_build's BUILD_DIR/CONFIG.
function(assert_noop_rebuild why)
  cmake_parse_arguments(PARSE_ARGV 1 arg "" "BUILD_DIR;CONFIG" "")
  set(_fb)
  if(arg_BUILD_DIR)
    list(APPEND _fb BUILD_DIR "${arg_BUILD_DIR}")
  endif()
  if(arg_CONFIG)
    list(APPEND _fb CONFIG "${arg_CONFIG}")
  endif()
  fixture_build(_noop ${_fb})
  assert_build_ok(_noop)
  assert_not_contains("${_noop}" "Compiling Hylo module" "${why}: second build must be a no-op")
  assert_not_contains("${_noop}" "Linking C" "${why}: second build must not relink")
endfunction()

# Sets ${out} to ON when the compiler's interface hash is precise (a body-only
# change leaves it untouched -- hylo-lang/hylo-new#321), OFF while it is a
# hash of the whole archive.  Incremental tests assert soundness identically
# either way and branch only their expected recompile sets on this
# (notes/TESTING-STRATEGY.md, section 3.2).
function(probe_hash_precise out)
  set(_d "${WORK_DIR}/hash-probe")
  file(MAKE_DIRECTORY "${_d}/cache")
  foreach(_body IN ITEMS 1 2)
    file(WRITE "${_d}/P.hylo" "public fun p() -> Int32 { ${_body} }\n")
    execute_process(
      COMMAND "${Hylo_COMPILER}" --module-name P --module-cache "${_d}/cache"
        --emit object -o "${_d}/P.o" --emit-module-to "${_d}/P.hylomodule"
        --emit-module-interface-hash-to "${_d}/P${_body}.iface" "${_d}/P.hylo"
      RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _o)
    if(NOT _r EQUAL 0)
      message(FATAL_ERROR "hash probe failed to compile (${_r}):\n${_o}")
    endif()
  endforeach()
  file(READ "${_d}/P1.iface" _h1 HEX)
  file(READ "${_d}/P2.iface" _h2 HEX)
  if(_h1 STREQUAL _h2)
    set(${out} ON PARENT_SCOPE)
    message(STATUS "interface hash: precise (body-only edits leave it unchanged)")
  else()
    set(${out} OFF PARENT_SCOPE)
    message(STATUS "interface hash: conservative (whole archive)")
  endif()
endfunction()

# Extracts the hc command line that compiled <module> from verbose build output.
function(hc_command out module text)
  string(REGEX MATCH "hc(\\.exe)? --module-name ${module} [^\n]*" _cmd "${text}")
  if(NOT _cmd)
    message(FATAL_ERROR "no hc command for module ${module} in:\n${text}")
  endif()
  set(${out} "${_cmd}" PARENT_SCOPE)
endfunction()
