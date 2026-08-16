# Test that the Hylo compiler works.
#
# See Modules/CMakeAddNewLanguage.txt in the CMake source tree.

if(CMAKE_Hylo_COMPILER_WORKS)
  return()
endif()

# We deliberately do NOT use try_compile() here.
#
# try_compile() generates a throwaway project that calls enable_language(Hylo),
# which in turn needs CMakeDetermineHyloCompiler.cmake et al. on its module
# path. try_compile does not propagate CMAKE_MODULE_PATH into that project, so
# the generated project cannot find our language definition and configuration
# fails. Propagating it requires either CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
# plumbing that is itself internal API, or upstream support. This is a real
# rough edge for out-of-tree languages -- see FINDINGS.md.
#
# Instead we compile a trivial module directly with execute_process.

set(_test_dir "${CMAKE_PLATFORM_INFO_DIR}/HyloCompilerTest")
file(REMOVE_RECURSE "${_test_dir}")
file(MAKE_DIRECTORY "${_test_dir}")

set(_test_src "${_test_dir}/CMakeHyloCompilerTest.hylo")
file(WRITE "${_test_src}" "public fun main() -> Int32 {\n  0\n}\n")

execute_process(
  COMMAND "${CMAKE_Hylo_COMPILER}"
    --module-name CMakeHyloCompilerTest
    --emit object "${_test_src}" -o "${_test_dir}/CMakeHyloCompilerTest.o"
  RESULT_VARIABLE _hylo_test_result
  OUTPUT_VARIABLE _hylo_test_output
  ERROR_VARIABLE _hylo_test_output)

if(NOT _hylo_test_result EQUAL 0)
  message(FATAL_ERROR
    "The Hylo compiler\n  \"${CMAKE_Hylo_COMPILER}\"\n"
    "is not able to compile a simple test program.\nIt fails with the following output:\n"
    "${_hylo_test_output}\n")
endif()

message(STATUS "Check for working Hylo compiler: ${CMAKE_Hylo_COMPILER} -- works")
set(CMAKE_Hylo_COMPILER_WORKS 1 CACHE INTERNAL "")
