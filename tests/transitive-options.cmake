# hylo_target_compile_options propagation through target_link_libraries
# (TRANSITIVE_COMPILE_PROPERTIES): PUBLIC reaches the target itself and every
# direct dependent; INTERFACE reaches dependents only; neither crosses a
# PRIVATE link (App links Left PRIVATE, Left links Base PRIVATE, so nothing of
# Base's interface reaches App).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)
file(READ "${WORK_DIR}/src/diamond/CMakeLists.txt" _cm)
string(APPEND _cm "
hylo_target_compile_options(Base PUBLIC --cpu generic)
hylo_target_compile_options(Base INTERFACE -O)
")
file(WRITE "${WORK_DIR}/src/diamond/CMakeLists.txt" "${_cm}")

fixture_configure(ARGS -DCMAKE_BUILD_TYPE=Debug)
fixture_build(out ARGS --verbose)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

hc_command(_cmd Base "${out}")
assert_contains("${_cmd}" "--cpu generic" "PUBLIC option missing on the target itself")
assert_not_contains("${_cmd}" " -O " "INTERFACE option must not apply to the target itself")

hc_command(_cmd Left "${out}")   # links Base PRIVATE: still a direct dependent
assert_contains("${_cmd}" "--cpu generic" "PUBLIC option missing on a direct dependent")
assert_contains("${_cmd}" " -O " "INTERFACE option missing on a direct dependent")

hc_command(_cmd Right "${out}")  # links Base PUBLIC
assert_contains("${_cmd}" "--cpu generic" "PUBLIC option missing on a PUBLIC dependent")
assert_contains("${_cmd}" " -O " "INTERFACE option missing on a PUBLIC dependent")

hc_command(_cmd MainDiamond "${out}")  # reaches Base only through PRIVATE links
assert_not_contains("${_cmd}" "--cpu generic" "option must not cross a PRIVATE link")
assert_not_contains("${_cmd}" " -O " "INTERFACE option must not cross a PRIVATE link")
