# hylo-cmake-support

CMake support for the [Hylo](https://github.com/hylo-lang/hylo-new) programming
language, plus the research notes behind it.

```cmake
find_package(Hylo 0.0.6 REQUIRED)                  # cmake/FindHylo.cmake on CMAKE_MODULE_PATH
hylo_add_library(Support SOURCES Support.hylo Extra.hylo)
hylo_add_executable(app   SOURCES main.hylo)
target_link_libraries(app PRIVATE Support)         # links and imports the module
```

- **`cmake/`** — the integration (`FindHylo.cmake`, `HyloTargets.cmake`) and its
  [README](cmake/README.md): usage, design, limitations.
- **`examples/`** — multi-file module, module graph (diamond), C interop, plain
  `add_library` + `hylo_target_module`.
- **`tests/`** — build-system behaviour tests (incremental rebuilds, interface-hash
  pruning, generators), run by `ctest -L behaviour`.
- **`notes/`** — research: [UPSTREAM-PLAN.md](notes/UPSTREAM-PLAN.md) (status and
  tiered plans for upstream CMake / hc), and the earlier investigation of
  out-of-tree language support, whole-module compilation upstream, Swift's model,
  and LSP integration.

Requires CMake ≥ 3.30 and hc ≥ 0.0.6 (`hc` on `PATH`, or `-DHylo_COMPILER=…`).

```
cmake --preset default && cmake --build --preset default && ctest --preset default
```
