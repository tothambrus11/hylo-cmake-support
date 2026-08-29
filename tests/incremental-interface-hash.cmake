# Incremental correctness on the diamond (Base <- Left <- App, Base <- Right).
# Soundness assertions (the edited module recompiles, the program behaves like
# a clean build, a second build is a no-op) hold identically forever; which
# *dependents* recompile is branched on probe_hash_precise, so this test needs
# no edits when hc's interface hash becomes precise (hylo-new#321).  Ninja only
# (restat).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
probe_hash_precise(HASH_PRECISE)
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# 1. No-op rebuild.
assert_noop_rebuild("initial build")

# 2. Touch Base.hylo without changing it: Base recompiles, its interface hash
#    is left untouched by hc (write-if-different), restat prunes Left and App.
file(TOUCH_NOCREATE "${WORK_DIR}/src/diamond/Base.hylo")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Base (" "touched Base must recompile")
assert_not_contains("${out}" "Compiling Hylo module Left (" "unchanged interface must not recompile Left")
assert_not_contains("${out}" "Compiling Hylo module MainDiamond (" "unchanged interface must not recompile App")
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_noop_rebuild("after touch")

# 3. Change Base's body (23 -> 24).  Soundness: Base recompiles and the
#    relinked program picks up the new value -- also when dependents are
#    pruned, the case a missing link dependency on the object would break.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Base (" "edited Base must recompile")
if(HASH_PRECISE)
  assert_not_contains("${out}" "Compiling Hylo module Left (" "body-only edit must not recompile Left")
  assert_not_contains("${out}" "Compiling Hylo module MainDiamond (" "body-only edit must not recompile App")
else()
  assert_contains("${out}" "Compiling Hylo module Left (" "conservative hash must recompile Left")
  assert_contains("${out}" "Compiling Hylo module MainDiamond (" "conservative hash must recompile App")
endif()
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
assert_noop_rebuild("after body edit")

# 4. Grow Base's interface (add a public function): Left, which imports it,
#    and App, which links it transitively, must recompile under either hash.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo"
  "public fun base() -> Int32 { 24 }\npublic fun extra() -> Int32 { 1 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Left (" "interface change must recompile importer")
assert_contains("${out}" "Compiling Hylo module MainDiamond (" "interface change must recompile transitive dependent")
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
assert_noop_rebuild("after interface addition")

# 5. Shrink it again (remove the function): same recompiles, asymmetrically.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Left (" "interface removal must recompile importer")
assert_contains("${out}" "Compiling Hylo module MainDiamond (" "interface removal must recompile transitive dependent")
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
assert_noop_rebuild("after interface removal")
