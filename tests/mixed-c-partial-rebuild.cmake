# In a target mixing C and Hylo sources, touching a C file rebuilds only the C
# object, and touching a .hylo file rebuilds only the module.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(c-interop)
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/c-interop/c-interop" 13)
assert_noop_rebuild("initial build")

file(TOUCH_NOCREATE "${WORK_DIR}/src/c-interop/foreign.c")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "foreign.c" "touched C source must recompile")
assert_not_contains("${out}" "${HYLO_COMPILE_MESSAGE}" "C edit must not recompile the Hylo module")
assert_noop_rebuild("after C touch")

file(TOUCH_NOCREATE "${WORK_DIR}/src/c-interop/LibC.hylo")
fixture_build(out)
assert_build_ok(out)
assert_compiled("${out}" MainCInterop "touched Hylo source must recompile the module")
assert_not_contains("${out}" "Building C object" "Hylo edit must not recompile C")
assert_noop_rebuild("after Hylo touch")

# Negative control for the C object really being the one linked: perturb the C
# implementation of Point addition (r = p + q; result uses r.x) and the exit
# status must follow: 13 -> 113.
file(READ "${WORK_DIR}/src/c-interop/foreign.c" _c)
string(REPLACE "result->x = a->x + b->x;" "result->x = a->x + b->x + 100;" _c "${_c}")
file(WRITE "${WORK_DIR}/src/c-interop/foreign.c" "${_c}")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "foreign.c" "edited C source must recompile")
assert_not_contains("${out}" "${HYLO_COMPILE_MESSAGE}" "C edit must not recompile the Hylo module")
assert_exit("${WORK_DIR}/build/c-interop/c-interop" 113)
assert_noop_rebuild("after C edit")
