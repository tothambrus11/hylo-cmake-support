# A library rebuild that leaves its interface hash unchanged must NOT recompile
# its dependents (they only relink); an interface change must. Ninja only.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# 1. No-op rebuild.
fixture_build(out)
assert_build_ok(out)
assert_not_contains("${out}" "Compiling Hylo module" "no-op rebuild compiled something")

# 2. Touch Base.hylo without changing it: Base recompiles, its interface hash is
#    left untouched by hc (write-if-different), restat prunes Left and App.
file(TOUCH_NOCREATE "${WORK_DIR}/src/diamond/Base.hylo")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Base (" "touched Base must recompile")
assert_not_contains("${out}" "Compiling Hylo module Left (" "unchanged interface must not recompile Left")
assert_not_contains("${out}" "Compiling Hylo module MainDiamond (" "unchanged interface must not recompile App")
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# 3. Change Base's body (23 -> 24). Whether Left/App recompile depends on how
#    precise hc's interface hash is (today it hashes the whole archive, so they
#    do); either way the program must pick up the new value.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo" "public fun base() -> Int32 { 24 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Base (" "edited Base must recompile")
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)

# 4. Change Base's interface (add a public function): Left, which imports it,
#    and App, which links it transitively, must recompile.
file(WRITE "${WORK_DIR}/src/diamond/Base.hylo"
  "public fun base() -> Int32 { 24 }\npublic fun extra() -> Int32 { 1 }\n")
fixture_build(out)
assert_build_ok(out)
assert_contains("${out}" "Compiling Hylo module Left (" "interface change must recompile importer")
assert_contains("${out}" "Compiling Hylo module MainDiamond (" "interface change must recompile transitive dependent")
assert_exit("${WORK_DIR}/build/diamond/diamond" 24)
