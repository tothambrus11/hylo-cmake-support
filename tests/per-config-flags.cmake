# Hylo_FLAGS_<CONFIG> reach hc: Release builds pass -O, Debug builds do not,
# and hylo_target_compile_options adds per-target options.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond plain-targets)

fixture_configure(BUILD_DIR "${WORK_DIR}/debug" ARGS -DCMAKE_BUILD_TYPE=Debug)
fixture_build(out BUILD_DIR "${WORK_DIR}/debug" ARGS --verbose)
assert_build_ok(out)
hc_command(_base_cmd Base "${out}")
assert_not_contains("${_base_cmd}" " -O " "Debug build must not optimize")
hc_command(_greeter_cmd Greeter "${out}")
assert_contains("${_greeter_cmd}" " -O " "hylo_target_compile_options(PRIVATE -O) missing")

fixture_configure(BUILD_DIR "${WORK_DIR}/release" ARGS -DCMAKE_BUILD_TYPE=Release)
fixture_build(out BUILD_DIR "${WORK_DIR}/release" ARGS --verbose)
assert_build_ok(out)
hc_command(_base_cmd Base "${out}")
assert_contains("${_base_cmd}" " -O " "Release build must pass -O")
assert_exit("${WORK_DIR}/release/diamond/diamond" 23)

# Hylo_FLAGS applies everywhere; here an option hc accepts and that is visible
# on the command line.
fixture_configure(BUILD_DIR "${WORK_DIR}/flags" ARGS -DCMAKE_BUILD_TYPE=Debug "-DHylo_FLAGS=--cpu generic")
fixture_build(out BUILD_DIR "${WORK_DIR}/flags" ARGS --verbose)
assert_build_ok(out)
hc_command(_base_cmd Base "${out}")
assert_contains("${_base_cmd}" "--cpu generic" "Hylo_FLAGS must reach hc")
assert_exit("${WORK_DIR}/flags/diamond/diamond" 23)
