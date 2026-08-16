hylo_add_executable(c-interop
        MODULE_NAME MainCInterop
        main.hylo
        LibC.hylo
        foreign.c)

add_exit_status_test(c_interop_exits_13 c-interop 13)
