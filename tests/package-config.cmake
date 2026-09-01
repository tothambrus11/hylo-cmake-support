# The CMake support can be shipped inside a toolchain as a package config:
# with <root>/lib/cmake/Hylo/{HyloConfig,HyloConfigVersion,FindHylo,HyloTargets}.cmake
# and <root>/bin/hc, `find_package(Hylo 0.0.8 REQUIRED)` works from
# CMAKE_PREFIX_PATH alone, with no CMAKE_MODULE_PATH and no hc on PATH.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
file(REMOVE_RECURSE "${WORK_DIR}")
set(_root "${WORK_DIR}/toolchain")
file(MAKE_DIRECTORY "${_root}/lib/cmake/Hylo")
# Stand in for an installed toolchain by cloning the directory that holds hc
# as <root>/bin (toolchain_clone, Harness.cmake): the bundled standard library
# (Hylo_StandardLibrary.resources) must stay next to the executable -- on
# macOS hc looks it up via its own, unresolved, executable path, so linking
# hc alone would not do.
get_filename_component(_hc_name "${Hylo_COMPILER}" NAME)
toolchain_clone("${_root}/bin")
foreach(_f HyloConfig.cmake HyloConfigVersion.cmake FindHylo.cmake HyloTargets.cmake)
  file(COPY "${SOURCE_DIR}/cmake/${_f}" DESTINATION "${_root}/lib/cmake/Hylo")
endforeach()

file(MAKE_DIRECTORY "${WORK_DIR}/src")
file(COPY "${SOURCE_DIR}/examples/diamond" DESTINATION "${WORK_DIR}/src")
file(WRITE "${WORK_DIR}/src/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.30)
project(PkgConfigFixture LANGUAGES C)
find_package(Hylo 0.0.8 REQUIRED)      # no CMAKE_MODULE_PATH: must come from the prefix
function(add_exit_status_test)
endfunction()
add_subdirectory(diamond)
")
# Note: no -DHylo_COMPILER, and PATH is not consulted for the compiler.
execute_process(COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src" -B "${WORK_DIR}/build" -G "${GENERATOR}"
  "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}" "-DCMAKE_C_COMPILER=${C_COMPILER}" "-DCMAKE_PREFIX_PATH=${_root}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "configure failed:\n${_o}${_e}")
endif()
assert_contains("${_o}" "Found Hylo: ${_root}/bin/${_hc_name}" "hc must be the one from the prefix")
fixture_build(out)
assert_build_ok(out)
assert_exit("${WORK_DIR}/build/diamond/diamond" 23)

# A too-new version requirement is rejected by the version file.
file(MAKE_DIRECTORY "${WORK_DIR}/src-bad")
file(WRITE "${WORK_DIR}/src-bad/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.30)
project(PkgConfigBad LANGUAGES NONE)
find_package(Hylo 99.0 REQUIRED)
")
execute_process(COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src-bad" -B "${WORK_DIR}/build-bad" -G "${GENERATOR}"
  "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}" "-DCMAKE_PREFIX_PATH=${_root}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(_r EQUAL 0)
  message(FATAL_ERROR "find_package(Hylo 99.0) unexpectedly succeeded:\n${_o}")
endif()
assert_contains("${_o}${_e}" "99.0" "version mismatch must be reported")
