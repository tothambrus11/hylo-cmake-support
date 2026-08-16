# Locate the Hylo compiler (hc) and configure CMakeHyloCompiler.cmake.
#
# See Modules/CMakeAddNewLanguage.txt in the CMake source tree.

if(NOT CMAKE_Hylo_COMPILER)
  find_program(CMAKE_Hylo_COMPILER
    NAMES hc
    HINTS ENV HYLO_ROOT
    PATH_SUFFIXES release
    DOC "Hylo compiler (hc)")
endif()

if(NOT CMAKE_Hylo_COMPILER)
  message(FATAL_ERROR "Could not find the Hylo compiler 'hc'. "
    "Set CMAKE_Hylo_COMPILER or add it to PATH.")
endif()

mark_as_advanced(CMAKE_Hylo_COMPILER)

set(CMAKE_Hylo_SOURCE_FILE_EXTENSIONS hylo)
set(CMAKE_Hylo_OUTPUT_EXTENSION .o)
set(CMAKE_Hylo_COMPILER_ENV_VAR "HC")

# hc has no --version flag, so there is no reliable version to report.
# See FINDINGS.md: "hc exposes no version".
set(CMAKE_Hylo_COMPILER_ID "Hylo")
set(CMAKE_Hylo_COMPILER_VERSION "unknown")

# The linker used to turn Hylo objects into executables. hc shells out to
# clang internally (Driver.swift), so we use clang directly here.
if(NOT CMAKE_Hylo_HOST_LINKER)
  find_program(CMAKE_Hylo_HOST_LINKER NAMES clang cc gcc DOC "Linker for Hylo targets")
endif()
mark_as_advanced(CMAKE_Hylo_HOST_LINKER)

# The standard library's C shim (shims.c) implements the @extern_c_indirect
# functions the stdlib declares -- c_malloc_indirect, c_free_indirect. Any Hylo
# program that allocates needs it linked in.
#
# `hc --emit binary` appends this file to its own link line automatically
# (Driver.generateExecutable). When we link ourselves -- which is what any build
# system integration does -- we have to supply it. The stdlib location is baked
# into the compiler at build time (#filePath, or a resource bundle when built
# with USE_BUNDLED_STANDARD_LIBRARY), so the compiler is the only thing that
# knows where it is. Ask it.
if(NOT CMAKE_Hylo_STDLIB_ROOT)
  execute_process(
    COMMAND "${CMAKE_Hylo_COMPILER}" --print-stdlib-root
    OUTPUT_VARIABLE _hylo_stdlib_root
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_VARIABLE _hylo_stdlib_root_error
    RESULT_VARIABLE _hylo_stdlib_root_result)

  if(NOT _hylo_stdlib_root_result EQUAL 0)
    message(FATAL_ERROR
      "The Hylo compiler\n  \"${CMAKE_Hylo_COMPILER}\"\n"
      "does not support --print-stdlib-root, so the standard library cannot be located.\n"
      "It fails with:\n${_hylo_stdlib_root_error}\n"
      "Use a newer hc, or set CMAKE_Hylo_STDLIB_ROOT explicitly.")
  endif()

  set(CMAKE_Hylo_STDLIB_ROOT "${_hylo_stdlib_root}"
    CACHE PATH "Root directory of the Hylo standard library's sources")
endif()

if(NOT CMAKE_Hylo_STDLIB_SHIMS)
  set(CMAKE_Hylo_STDLIB_SHIMS "${CMAKE_Hylo_STDLIB_ROOT}/shims.c"
    CACHE FILEPATH "Hylo standard library C shim")
endif()

if(NOT EXISTS "${CMAKE_Hylo_STDLIB_SHIMS}")
  message(FATAL_ERROR
    "The Hylo standard library C shim was not found at\n  \"${CMAKE_Hylo_STDLIB_SHIMS}\"\n"
    "(standard library root reported as \"${CMAKE_Hylo_STDLIB_ROOT}\").")
endif()

mark_as_advanced(CMAKE_Hylo_STDLIB_ROOT CMAKE_Hylo_STDLIB_SHIMS)

configure_file(
  ${CMAKE_CURRENT_LIST_DIR}/CMakeHyloCompiler.cmake.in
  ${CMAKE_PLATFORM_INFO_DIR}/CMakeHyloCompiler.cmake
  @ONLY)
