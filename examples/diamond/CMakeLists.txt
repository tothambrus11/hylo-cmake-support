# A diamond module graph: Base <- Left, Base <- Right, Left <- App.
#
# App only IMPORTS Left directly; hc resolves Base transitively by reading
# Left.hylomodule's dependency header. The build declares only DIRECT edges
# and CMake's transitive target_link_libraries carries the objects to the link.

hylo_add_library(Base  MODULE_NAME Base  SOURCES Base.hylo)
hylo_add_library(Left  MODULE_NAME Left  SOURCES Left.hylo  IMPORTS Base)
hylo_add_library(Right MODULE_NAME Right SOURCES Right.hylo IMPORTS Base)
hylo_add_executable(diamond
        MODULE_NAME MainDiamond
        SOURCES App.hylo
        IMPORTS Left)

add_exit_status_test(diamond_exits_23 diamond 23)
