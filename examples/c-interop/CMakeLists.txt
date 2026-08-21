# Hylo calling C through @extern_c_indirect. foreign.c is just another source
# of the target: CMake compiles it with its C support and links it with the
# module's object. Touching foreign.c rebuilds only the C object; touching a
# .hylo file rebuilds only the module.
hylo_add_executable(c-interop
  MODULE_NAME MainCInterop
  SOURCES main.hylo LibC.hylo foreign.c)

add_exit_status_test(c_interop_exits_13 c-interop 13)
