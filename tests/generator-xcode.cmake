# Xcode generator: the module's custom command becomes a script phase.  The
# real risk is the external object -- Xcode is the one generator that rewrites
# object locations (HasKnownObjectFileLocation() is false), so a fixed-path
# external object linking correctly is exactly what this asserts.  Both
# configurations build from one tree and run; an edit must propagate.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond multi-module)
fixture_configure(GENERATOR "Xcode")
fixture_build(out CONFIG Debug)
assert_build_ok(out)
fixture_build(out CONFIG Release)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/Debug/diamond" 23)
assert_exit("${WORK_DIR}/build/diamond/Release/diamond" 23)
assert_exit("${WORK_DIR}/build/multi-module/Release/multi" 42)

# An edit propagates.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out CONFIG Debug)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/Debug/diamond" 24)
