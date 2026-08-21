# Package configuration file for Hylo, for shipping the CMake support inside a
# toolchain so that
#
#   find_package(Hylo REQUIRED)          # with CMAKE_PREFIX_PATH=<toolchain root>
#
# needs no CMAKE_MODULE_PATH. Install this file, HyloConfigVersion.cmake,
# FindHylo.cmake and HyloTargets.cmake together into
# <root>/lib/cmake/Hylo/ (or <root>/cmake/Hylo/, <root>/share/cmake/Hylo/).
#
# It locates hc relative to itself, then defers to FindHylo.cmake, which does
# all the work and defines the same variables, targets and commands. An explicit
# Hylo_COMPILER always wins.

if(NOT Hylo_COMPILER)
  set(_hylo_config_root "${CMAKE_CURRENT_LIST_DIR}")
  set(_hylo_candidates)
  foreach(_up IN ITEMS 1 2 3)
    get_filename_component(_hylo_config_root "${_hylo_config_root}" DIRECTORY)
    # <root>/bin/hc (FHS layout) and <root>/hc (flat release tarball layout).
    list(APPEND _hylo_candidates
      "${_hylo_config_root}/bin/hc${CMAKE_EXECUTABLE_SUFFIX}"
      "${_hylo_config_root}/hc${CMAKE_EXECUTABLE_SUFFIX}")
  endforeach()
  foreach(_c IN LISTS _hylo_candidates)
    if(EXISTS "${_c}")
      set(Hylo_COMPILER "${_c}" CACHE FILEPATH "Hylo compiler (hc)")
      break()
    endif()
  endforeach()
  unset(_hylo_candidates)
  unset(_hylo_config_root)
endif()

# find_package(... CONFIG) sets <Pkg>_FIND_* just like the module path does, so
# FindHylo's version handling and FPHSA apply unchanged.
include("${CMAKE_CURRENT_LIST_DIR}/FindHylo.cmake")
