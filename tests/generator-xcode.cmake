# Xcode generator: NOT supported, by CMake's design rather than ours -- Xcode
# is the one generator without per-config sources, and the module's object is
# a generated per-configuration source ($<CONFIG> in its path; left as the
# literal "NOCONFIG" by the Xcode generator).  What this asserts is the
# curated configure-time diagnostic, not a build.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
execute_process(
  COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src" -B "${WORK_DIR}/build" -G Xcode
    "-DHylo_COMPILER=${Hylo_COMPILER}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(_r EQUAL 0)
  message(FATAL_ERROR "configuring with the Xcode generator unexpectedly succeeded:\n${_o}")
endif()
assert_contains("${_o}${_e}" "the Xcode generator is not supported"
  "unsupported generator must fail with the curated message")
