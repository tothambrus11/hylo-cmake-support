# Changing hc flags must recompile the affected modules: the flags live on the
# custom command's command line, which Ninja hashes -- a flag routed through a
# response file or the environment would silently break this.  Ninja only.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
fixture_configure(ARGS -DCMAKE_BUILD_TYPE=Debug)
fixture_build(out)
assert_build_ok(out)

# A configuration-wide flag change recompiles every module.
fixture_configure(ARGS -DCMAKE_BUILD_TYPE=Debug "-DHylo_FLAGS=--cpu generic")
fixture_build(out)
assert_build_ok(out)
assert_compiled("${out}" Base "global flag change must recompile Base")
assert_compiled("${out}" MainDiamond "global flag change must recompile App")
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_noop_rebuild("after global flag change")

# A per-target option recompiles that target's module only.
file(READ "${WORK_DIR}/src/diamond/CMakeLists.txt" _cm)
string(APPEND _cm "\nhylo_target_compile_options(Left PRIVATE -O)\n")
file(WRITE "${WORK_DIR}/src/diamond/CMakeLists.txt" "${_cm}")
fixture_build(out)   # cmake --build reruns the generate step itself
assert_build_ok(out)
assert_compiled("${out}" Left "per-target option change must recompile Left")
assert_not_compiled("${out}" Base "unrelated module must not recompile")
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_noop_rebuild("after per-target option change")
