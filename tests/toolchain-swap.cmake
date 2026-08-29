# A build tree survives its toolchain moving: configure against a toolchain at
# one path, rename that directory, point Hylo_COMPILER at the new path,
# reconfigure and rebuild.  Every recorded dependency (compiler, stdlib
# sources) must follow the move; anything cached from the old toolchain -- a
# stale stdlib file list, say -- fails the build with missing dependencies.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
fixture_create(diamond)

# A stand-in toolchain: hard links (cheap; the toolchain is big) so that, unlike
# a symlink, hc's own resolved path -- where it finds its bundled stdlib -- is
# inside the stand-in.  Assumes the flat release layout (stdlib next to hc).
get_filename_component(_hc_name "${Hylo_COMPILER}" NAME)
get_filename_component(_hc_src "${Hylo_COMPILER}" DIRECTORY)
set(_tc_a "${WORK_DIR}/tc-a")
set(_tc_b "${WORK_DIR}/tc-b")
file(GLOB_RECURSE _files RELATIVE "${_hc_src}" "${_hc_src}/*")
foreach(_f IN LISTS _files)
  get_filename_component(_d "${_tc_a}/${_f}" DIRECTORY)
  file(MAKE_DIRECTORY "${_d}")
  file(CREATE_LINK "${_hc_src}/${_f}" "${_tc_a}/${_f}" COPY_ON_ERROR)
endforeach()

execute_process(COMMAND "${_tc_a}/${_hc_name}" --print-stdlib-root
  OUTPUT_VARIABLE _stdlib OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE _r)
if(NOT _r EQUAL 0 OR NOT _stdlib MATCHES "^${_tc_a}/")
  # An FHS-installed toolchain (stdlib not next to hc) cannot be cloned this
  # way; the test cannot exercise the move, which is fine to skip.
  message(STATUS "stand-in toolchain reports its stdlib outside itself (${_stdlib}); skipping")
  return()
endif()

fixture_configure(ARGS "-DHylo_COMPILER=${_tc_a}/${_hc_name}")
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# Move the toolchain, reconfigure against the new location, rebuild.
file(RENAME "${_tc_a}" "${_tc_b}")
fixture_configure(ARGS "-DHylo_COMPILER=${_tc_b}/${_hc_name}")
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# Nothing in the build graph may still reference the old location.
if(EXISTS "${WORK_DIR}/build/build.ninja")
  file(READ "${WORK_DIR}/build/build.ninja" _ninja)
  assert_not_contains("${_ninja}" "tc-a" "build graph still references the old toolchain")
endif()
