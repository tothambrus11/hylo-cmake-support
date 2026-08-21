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

function(assert_build_ok out)
  if(NOT ${out}_RESULT EQUAL 0)
    message(FATAL_ERROR "build failed (${${out}_RESULT}):\n${${out}}")
  endif()
endfunction()

function(assert_build_fails out)
  if(${out}_RESULT EQUAL 0)
    message(FATAL_ERROR "build unexpectedly succeeded:\n${${out}}")
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
