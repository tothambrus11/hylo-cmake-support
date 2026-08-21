# CMake support for Hylo

Two files give a CMake project Hylo support, using only documented, stable CMake
features (no `CMakeDetermine<LANG>Compiler` internals):

| file | role |
|---|---|
| `FindHylo.cmake` | finds `hc`, queries it (`--version`, `--print-stdlib-root`), checks it works, defines `Hylo::hc` / `Hylo::Runtime`, the `Hylo_*` configuration variables, and includes the next file |
| `HyloTargets.cmake` | `hylo_add_library`, `hylo_add_executable`, `hylo_target_module`, `hylo_target_compile_options`, `hylo_install_module`, and the `hylo-project.json` writer |
| `RunExpectExit.cmake` | ctest helper used by this repo's examples: assert an exact exit status |

Tested against **hc 0.0.6** (the first release with `--module-search-path`,
`--import`, `--emit-module-to`, `--emit-module-interface-hash-to`, `--version`)
and CMake 4.3; requires **CMake ≥ 3.30**.

## Usage

```cmake
cmake_minimum_required(VERSION 3.30)
project(MyApp LANGUAGES C)                      # Hylo programs are linked with the C toolchain

list(APPEND CMAKE_MODULE_PATH "<path-to-this-directory>")
find_package(Hylo 0.0.6 REQUIRED)               # hc from PATH, $HC, $HYLO_ROOT, or -DHylo_COMPILER=

hylo_add_library(Support SOURCES Support.hylo Extra.hylo)     # one module, two files
hylo_add_executable(app   SOURCES main.hylo foreign.c)        # .c files are compiled by CMake as usual
target_link_libraries(app PRIVATE Support)                    # links AND makes `import Support` work
```

That is the whole API surface for most projects. `target_link_libraries` is the
only way to declare a module dependency: linking a Hylo library target adds
`--import=<Module>` to the dependent's compile, puts the archive directory on the
module search path, and makes the dependent's compile depend on the library's
interface hash. `PRIVATE`/`PUBLIC` have their usual meaning — and hc enforces
it: a module reachable only through a `PRIVATE` link cannot be `import`ed
(`behaviour.import-visibility` test).

Commands:

```
hylo_add_library(<target> [STATIC|SHARED|MODULE] [EXCLUDE_FROM_ALL]
                 [MODULE_NAME <name>] [NO_RUNTIME] [SOURCES] <file>...)
hylo_add_executable(<target> [EXCLUDE_FROM_ALL] [MODULE_NAME <name>] [NO_RUNTIME] [SOURCES] <file>...)
hylo_target_module(<existing-target> [MODULE_NAME <name>] [NO_RUNTIME])   # the primitive the two above use
hylo_target_compile_options(<target> <PRIVATE|PUBLIC|INTERFACE> <hc-option>...)
hylo_install_module(<library-target> [DESTINATION <dir>] [COMPONENT <c>])   # + install(TARGETS ... EXPORT)
```

Installing a Hylo library for other projects is the standard three lines plus one:

```cmake
install(TARGETS Support EXPORT SupportTargets ARCHIVE DESTINATION lib)
hylo_install_module(Support)                      # installs Support.hylomodule + Support.iface under lib/hylo
install(EXPORT SupportTargets NAMESPACE Support:: DESTINATION lib/cmake/Support)
```

A consumer then does `find_package(Hylo)` + `find_package(Support)` and
`target_link_libraries(app PRIVATE Support::Support)`; the exported target carries
the module name, the installed archive directory and the interface-hash file
(`tests/install-export/`).

`hylo_target_module` turns a target you created with `add_library`/`add_executable`
into a Hylo module; every `.hylo` file among its `SOURCES` — including ones added
later with `target_sources()` — is compiled into one module (`examples/plain-targets`).

Configuration (cache variables): `Hylo_COMPILER`, `Hylo_FLAGS`,
`Hylo_FLAGS_<CONFIG>` (Release & co. default to `-O`), `Hylo_MODULE_CACHE_DIR`
(hc's stdlib cache; defaults to inside the build tree), `Hylo_TARGET_TRIPLE`
(`hc --target`, experimental), `Hylo_PROJECT_MANIFEST` (where the LSP manifest goes).
Full reference: the header comments of `FindHylo.cmake` and `HyloTargets.cmake`.

## How it works, and why it is built this way

`hc` compiles a **whole module at once** into exactly one object, and can publish
the module's archive (`.hylomodule`, what importers read) and an **interface
hash** next to it. CMake's native model is one object per *source*, so a Hylo
module is not expressed as compiled sources. Instead each Hylo target gets one
custom command:

```
hc --module-name M [Hylo_FLAGS...] [--import=Dep]... [--module-search-path=<dir>]...
   --emit object -o M.o --emit-module-to M.hylomodule --emit-module-interface-hash-to M.iface
   <every .hylo source of the target>
```

Its object is added to the target as an external object and linked by CMake's
ordinary C link rules. The `.hylo` files stay in the target (IDEs see them) but
CMake has no rule for them because Hylo is *not* an enabled CMake language.
Module visibility, search paths and rebuild dependencies flow through
`target_link_libraries` via CMake 3.30 custom transitive properties
(`TRANSITIVE_COMPILE_PROPERTIES` / `TRANSITIVE_LINK_PROPERTIES`); see the header
of `HyloTargets.cmake` for the property names.

The first version of this repository did the opposite: it registered Hylo as a
CMake *language* out-of-tree (`CMakeDetermineHyloCompiler.cmake` & co., in the
git history) and compiled the module through `CMAKE_Hylo_COMPILE_OBJECT`, with
the first source carrying the compile and the rest marked `HEADER_FILE_ONLY`.
It worked, but it sat on internal API and hit three ceilings that the custom
command approach does not have:

| | language-module version | this version |
|---|---|---|
| archive / interface hash as build outputs | `OBJECT_OUTPUTS` → Ninja **phony** alias of the `.o`; deleting the archive was not noticed | **real outputs** of the compile edge; regenerated if deleted, removed by `clean` (`behaviour.regenerate-deleted-archive`) |
| pruning dependents when a dependency's interface did not change | impossible: CMake's generic compile rule has no `restat` (only Swift sets it, in C++) | **works**: custom commands get `restat = 1`, and hc writes the hash file only when it changes (`behaviour.incremental-interface-hash`) |
| multi-config generators | no (archive path shared by all configs) | Ninja Multi-Config works (`behaviour.generator-ninja-multi-config`) |
| declaring a dependency | `IMPORTS <target>` keyword on our own functions | plain `target_link_libraries`, PRIVATE/PUBLIC respected |
| module sources | fixed at creation; "first source" was load-bearing | any `.hylo` in `SOURCES`, evaluated at generate time |
| API it relies on | `CMakeAddNewLanguage.txt` internals ("no compatibility guarantee") | `add_custom_command`, external objects, transitive properties — all documented |
| CMake floor | 3.28 | **3.30** (custom transitive properties) |

What is *lost*: `project(LANGUAGES Hylo)`, `CMAKE_Hylo_*` naming, and
`$<COMPILE_LANGUAGE:Hylo>` — the "Hylo is a language" feel. Those come back the
day CMake has first-class whole-module support (see `../notes/UPSTREAM-PLAN.md`);
until then a custom-command integration is what every other out-of-tree
toolchain (protobuf, Qt's moc, Vala, Corrosion for Rust) does, and it is the
more robust choice.

### The interface-hash story, concretely

`behaviour.incremental-interface-hash` builds the diamond (`Base ← Left ← App`,
`Base ← Right`), touches `Base.hylo` without changing it and rebuilds:

```
[1/9] Compiling Hylo module Base (Base)        # Base recompiles; hc leaves Base.iface untouched
[2/4] Linking C static library libBase.a       # 4 steps total: Left, Right, App were pruned
[3/4] Linking C executable diamond
```

Then it changes `Base`'s interface (adds a public function) and checks that
`Left` and `App` *do* recompile. Today hc's interface hash is a hash of the whole
archive (hylo-lang/hylo-new#321), so a body-only edit still cascades; the build
graph is already shaped to take advantage of a precise hash the moment the
compiler provides one — nothing on the CMake side has to change.

Conservatively, a dependent depends on the interface hashes of *every* module in
its link closure (not just direct imports), because hc loads transitive archives
and may inline their layouts.

## Limitations

- **OBJECT libraries** are not supported (`hylo_add_library(... OBJECT)` errors):
  the module's object is an *external* object of its target and CMake's
  `$<TARGET_OBJECTS>` / object-library linking does not include external objects
  (verified on CMake 4.3, `cmGeneratorTarget::GetTargetObjectLocations`). This is
  the same object-map limitation that blocks whole-module languages upstream.
- **One module per target**; `hylo_target_module` must be called in the
  directory that created the target (custom-command outputs attach to targets
  of their own directory).
- **Ordinary `COMPILE_OPTIONS` are not passed to hc** (in a mixed target they are
  C flags); use `hylo_target_compile_options` / `Hylo_FLAGS*`.
- A target with **C++ sources** must set `LINKER_LANGUAGE CXX` itself
  (`hylo_target_module` sets `C` only when nothing is set).
- `hylo-project.json` paths containing `"` or `\` are not escaped (it is written
  with `file(GENERATE)` from generator expressions, which cannot escape).
- Installing/exporting works (`hylo_install_module` + the usual
  `install(TARGETS ... EXPORT)`; `behaviour.install-export`), but the consumer must
  use a compatible `hc` — archives are tied to the compiler version and there is
  no version check on import yet beyond hc's own "cannot parse archive" error.
- Visual Studio / Xcode generators: untested. Nothing here is Ninja-specific
  except the `restat` pruning; Unix Makefiles are tested.

## Testing

```
cmake --preset default && cmake --build --preset default
ctest --preset default                 # exit-status tests of the examples + behaviour tests
ctest --preset default -L behaviour    # just the build-system behaviour tests (~40 s CPU)
```

The behaviour tests (`../tests/*.cmake`) configure and build copies of the
examples in scratch directories, mutate them, and assert on what recompiled and
on exit codes: interface-hash pruning, archive regeneration, mixed C/Hylo
partial rebuilds, late `target_sources`, import visibility, per-config flags, the
manifest, Ninja Multi-Config, Unix Makefiles.
