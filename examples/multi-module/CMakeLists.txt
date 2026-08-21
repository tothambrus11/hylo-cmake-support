# Two Hylo modules compiled separately and linked together.
#
# Support publishes Support.hylomodule; `target_link_libraries` is all that is
# needed for `multi` to import it: linking a Hylo library target adds
# `--import=Support` to the dependent's compile, puts the archive on the module
# search path, and makes the compile depend on Support's interface hash.
hylo_add_library(Support
  SOURCES Support.hylo Extra.hylo)

hylo_add_executable(multi
  MODULE_NAME MainMulti
  SOURCES Main.hylo)
target_link_libraries(multi PRIVATE Support)

add_exit_status_test(multi_module_exits_42 multi 42)
