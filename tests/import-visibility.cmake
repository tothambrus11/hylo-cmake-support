# Module visibility follows target_link_libraries: a module is importable only
# by targets that link its library (directly, or through a PUBLIC link), and a
# PRIVATE dependency is not re-exported. hc enforces this (`import X` needs
# `--import X`), so the CMake rules must produce exactly the right flags.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)

# App links Left only; Left's dependency on Base is PRIVATE. Importing Base from
# App must therefore fail at compile time...
file(WRITE "${WORK_DIR}/src/diamond/App.hylo"
  "import Left\nimport Base\npublic fun main() -> Int32 { left() + base() }\n")
fixture_configure()
fixture_build(out)
assert_build_fails(out)
assert_contains("${out}" "undefined module 'Base'" "PRIVATE dependency leaked to a dependent")

# ...and succeed once Left's link to Base is PUBLIC.
file(READ "${WORK_DIR}/src/diamond/CMakeLists.txt" _cm)
string(REPLACE "target_link_libraries(Left  PRIVATE Base)" "target_link_libraries(Left PUBLIC Base)" _cm "${_cm}")
file(WRITE "${WORK_DIR}/src/diamond/CMakeLists.txt" "${_cm}")
fixture_configure()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 46)

# A module that is not linked at all is not importable even if it is built in
# the same project.
file(WRITE "${WORK_DIR}/src/diamond/App.hylo"
  "import Right\npublic fun main() -> Int32 { right() }\n")
fixture_build(out)
assert_build_fails(out)
assert_contains("${out}" "undefined module 'Right'" "unlinked module must not be importable")
