# Visual Studio generator (the installed version, probed and passed in as
# VS_GENERATOR): the module's multi-output custom command becomes an MSBuild
# CustomBuild step and the object links as an external object.  Both
# configurations build from one tree and run.  MSBuild has no restat, so
# over-rebuild is acceptable; an edit must still propagate (soundness).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond multi-module)
fixture_configure(GENERATOR "${VS_GENERATOR}")
fixture_build(out CONFIG Debug)
assert_build_ok(out)
fixture_build(out CONFIG Release)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/Debug/diamond" 23)
assert_exit("${WORK_DIR}/build/diamond/Release/diamond" 23)
assert_exit("${WORK_DIR}/build/multi-module/Release/multi" 42)
assert_exists("${WORK_DIR}/build/diamond/CMakeFiles/Base.hylo.dir/Debug/Base.hylomodule" "Debug archive")
assert_exists("${WORK_DIR}/build/diamond/CMakeFiles/Base.hylo.dir/Release/Base.hylomodule" "Release archive")

# An edit propagates.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out CONFIG Debug)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/Debug/diamond" 24)
