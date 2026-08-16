# Compiler configuration for the Hylo language.
#
# See Modules/CMakeAddNewLanguage.txt in the CMake source tree.
#
# NOTE ON THE WHOLE-MODULE MISMATCH:
# CMake's compile model is one-object-per-source. hc's model is
# one-object-per-MODULE: it takes every source of a module at once and emits a
# single object. The compile rule below therefore does NOT compile <SOURCE> in
# isolation -- it compiles the whole module. AddHylo.cmake arranges for exactly
# one source per target to reach this rule, and feeds the remaining sources in
# through <FLAGS>. See hylo_add_executable.
#
# <FLAGS> carries --module-name and the module's remaining sources; <SOURCE> is
# the one source CMake chose to hang the module compilation off of.
set(CMAKE_Hylo_COMPILE_OBJECT
  "<CMAKE_Hylo_COMPILER> <FLAGS> --emit object -o <OBJECT> <SOURCE>")

set(CMAKE_Hylo_LINK_EXECUTABLE
  "\"${CMAKE_Hylo_HOST_LINKER}\" <CMAKE_Hylo_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES>")

set(CMAKE_Hylo_CREATE_STATIC_LIBRARY
  "\"${CMAKE_AR}\" qc <TARGET> <OBJECTS>"
  "\"${CMAKE_RANLIB}\" <TARGET>")

set(CMAKE_Hylo_FLAGS_INIT "")
set(CMAKE_Hylo_FLAGS_DEBUG_INIT "")
set(CMAKE_Hylo_FLAGS_RELEASE_INIT "-O")
set(CMAKE_Hylo_FLAGS_RELWITHDEBINFO_INIT "-O")
set(CMAKE_Hylo_FLAGS_MINSIZEREL_INIT "-O")

# The *_INIT variables above are inert on their own: something has to turn them
# into the per-config cache entries (CMAKE_Hylo_FLAGS_RELEASE etc.) that <FLAGS>
# is built from. That is this call. Omitting it silently drops every flag --
# there is no warning, the flags simply never appear on the command line.
cmake_initialize_per_config_variable(CMAKE_Hylo_FLAGS "Flags used by the Hylo compiler")

# Provides CMAKE_EXE_LINKER_FLAGS and friends, honouring $ENV{LDFLAGS}.
include(CMakeCommonLanguageInclude)

set(CMAKE_Hylo_INFORMATION_LOADED 1)
