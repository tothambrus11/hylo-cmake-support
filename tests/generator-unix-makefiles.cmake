# Unix Makefiles: builds, runs, and an incremental edit propagates. (Make has
# no restat, so dependents are recompiled after any dependency rebuild; that is
# correct, just not minimal.)
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond c-interop)
fixture_configure(GENERATOR "Unix Makefiles" MAKE_PROGRAM "${MAKE}")
fixture_build(out ARGS -j 4)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_exit("${WORK_DIR}/build/c-interop/c-interop" 13)
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out ARGS -j 4)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
