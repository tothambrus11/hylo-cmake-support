# Runs EXE and asserts it exits with status EXPECT.
#
# ctest's WILL_FAIL only distinguishes zero from nonzero, but these programs
# communicate their result through the exact exit status (matching the
# "exit-status:N" option in the upstream Hylo test packages).
#
# EMULATOR (optional, a ;-list) is prepended to the command line -- the
# target's CROSSCOMPILING_EMULATOR, so cross-built tests run under e.g. qemu.
#
# Usage: cmake -DEXE=<path> -DEXPECT=<n> [-DEMULATOR=<emu;args>] -P RunExpectExit.cmake

execute_process(COMMAND ${EMULATOR} "${EXE}" RESULT_VARIABLE _actual)

if(NOT _actual STREQUAL EXPECT)
  message(FATAL_ERROR "${EMULATOR} ${EXE}: expected exit status ${EXPECT}, got ${_actual}")
endif()
