# Two Hylo modules compiled separately and linked together.
#
# Requires hc --import, --emit-module-to, -L.
hylo_add_library(Support
        MODULE_NAME Support
        SOURCES Support.hylo
        Extra.hylo)
hylo_add_executable(multi
        MODULE_NAME MainMulti
        SOURCES Main.hylo
        IMPORTS Support)

add_exit_status_test(multi_module_exits_42 multi 42)
