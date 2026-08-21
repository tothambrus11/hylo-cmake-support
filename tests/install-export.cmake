# A Hylo library installed with install(TARGETS ... EXPORT) + hylo_install_module
# can be consumed from a separate project through find_package: the exported
# target carries the module's import name, installed archive directory and
# interface-hash file.
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(_prefix "${WORK_DIR}/prefix")
set(_common "-DHylo_COMPILER=${Hylo_COMPILER}" "-DCMAKE_C_COMPILER=${C_COMPILER}"
  "-DHYLO_CMAKE_DIR=${SOURCE_DIR}/cmake" "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}")

execute_process(COMMAND "${CMAKE_COMMAND}" -S "${SOURCE_DIR}/tests/install-export/lib" -B "${WORK_DIR}/lib-build"
  -G "${GENERATOR}" ${_common} "-DCMAKE_INSTALL_PREFIX=${_prefix}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "lib configure failed:\n${_o}${_e}")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" --build "${WORK_DIR}/lib-build" --target install
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "lib build/install failed:\n${_o}${_e}")
endif()
assert_exists("${_prefix}/lib/hylo/Greeting.hylomodule" "archive not installed")
assert_exists("${_prefix}/lib/hylo/Greeting.iface" "interface hash not installed")
assert_exists("${_prefix}/lib/cmake/Greeting/GreetingTargets.cmake" "export file not installed")
file(READ "${_prefix}/lib/cmake/Greeting/GreetingTargets.cmake" _export)
assert_contains("${_export}" "INTERFACE_HYLO_IMPORTS \"Greeting\"" "export must carry the module name")
assert_contains("${_export}" "\${_IMPORT_PREFIX}/lib/hylo" "export must carry the installed search path")
assert_not_contains("${_export}" "hylo-runtime" "export must not reference the build-tree runtime target")

# The consumer sees nothing of the library's build tree.
file(REMOVE_RECURSE "${WORK_DIR}/lib-build")
execute_process(COMMAND "${CMAKE_COMMAND}" -S "${SOURCE_DIR}/tests/install-export/consumer" -B "${WORK_DIR}/consumer-build"
  -G "${GENERATOR}" ${_common} "-DCMAKE_PREFIX_PATH=${_prefix}"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "consumer configure failed:\n${_o}${_e}")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" --build "${WORK_DIR}/consumer-build"
  RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
if(NOT _r EQUAL 0)
  message(FATAL_ERROR "consumer build failed:\n${_o}${_e}")
endif()
assert_exit("${WORK_DIR}/consumer-build/consumer" 62)
