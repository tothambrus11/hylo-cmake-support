# The .hylomodule archive and interface hash are real outputs of the compile
# edge: deleting one must make the build regenerate it (the earlier language
# module integration could only declare them as phony aliases of the object).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
fixture_configure()
fixture_build(out)
assert_build_ok(out)

set(_dir "${WORK_DIR}/build/diamond/CMakeFiles/Base.hylo.dir")
file(REMOVE "${_dir}/Base.hylomodule")
fixture_build(out)
assert_build_ok(out)
assert_compiled("${out}" Base "deleted archive must trigger recompile")
assert_exists("${_dir}/Base.hylomodule" "archive not regenerated")
assert_noop_rebuild("after archive regeneration")

file(REMOVE "${_dir}/Base.iface")
fixture_build(out)
assert_build_ok(out)
assert_exists("${_dir}/Base.iface" "interface hash file not regenerated")
assert_noop_rebuild("after interface-hash regeneration")

# And `clean` removes them like any other output.
fixture_build(out ARGS --target clean)
assert_build_ok(out)
if(EXISTS "${_dir}/Base.hylomodule" OR EXISTS "${_dir}/Base${HYLO_OBJ_EXT}")
  message(FATAL_ERROR "clean left module outputs behind")
endif()
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)
assert_noop_rebuild("after clean and full rebuild")
