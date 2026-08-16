# Runs EXE and asserts it exits with status EXPECT.
#
# ctest's WILL_FAIL only distinguishes zero from nonzero, but these programs
# communicate their result through the exact exit status (matching the
# "exit-status:N" option in the upstream Hylo test packages).
#
# Usage: cmake -DEXE=<path> -DEXPECT=<n> -P RunExpectExit.cmake

execute_process(COMMAND "${EXE}" RESULT_VARIABLE _actual)

if(NOT _actual STREQUAL EXPECT)
  message(FATAL_ERROR "${EXE}: expected exit status ${EXPECT}, got ${_actual}")
endif()
