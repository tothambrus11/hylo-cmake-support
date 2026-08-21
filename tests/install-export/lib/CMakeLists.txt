cmake_minimum_required(VERSION 3.30)
project(Greeting VERSION 1.0 LANGUAGES C)
list(APPEND CMAKE_MODULE_PATH "${HYLO_CMAKE_DIR}")
find_package(Hylo REQUIRED)

hylo_add_library(Greeting SOURCES Greeting.hylo)
hylo_add_library(GreetingCore SOURCES Core.hylo)
target_link_libraries(Greeting PUBLIC GreetingCore)     # PUBLIC: Greeting's users may import Core too

include(GNUInstallDirs)
install(TARGETS Greeting GreetingCore EXPORT GreetingTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR})
hylo_install_module(Greeting)
hylo_install_module(GreetingCore)
install(EXPORT GreetingTargets NAMESPACE Greeting:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Greeting)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/GreetingConfig.cmake"
  "include(\"\${CMAKE_CURRENT_LIST_DIR}/GreetingTargets.cmake\")\n")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/GreetingConfig.cmake" DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/Greeting)
