# The primitive behind hylo_add_*: attach a Hylo module to a target you created
# yourself. Sources added later with target_sources() are part of the module
# too (the source list is evaluated at generate time), and hc options can be
# attached per target.
add_library(Greeter STATIC)
target_sources(Greeter PRIVATE Greeter.hylo)
hylo_target_module(Greeter)
target_sources(Greeter PRIVATE GreeterExtra.hylo)        # still part of the module
hylo_target_compile_options(Greeter PRIVATE -O)          # hc options, this target only

add_executable(plain-app App.hylo)
hylo_target_module(plain-app MODULE_NAME PlainApp)
target_link_libraries(plain-app PRIVATE Greeter)

add_exit_status_test(plain_targets_exit_7 plain-app 7)
