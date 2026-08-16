# Swift's compilation model: CMake vs. SPM

Everything below is **observed**, not recalled: CMake 4.4 built from this tree driving `swiftc`
6.3, and SPM's own llbuild manifests from the `hylo-new` package (`.build/release.yaml`,
`.build/debug.yaml`).

## TL;DR

The two systems have **converged on the same compile model**: *the module is the compile unit*.
One task per module, N sources in, N objects out, `-module-name`, `-output-file-map`, sources
passed via a response file. Put the two descriptions side by side and they are nearly the same
sentence:

```
SPM     description: "Compiling Swift Module 'Driver' (3 sources)"
CMake   description = Building Swift Module 'wm' with 2 sources
```

They differ in three places that matter:

1. **Who defines the module** — SPM by directory convention, CMake by explicit source lists.
2. **Who decides the compilation mode** — SPM hardwires it to the configuration, CMake exposes it
   as a per-target property.
3. **Whether objects are user-visible** — SPM hides them, CMake makes them first-class. This is
   the deep difference, and the source of CMake's bugs.

## 1. The shared foundation

### SPM (`.build/release.yaml`, an llbuild manifest — SPM's `build.ninja`)

```yaml
"C.Driver-x86_64-unknown-linux-gnu-release.module":
  tool: shell
  inputs:  ["…/Driver/CompilationError.swift", "…/Driver/Driver.swift", …]
  outputs: ["…/release/Driver.build/CompilationError.swift.o", …]
  description: "Compiling Swift Module 'Driver' (3 sources)"
  args: [swiftc, -module-name, Driver, -emit-dependencies, -emit-module,
         -emit-module-path, …/Modules/Driver.swiftmodule,
         -output-file-map, …/Driver.build/output-file-map.json,
         -parse-as-library, -whole-module-optimization, -num-threads, 20, -O,
         -c, "@…/Driver.build/sources"]
```

### CMake (`build.ninja`)

```ninja
build CMakeFiles/wm.dir/a.swift.o CMakeFiles/wm.dir/b.swift.o: Swift_COMPILER__wm_unscanned_ a.swift b.swift || cmake_object_order_depends_target_wm
  FLAGS = -module-name wm -wmo -output-file-map CMakeFiles/wm.dir//output-file-map.json
  description = Building Swift Module 'wm' with 2 sources
  restat = 1
```

Both are **one node in the build graph per module**, with every source as an input and every
object as an output. Neither build system compiles a Swift file in isolation. Both:

- pass `-module-name` explicitly rather than inferring it,
- hand `swiftc` an `-output-file-map` (the swiftc driver protocol from Apple's `Driver.md`) so it
  knows where to put each `.o`,
- move the source list into a response file, because whole-module command lines blow the
  command-line length limit. SPM writes `Driver.build/sources` (one path per line) and passes
  `-c @…/sources`. CMake has a hardcoded carve-out for exactly this at
  `Source/cmNinjaTargetGenerator.cxx:715`:

  > `// Swift consumes all source files in a module at once, which reaches command line length`
  > `// limits pretty quickly. Inject source files into the response file in this case as well.`

- **delegate incrementality to the compiler.** Neither build system models per-file Swift
  dependencies. The task/edge re-runs as a unit; `swiftc` consults `.swiftdeps` via the OFM and
  internally skips work. CMake sets `restat = 1` because swiftc leaves unchanged outputs untouched.

That convergence is not coincidence — CMake's Swift support was written by Apple/Swift-adjacent
contributors, and both are driving the same `swiftc` driver, whose interface *is* whole-module.

## 2. Where they diverge

### 2.1 Who defines the module

| | SPM | CMake |
|---|---|---|
| Module identity | Directory name: `Sources/Driver/` → module `Driver` | Target name: `add_library(Driver …)` |
| Source list | **Globbed** from the directory | **Explicitly listed**, every file |
| Dependencies | `.target(name:"Driver", dependencies:["FrontEnd"])` in `Package.swift` | `target_link_libraries(Driver PRIVATE FrontEnd)` |

SPM's model is convention-over-configuration: a module *is* a directory, and adding a file to it
requires no build-file edit. CMake requires enumerating sources, which is the long-standing CMake
position (globbing hides new files from the configure step).

For dependencies, CMake threads `.swiftmodule` files in as **implicit deps** on the compile edge
from each direct dependency (`cmNinjaTargetGenerator.cxx:2288-2303`), and makes the link edge
implicitly depend on the target's own `.swiftmodule` so the emit-module edge runs even if nothing
else consumes it (`cmNinjaNormalTargetGenerator.cxx:1652-1657`).

### 2.2 Who decides the compilation mode

**SPM hardwires mode to configuration.** Observed in the manifests:

| | flags |
|---|---|
| `release.yaml` | `-whole-module-optimization -num-threads 20 -O` |
| `debug.yaml` | `-incremental -enable-batch-mode -Onone` |

That is a policy decision baked into SPM: release means WMO, debug means incremental+batch. There
is no per-target knob.

**CMake exposes it.** `Swift_COMPILATION_MODE` (target property, CMake 3.29+, policy CMP0157),
initialized from `CMAKE_Swift_COMPILATION_MODE`, values `wholemodule` / `incremental` /
`singlefile`, default `incremental`, and generator-expression-aware:

```cmake
set_property(TARGET foo PROPERTY
  Swift_COMPILATION_MODE "$<IF:$<CONFIG:Release>,wholemodule,incremental>")
```

That example from `Help/prop_tgt/Swift_COMPILATION_MODE.rst` is CMake reproducing *by hand* what
SPM does automatically. CMake is more configurable and less opinionated; SPM is more automatic.

**Crucially, the mode is not build-graph topology in either system.** Verified — CMake's
`wholemodule` and `incremental` emit the *identical* ninja graph, differing only in a flag:

```
build …/wm.dir/a.swift.o  …/wm.dir/b.swift.o : Swift_COMPILER__wm_  a.swift b.swift
  FLAGS = -module-name wm  -wmo         -output-file-map …
build …/inc.dir/a.swift.o …/inc.dir/b.swift.o: Swift_COMPILER__inc_ a.swift b.swift
  FLAGS = -module-name inc -incremental -output-file-map …
```

Same shape, same inputs, same outputs. Both systems always emit one edge per module and let
`swiftc` decide what to actually do.

### 2.3 Module emission — CMake is ahead

**SPM emits the `.swiftmodule` on the same invocation**: `-emit-module -emit-module-path
…/Modules/Driver.swiftmodule` sits in the same `args` array as `-c`. Downstream modules therefore
wait for the whole compile.

**CMake 4.4 can split it into a separate, earlier edge** — `CMAKE_Swift_EMIT_MODULE` +
`Swift_SEPARATE_MODULE_EMISSION` (policy CMP0215). Observed:

```ninja
build lib.swiftmodule/x86_64-unknown-linux-gnu.swiftmodule: Swift_EMIT_MODULE__lib_ a.swift b.swift
build CMakeFiles/lib.dir/a.swift.o CMakeFiles/lib.dir/b.swift.o: Swift_COMPILER__lib_unscanned_ a.swift b.swift
build liblib.a: Swift_STATIC_LIBRARY_LINKER__lib_ …/a.swift.o …/b.swift.o | lib.swiftmodule/…
```

Dependents can start as soon as the `.swiftmodule` lands, without waiting for object code — the
same idea as C++20 BMIs and Fortran `.mod`. This is a genuine capability SPM lacks.

The catch, and CMake documents it in the code: both edges share one `-output-file-map`, so they
would race on the module `.swiftdeps`. CMake serializes them with an order-only dep
(`cmNinjaTargetGenerator.cxx`):

> `// Both edges share the same -output-file-map; serialize the compile edge after emit-module so`
> `// they do not race on the module .swiftdeps.`

So the win is for *downstream* targets, not for the two edges of the same target.

### 2.4 The output-file-map differs in content

Both write one, but not the same one.

**SPM** (`Driver.build/output-file-map.json`):
```json
"":  { "object": "…/Driver.o", "dependencies": "…/Driver.d", "swift-dependencies": "…" }
"…/CompilationError.swift": { "object": "…/CompilationError.swift.o",
                              "swiftmodule": "…/CompilationError~partial.swiftmodule",
                              "swift-dependencies": "…" }
```

**CMake** (`CMakeFiles/wm.dir/output-file-map.json`):
```json
"":  { "swift-dependencies": "CMakeFiles/wm.dir//wm.swiftdeps" }
"…/a.swift": { "object": "…/a.swift.o", "dependencies": "…/a.swift.o.d",
               "diagnostics": "…/a.swift.o.dia", "swift-dependencies": "…" }
```

- SPM's module-level `""` entry names a **module object** (`Driver.o`) and a module depfile; CMake's
  `""` entry carries only `swift-dependencies`.
- SPM emits `~partial.swiftmodule` per source (the merge-modules model); CMake does not.
- CMake adds `diagnostics` (`.dia`) per source; SPM (release) does not.

### 2.5 Objects: hidden vs. first-class — the deep difference

This is the one that actually bites.

**SPM does not expose object files.** They are an implementation detail inside `.build/`. Nothing
in `Package.swift` can name one. So SPM is free to let `swiftc` decide how many objects exist and
what they are called — the OFM is the only thing that needs to know, and `swiftc` reads it.

**CMake makes objects a user-visible, load-bearing concept**: `$<TARGET_OBJECTS:tgt>`,
`add_library(… OBJECT …)`, `install(TARGETS … OBJECTS)`, and the file API all name individual
object files. CMake must therefore *predict* object paths at generate time, which is why it holds

```cpp
mutable std::map<cmSourceFile const*, cmObjectLocations> Objects;   // cmGeneratorTarget.h:1205
```

— one source, one object. Swift's whole-module path bypasses this map rather than fixing it, and
the two disagree. Reproduced against CMake 4.4:

```
$<TARGET_OBJECTS:objs>  claims:   CMakeFiles/objs.dir/./a.swift.o
the compile edge actually emits:  CMakeFiles/objs.dir/objs.o
```

The generator expression names a file that is never produced. This is the 2023 `9bed4f4d81` commit's
acknowledged leftover, still open. SPM has no equivalent bug because it never made the promise.

Why it rarely bites Swift: the single-object path requires `CMAKE_Swift_NUM_THREADS == 0`, but
`Modules/CMakeSwiftInformation.cmake` defaults it to the core count — so Swift almost always emits
one object *per source*, accidentally satisfying the 1:1 map. Note SPM makes the same choice
(`-num-threads 20` on a 20-core box), for the same reason: parallelism within the module.

### 2.6 Everything else SPM owns that CMake doesn't

SPM is a package manager, not just a build system. `.build/` also holds `checkouts/`,
`repositories/`, `workspace-state.json`, `artifacts/`, `plugins/`, `prebuilts/` — dependency
resolution, version pinning, and build plugins. CMake deliberately has no opinion here
(`FetchContent`/`find_package` are separate mechanisms). The manifest itself is compiled: SPM runs
`swift-frontend` over `Package.swift` to *execute* it, whereas CMake interprets `../CMakeLists.txt`.

## 3. Summary table

| | SPM | CMake 4.4 |
|---|---|---|
| Compile unit | module | module (target) |
| Graph shape | 1 llbuild task / module | 1 ninja edge / target |
| Sources | globbed from directory | listed explicitly |
| Source passing | `-c @…/sources` rsp file | `$in` injected into rsp (`:715` carve-out) |
| Module name | directory name | target name, `-module-name` |
| Mode selection | hardwired: release=WMO+`-O`, debug=incremental+batch | `Swift_COMPILATION_MODE` property (CMP0157) |
| Mode affects topology? | **no** | **no** — flags only |
| `.swiftmodule` | same invocation | same invocation, **or separate edge** (CMP0215) |
| Output-file-map | yes, `""` entry names module object | yes, `""` entry has only swiftdeps |
| Incrementality | `swiftc` (`-incremental`, swiftdeps) | `swiftc` (same), `restat = 1` |
| Objects user-visible | **no** | **yes** — `$<TARGET_OBJECTS>`, OBJECT libs, install |
| Object-name bug | n/a | **yes**, whole-module + single output |
| Generators/backends | llbuild only | Ninja, Xcode (**not** Makefiles, **not** VS) |
| Dependency resolution | built in | out of scope |

## 4. What this implies for Hylo

Both mainstream Swift build paths converged on *the module is the compile unit* — which is exactly
`hc`'s model, and exactly what CMake's generic per-source machinery cannot express. That is
reassuring: Hylo is not unusual, it is in the same family as Swift, and the CMake-side answer for
Hylo should look like Swift's edge.

But two of Swift's escape hatches are unavailable to Hylo:

- **Swift dodges the object-name bug by emitting N objects** (one per source, via `-num-threads`).
  `hc` emits exactly one object per module, always. Hylo lives permanently in the broken corner.
- **Swift delegates incrementality to `swiftc`** via the OFM and `.swiftdeps`. `hc` has no such
  protocol — no output-file-map, no per-source dependency records, and its module archive is
  computed and discarded (see FINDINGS.md). So "one edge per module, rebuild the module on any
  change" is not a temporary limitation for Hylo; it is the only available semantics until `hc`
  grows an incremental protocol.

If Hylo ever wants what SPM/Swift have, the OFM is the design to copy: a build-system-written JSON
file telling the compiler where each artifact goes, plus compiler-written dependency records the
build system never parses. That is the contract that lets both CMake and SPM stay ignorant of
Swift's internals while still getting incremental builds.
