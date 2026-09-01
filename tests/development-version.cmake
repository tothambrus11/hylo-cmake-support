# Policy: a `development` hc (non-numeric --version, i.e. a compiler built
# from source) satisfies any requested version -- accepted with a status note,
# and everything still builds.  Simulated with a wrapper script that reports
# `development` and forwards everything else to the real hc.  Not on Windows
# (the wrapper is a shell script).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)

set(_stub "${WORK_DIR}/stub")
file(MAKE_DIRECTORY "${_stub}")
file(WRITE "${_stub}/hc"
"#!/bin/sh
if [ \"$1\" = \"--version\" ]; then echo development; exit 0; fi
exec \"${Hylo_COMPILER}\" \"$@\"
")
file(CHMOD "${_stub}/hc" PERMISSIONS
  OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)

# Ask for a concrete minimum version, which the stub cannot prove.
file(READ "${WORK_DIR}/src/CMakeLists.txt" _cm)
string(REPLACE "find_package(Hylo REQUIRED)" "find_package(Hylo 0.0.8 REQUIRED)" _cm "${_cm}")
file(WRITE "${WORK_DIR}/src/CMakeLists.txt" "${_cm}")

execute_process(
  COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src" -B "${WORK_DIR}/build" -G "${GENERATOR}"
    "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}" "-DCMAKE_C_COMPILER=${C_COMPILER}"
    "-DHylo_COMPILER=${_stub}/hc"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "a development compiler must be accepted; configure failed (${_r}):\n${_o}\n${_e}")
endif()
assert_contains("${_o}" "cannot check the requested version"
  "accepting an uncheckable version must be said out loud")

fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
