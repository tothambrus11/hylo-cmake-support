# Emits a build-system-agnostic Hylo project manifest (hylo-project.json) that a
# language server can read to learn the module graph, without knowing anything
# about CMake.
#
# WHY THIS EXISTS
#
# An LSP needs, for any file it is asked about: which MODULE the file belongs to,
# the module's other source files, and which modules it imports. That is a
# per-module (not per-source) view -- the same shape rust-analyzer's crate graph
# and rust-project.json use, and NOT the per-source shape of compile_commands.json.
# Hylo compiles a whole module at once, so the module is the unit.
#
# The manifest is a VIEW of the build: each module lists only its .hylo sources.
# A target that also contains Swift or C sources contributes only its Hylo slice
# here; the other languages' servers (SourceKit-LSP, clangd) see their own slices.
# Hylo therefore never has to be the target's "top-level" language.
#
# HOW IT IS POPULATED
#
# AddHylo.cmake's _hylo_configure appends one JSON fragment per module to the
# global property HYLO_MANIFEST_MODULES as it declares targets. Call
# hylo_write_project_manifest() once, at the end of the top-level CMakeLists, to
# serialize them to ${CMAKE_BINARY_DIR}/hylo-project.json.

# Escapes a string for embedding in a JSON string literal: backslash and
# double-quote must be escaped or the manifest is invalid JSON (e.g. a path or
# directory name containing either character).
function(_hylo_json_escape out value)
  string(REPLACE "\\" "\\\\" _v "${value}")
  string(REPLACE "\"" "\\\"" _v "${_v}")
  set(${out} "${_v}" PARENT_SCOPE)
endfunction()

# Records one module in the pending manifest. Called from _hylo_configure.
#   _hylo_manifest_record(<module> <origin-target> <sources-list> <imports-list> <archive-or-empty>)
function(_hylo_manifest_record module origin sources imports archive)
  _hylo_json_escape(module "${module}")
  _hylo_json_escape(origin "${origin}")
  _hylo_json_escape(archive "${archive}")
  # Build JSON arrays by hand -- string(JSON) can read but not easily append to
  # arrays, and hand assembly keeps this readable and dependency-free.
  set(_src_json "")
  foreach(_s IN LISTS sources)
    _hylo_json_escape(_s "${_s}")
    if(_src_json)
      string(APPEND _src_json ",\n")
    endif()
    string(APPEND _src_json "        \"${_s}\"")
  endforeach()

  set(_imp_json "")
  foreach(_i IN LISTS imports)
    _hylo_json_escape(_i "${_i}")
    if(_imp_json)
      string(APPEND _imp_json ", ")
    endif()
    string(APPEND _imp_json "\"${_i}\"")
  endforeach()

  set(_archive_line "")
  if(archive)
    set(_archive_line "      \"archive\": \"${archive}\",\n")
  endif()

  set(_module_json
"    {
      \"name\": \"${module}\",
      \"originTarget\": \"${origin}\",
${_archive_line}      \"imports\": [${_imp_json}],
      \"sources\": [
${_src_json}
      ]
    }")

  set_property(GLOBAL APPEND PROPERTY HYLO_MANIFEST_MODULES "${_module_json}")
endfunction()

# Serializes the recorded modules to <dir>/hylo-project.json (default: the build
# dir). Idempotent; call once after all hylo_add_* calls.
function(hylo_write_project_manifest)
  set(_out "${CMAKE_BINARY_DIR}/hylo-project.json")
  cmake_parse_arguments(_M "" "OUTPUT" "" ${ARGN})
  if(_M_OUTPUT)
    set(_out "${_M_OUTPUT}")
  endif()

  _hylo_json_escape(_stdlib_root "${CMAKE_Hylo_STDLIB_ROOT}")
  _hylo_json_escape(_target "${CMAKE_Hylo_COMPILER_TARGET}")

  get_property(_modules GLOBAL PROPERTY HYLO_MANIFEST_MODULES)

  set(_modules_json "")
  foreach(_m IN LISTS _modules)
    if(_modules_json)
      string(APPEND _modules_json ",\n")
    endif()
    string(APPEND _modules_json "${_m}")
  endforeach()

  # A schemaVersion lets the reader evolve; stdlibRoot and target are the
  # module-independent compiler configuration the LSP would otherwise have to
  # guess. Both come straight from the compiler (see --print-stdlib-root).
  set(_manifest
"{
  \"schemaVersion\": 1,
  \"generator\": \"cmake/HyloProjectManifest.cmake\",
  \"stdlibRoot\": \"${_stdlib_root}\",
  \"target\": \"${_target}\",
  \"modules\": [
${_modules_json}
  ]
}
")

  file(WRITE "${_out}" "${_manifest}")
  message(STATUS "Hylo: wrote project manifest ${_out}")
endfunction()
