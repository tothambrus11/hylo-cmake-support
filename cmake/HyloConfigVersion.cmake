# Version file for the Hylo package configuration: reports the version of the
# hc found next to this file (see HyloConfig.cmake for the layouts searched),
# so `find_package(Hylo 0.0.8)` can be checked before HyloConfig.cmake runs.
# A compiler that reports a non-numeric version ("development") is accepted for
# any requested version.

set(_hylo_root "${CMAKE_CURRENT_LIST_DIR}")
set(PACKAGE_VERSION "")
foreach(_up IN ITEMS 1 2 3)
  get_filename_component(_hylo_root "${_hylo_root}" DIRECTORY)
  foreach(_c IN ITEMS "${_hylo_root}/bin/hc${CMAKE_EXECUTABLE_SUFFIX}" "${_hylo_root}/hc${CMAKE_EXECUTABLE_SUFFIX}")
    if(EXISTS "${_c}")
      execute_process(COMMAND "${_c}" --version
        OUTPUT_VARIABLE PACKAGE_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
      break()
    endif()
  endforeach()
  if(PACKAGE_VERSION)
    break()
  endif()
endforeach()

if(PACKAGE_VERSION MATCHES "^v?([0-9]+(\\.[0-9]+)*)")
  set(PACKAGE_VERSION "${CMAKE_MATCH_1}")
  if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
  else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
      set(PACKAGE_VERSION_EXACT TRUE)
    endif()
  endif()
else()
  # Unknown or "development": let HyloConfig/FindHylo decide.
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
endif()
unset(_hylo_root)
