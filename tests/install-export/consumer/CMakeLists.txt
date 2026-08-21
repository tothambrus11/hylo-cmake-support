cmake_minimum_required(VERSION 3.30)
project(Consumer LANGUAGES C)
list(APPEND CMAKE_MODULE_PATH "${HYLO_CMAKE_DIR}")
find_package(Hylo REQUIRED)
find_package(Greeting REQUIRED)          # the installed package from ../lib

hylo_add_executable(consumer SOURCES main.hylo)
target_link_libraries(consumer PRIVATE Greeting::Greeting)
