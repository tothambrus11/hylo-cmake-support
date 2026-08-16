# Helpers for declaring Hylo targets.
#
# WHY A WRAPPER IS NEEDED
#
# You cannot just write add_executable(foo a.hylo b.hylo). CMake would emit one
# compile command per source, and each one would compile the WHOLE module
# (because that is all hc can do), producing N identical objects that then
# collide at link time with duplicate symbols.
#
# So we let exactly one source -- the first -- carry the module compilation, and
# mark the rest HEADER_FILE_ONLY so CMake keeps them in the target (they still
# show up in IDEs) but never compiles them. The remaining sources are handed to
# the compile rule through source-level COMPILE_OPTIONS, and listed in
# OBJECT_DEPENDS so that editing any of them still triggers a rebuild.
#
# Upstream CMake does the same "first source is the aggregation point" thing for
# Rust (SourceKindRustMainCrateRoot), but with a real classification and an
# override property. See UPSTREAM-MULTIFILE-MODULES.md.

# Where module archives (.hylomodule) are published so importers can find them
# with a single -I (the module search path, distinct from -L which locates native
# libraries for the linker).
set(HYLO_MODULE_DIR "${CMAKE_BINARY_DIR}/hylo-modules"
  CACHE INTERNAL "Directory of published Hylo module archives")
file(MAKE_DIRECTORY "${HYLO_MODULE_DIR}")

# _hylo_configure(<target> <module-name> <sources...> IMPORTS <targets...>)
#
# Shared by hylo_add_library and hylo_add_executable. Sets up the whole-module
# compile on the first .hylo source and returns the non-Hylo sources.
function(_hylo_configure target module hylo_srcs other_srcs imports publish)
  list(GET hylo_srcs 0 _first)
  set(_rest ${hylo_srcs})
  list(REMOVE_AT _rest 0)

  set(_archive "${HYLO_MODULE_DIR}/${module}.hylomodule")

  # --module-name states the module identity instead of letting hc infer it from
  # the shape of the input list. -I points hc at the directory of published module
  # archives so `--import` can resolve dependencies there.
  set(_opts "--module-name" "${module}" "-I" "${HYLO_MODULE_DIR}")

  # Only libraries publish an archive. Nothing can import an executable's module,
  # and publishing one would collide in the shared module directory whenever two
  # executables use the same module name (e.g. the conventional "Main").
  if(publish)
    list(APPEND _opts "--emit-module-to" "${_archive}")
  endif()

  # Each import contributes "--import <ModuleName>"; -I above covers the search
  # path. The importer must ALSO say `import <M>` in its source -- the flag only
  # makes the module available, mirroring rustc's --extern.
  set(_import_archives)
  set(imports_module_names)
  foreach(_dep IN LISTS imports)
    if(NOT TARGET ${_dep})
      message(FATAL_ERROR "hylo: IMPORTS ${_dep} is not a target")
    endif()
    get_target_property(_dep_module ${_dep} HYLO_MODULE_NAME)
    if(NOT _dep_module)
      message(FATAL_ERROR "hylo: IMPORTS ${_dep} is not a Hylo module target")
    endif()
    list(APPEND _opts "--import" "${_dep_module}")
    list(APPEND _import_archives "${HYLO_MODULE_DIR}/${_dep_module}.hylomodule")
    list(APPEND imports_module_names "${_dep_module}")
  endforeach()

  list(APPEND _opts ${_rest})
  set_source_files_properties(${_first} PROPERTIES COMPILE_OPTIONS "${_opts}")

  # The archive is a real output of this compile edge. Without OBJECT_OUTPUTS,
  # the generator would not know the compile produces it, and importers could
  # race against a missing/stale .hylomodule.
  if(publish)
    set_source_files_properties(${_first} PROPERTIES OBJECT_OUTPUTS "${_archive}")
  endif()

  # Rebuild when any other source of this module changes, and when any imported
  # module's interface changes. The latter is what orders the module graph.
  set(_depends ${_rest} ${_import_archives})
  if(_depends)
    set_source_files_properties(${_first} PROPERTIES OBJECT_DEPENDS "${_depends}")
  endif()

  set_target_properties(${target} PROPERTIES
    LINKER_LANGUAGE Hylo
    HYLO_MODULE_NAME "${module}"
    HYLO_MODULE_ARCHIVE "${_archive}")

  # Record this module in the LSP-facing project manifest. Note we pass the FULL
  # .hylo source list (first + rest), the imported MODULE names, and -- only for
  # libraries -- the published archive path. The manifest is a per-module view;
  # the target's non-Hylo sources (other_srcs) are deliberately omitted.
  set(_manifest_archive "")
  if(publish)
    set(_manifest_archive "${_archive}")
  endif()
  set(_all_hylo ${_first} ${_rest})
  _hylo_manifest_record(
    "${module}" "${target}" "${_all_hylo}" "${imports_module_names}" "${_manifest_archive}")
endfunction()

# Splits sources into .hylo and everything else, absolutising both.
function(_hylo_partition_sources out_hylo out_other)
  set(_hylo)
  set(_other)
  foreach(_s IN LISTS ARGN)
    get_filename_component(_a "${_s}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(_a MATCHES "\\.hylo$")
      list(APPEND _hylo "${_a}")
    else()
      list(APPEND _other "${_a}")
    endif()
  endforeach()
  set(${out_hylo} "${_hylo}" PARENT_SCOPE)
  set(${out_other} "${_other}" PARENT_SCOPE)
endfunction()

# hylo_add_library(<target> MODULE_NAME <name> SOURCES <srcs>... [IMPORTS <targets>...])
#
# Builds one Hylo module as a static library, and publishes <name>.hylomodule so
# other modules can import it. Non-.hylo sources are compiled by CMake's own
# language support and archived alongside.
function(hylo_add_library target)
  cmake_parse_arguments(PARSE_ARGV 1 _H "" "MODULE_NAME" "SOURCES;IMPORTS")
  if(NOT _H_SOURCES)
    message(FATAL_ERROR "hylo_add_library(${target}): no SOURCES given")
  endif()
  set(_module "${_H_MODULE_NAME}")
  if(NOT _module)
    set(_module "${target}")
  endif()

  _hylo_partition_sources(_hylo _other ${_H_SOURCES})
  if(NOT _hylo)
    message(FATAL_ERROR "hylo_add_library(${target}): no .hylo SOURCES given")
  endif()

  add_library(${target} STATIC ${_hylo} ${_other})
  _hylo_configure(${target} "${_module}" "${_hylo}" "${_other}" "${_H_IMPORTS}" TRUE)

  list(REMOVE_AT _hylo 0)
  if(_hylo)
    set_source_files_properties(${_hylo} PROPERTIES HEADER_FILE_ONLY TRUE)
  endif()

  if(_H_IMPORTS)
    target_link_libraries(${target} PUBLIC ${_H_IMPORTS})
  endif()
endfunction()

# hylo_add_executable(<target> MODULE_NAME <name> SOURCES <srcs>...
#                     [IMPORTS <targets>...] [NO_STDLIB_SHIMS])
#
# The standard library's C shim is added automatically (it implements the
# @extern_c_indirect functions the stdlib declares), mirroring what
# `hc --emit binary` does internally.
function(hylo_add_executable target)
  cmake_parse_arguments(PARSE_ARGV 1 _H "NO_STDLIB_SHIMS" "MODULE_NAME" "SOURCES;IMPORTS")

  # Tolerate the terse form: hylo_add_executable(foo a.hylo b.hylo)
  if(NOT _H_SOURCES)
    set(_H_SOURCES ${_H_UNPARSED_ARGUMENTS})
  endif()
  if(NOT _H_SOURCES)
    message(FATAL_ERROR "hylo_add_executable(${target}): no sources given")
  endif()

  set(_module "${_H_MODULE_NAME}")
  if(NOT _module)
    set(_module "${target}")
  endif()

  _hylo_partition_sources(_hylo _other ${_H_SOURCES})
  if(NOT _hylo)
    message(FATAL_ERROR "hylo_add_executable(${target}): no .hylo sources given")
  endif()

  if(NOT _H_NO_STDLIB_SHIMS)
    if(NOT CMAKE_Hylo_STDLIB_SHIMS)
      message(FATAL_ERROR
        "hylo_add_executable(${target}): the Hylo stdlib shim (shims.c) was not found. "
        "Set CMAKE_Hylo_STDLIB_SHIMS, or pass NO_STDLIB_SHIMS if this program does not need it.")
    endif()
    list(APPEND _other "${CMAKE_Hylo_STDLIB_SHIMS}")
  endif()

  add_executable(${target} ${_hylo} ${_other})
  _hylo_configure(${target} "${_module}" "${_hylo}" "${_other}" "${_H_IMPORTS}" FALSE)

  list(REMOVE_AT _hylo 0)
  if(_hylo)
    set_source_files_properties(${_hylo} PROPERTIES HEADER_FILE_ONLY TRUE)
  endif()

  if(_H_IMPORTS)
    target_link_libraries(${target} PRIVATE ${_H_IMPORTS})
  endif()
endfunction()
