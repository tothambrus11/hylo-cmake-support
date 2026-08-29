# The smallest Hylo program CMake can build: one executable, one module, two
# source files. Both files belong to one module, hc compiles them together,
# and cross-file references resolve. Exits 42.
hylo_add_executable(hello
  MODULE_NAME Hello
  SOURCES main.hylo support.hylo)

add_exit_status_test(hello_exits_42 hello 42)
