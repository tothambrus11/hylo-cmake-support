# Source and build trees whose paths contain spaces: configure, build, run,
# and an edit propagates.  The whole fixture (src and build alike) lives under
# a spaced directory -- WORK_DIR itself is retargeted before the harness
# helpers are used, so every path they build inherits the spaces.
set(WORK_DIR "${WORK_DIR}/s p a c e d")
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_noop_rebuild("spaced paths")

file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
