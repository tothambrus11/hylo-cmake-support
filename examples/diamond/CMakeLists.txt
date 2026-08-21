# A diamond module graph: Base <- Left, Base <- Right, Left <- App.
#
# App only links Left. Left's dependency on Base is PRIVATE, so App does not get
# `--import=Base` (it could not name Base's declarations without importing it),
# but Base's archive directory and interface hash still reach App through the
# link closure: hc resolves Base transitively by reading Left.hylomodule's
# dependency header, and App recompiles if Base's interface changes.

hylo_add_library(Base  SOURCES Base.hylo)
hylo_add_library(Left  SOURCES Left.hylo)
hylo_add_library(Right SOURCES Right.hylo)
target_link_libraries(Left  PRIVATE Base)
target_link_libraries(Right PUBLIC  Base)

hylo_add_executable(diamond
  MODULE_NAME MainDiamond
  SOURCES App.hylo)
target_link_libraries(diamond PRIVATE Left)

add_exit_status_test(diamond_exits_23 diamond 23)
