# Sources added with target_sources() AFTER hylo_target_module() are part of
# the module, and removing a source from the module is detected at generate
# time (the source list is a generator expression, not a snapshot).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(plain-targets)
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/plain-targets/plain-app" 7)

# GreeterExtra.hylo was added after hylo_target_module(); it must be an input.
file(WRITE "${WORK_DIR}/src/plain-targets/GreeterExtra.hylo" "public fun bonus() -> Int32 { 9 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Greeter (" "late-added source must be a module input")
assert_exit("${WORK_DIR}/build/plain-targets/plain-app" 9)
