# Hylo × CMake: where we are, and tiered plans for upstream work

Status as of 2026-08-29, against **hc 0.0.8** (the supported floor) and
**CMake ≥ 3.30**. Companion to the
research notes in this directory (which document the *language-module* integration
this repository started with; see "What changed" below).

## 1. What exists now (all local, all tested)

`cmake/FindHylo.cmake` + `cmake/HyloTargets.cmake` — a `find_package(Hylo)`-style
integration that compiles each Hylo module with one custom command and links with
the C toolchain. Properties, verified by `tests/*.cmake` under ctest:

| property | status |
|---|---|
| multi-file modules, module graph via `target_link_libraries` (PRIVATE/PUBLIC respected, enforced by hc) | ✅ |
| archive + interface hash are **real** build outputs (regenerated if deleted, cleaned) | ✅ |
| **dependents pruned when the interface hash does not change** (Ninja `restat`) | ✅ works today; pays off fully once hc's hash is precise (hylo-new#321) |
| mixed C/Hylo targets, partial rebuilds | ✅ |
| Ninja, Ninja Multi-Config, Unix Makefiles | ✅ |
| per-config flags, per-target hc options | ✅ |
| `hylo-project.json` for the language server, generate-time accurate | ✅ |
| hermetic per-build-tree stdlib module cache, warmed at configure time | ✅ |
| OBJECT libraries | ❌ (CMake object map ignores external objects) |
| install/export of Hylo libraries (`hylo_install_module` + `install(EXPORT)`, consumed via `find_package`) | ✅ |
| package config for shipping inside a toolchain (`find_package(Hylo)` from `CMAKE_PREFIX_PATH`) | ✅ |
| Windows (MSVC + Ninja), macOS arm64, Linux x64/arm64 | ✅ in CI |
| Visual Studio 2022 / 2026 generators | ✅ supported, gating CI jobs |
| Xcode generator | ❌ unsupported (no per-config sources; curated configure-time diagnostic) |

### What changed versus the language-module version

The v1 integration registered Hylo as an out-of-tree CMake language
(`CMakeDetermineHyloCompiler.cmake` etc.) and compiled through
`CMAKE_Hylo_COMPILE_OBJECT` with the first source as the compile anchor and the
rest `HEADER_FILE_ONLY`. hc 0.0.6 renamed `-I` to `--module-search-path`, which
is what broke it; but while fixing that it became clear the language approach has
hard ceilings that the custom-command approach simply does not have — phony
archive outputs, no `restat` (so no interface-hash pruning, ever, from Modules
alone), no multi-config — and it sits on API that `CMakeAddNewLanguage.txt`
explicitly disclaims. The measurements that drove the switch are in
`../cmake/README.md`. The old modules remain in git history (commit `3e65052`).

This **does not** invalidate the upstream analysis in `UPSTREAM-MULTIFILE-MODULES.md`;
it sharpens it: the custom-command route is the best *out-of-tree* Hylo can do, and
its remaining gaps (OBJECT libraries, `$<COMPILE_LANGUAGE:Hylo>`, "first-class
language" ergonomics) are exactly the things only upstream C++ can provide.

## 2. Things still worth changing in `hc` (for build systems)

Ordered by value. Items 1–2 are the ones that change what CMake can do; the rest
are polish.

1. **Precise interface hash** (hylo-new#321). Today `--emit-module-interface-hash-to`
   hashes the whole archive, so any body edit invalidates dependents. The CMake side
   is already shaped for a precise hash (dependents depend on `.iface`, compile edges
   restat); the day the hash ignores bodies, body edits stop recompiling dependents
   with **no CMake change**. When doing it: fold the *dependencies'* interface hashes
   into a module's hash (or document that they are not), because a dependent
   compiled against `Left` may have inlined `Base`'s layouts through `Left`'s types;
   the CMake integration currently compensates by depending on the whole link
   closure's hashes.
2. **`--cpu` defaults to `native` for host builds.** Build systems produce artifacts
   that get copied around; a `-march=native`-style default is surprising for a
   *compiler driver* default (clang/gcc default to generic). Consider `generic` by
   default with `--cpu native` opt-in, or at least document it loudly. (CMake users
   can set `Hylo_FLAGS=--cpu generic`; tested.)
3. **Separate "emit module interface" from codegen** (like Swift's emit-module edge /
   CMP0215): dependents could start compiling as soon as a library's archive+hash
   are out, before its LLVM codegen finishes. Would let CMake split the custom
   command into two edges (archive+hash first, object second) and shorten critical
   paths on large graphs.
4. **Concurrent first use of the module cache.** N parallel `hc` processes with a
   cold cache all compile the stdlib and race writing `Hylo.hylomodule`. FindHylo
   avoids it by warming the cache at configure time, but a lock or atomic
   rename-into-place in `writeToCache` would make hc robust for every build system.
5. **Machine-readable diagnostics** (`--diagnostics-format json` or similar) so
   IDEs/CMake can surface errors without scraping; and an exit-code contract.
6. No depfile is needed: hc reads exactly the listed sources plus archives, and the
   build system knows both. Keep it that way (the `Generated.hylo` next to the
   stdlib root is the only implicit input; FindHylo depends on it explicitly).

## 3. Tiered plans for upstream CMake

The analysis in `UPSTREAM-MULTIFILE-MODULES.md` stands: CMake has no whole-module
abstraction; Swift, Rust, ISPC and C# each special-case the object map in C++. The
plan below is ordered by how realistic each step is *for us to land*, and what it
buys Hylo.

### Tier 0 — no upstream change; ship what we have (now)

- ~~Package config~~ — done: `HyloConfig.cmake` + `HyloConfigVersion.cmake` locate
  `hc` relative to themselves and defer to `FindHylo.cmake`; tested with a simulated
  `<root>/bin/hc` + `<root>/lib/cmake/Hylo/` layout (`behaviour.package-config`).
  Remaining: actually add the four files to hylo-new's release tarball
  (`.github/workflows/release.yml`) — a hylo-new PR.
- ~~Add install/export support~~ — done (`hylo_install_module`; CMake 3.30 exports
  custom transitive properties, and `$<INSTALL_INTERFACE:$<INSTALL_PREFIX>/lib/hylo>`
  resolves to `${_IMPORT_PREFIX}` in the export file). Missing: a compiler-version
  check when importing an installed archive (hc only fails with "cannot parse").
- Propose the integration to `hylo-lang` as the official CMake support (it is
  toolchain-agnostic beyond the `hc` CLI, which is now stable enough to pin).

### Tier 1 — small, self-contained upstream contributions (realistic in months)

Each of these is a normal CMake MR with a RunCMake test, independent of "Hylo
support", and each removes a papercut this integration hit:

1. **`$<TARGET_OBJECTS>` should include external objects of OBJECT libraries**, or
   a documented opt-in for it. Today `add_library(o OBJECT ext.o)` followed by
   `target_link_libraries(app o)` silently links nothing from `o`
   (`cmGeneratorTarget::GetTargetObjectLocations` only walks object sources and ISPC
   outputs). This is the reason Hylo OBJECT libraries are unsupported; it is also a
   latent trap for anyone wrapping an external code generator. Small C++ change,
   probably needs a policy.
2. **Documented `restat` for language compile rules**, e.g. a
   `CMAKE_<LANG>_COMPILE_OBJECT_RESTAT` (or per-rule variable) so out-of-tree
   languages whose compilers write-if-different can get the pruning that custom
   commands already get. One line in `cmNinjaTargetGenerator::WriteCompileRule`.
   This would let a *language-module* Hylo integration match the custom-command one
   on incremental behaviour.
3. **`try_compile()` should propagate `CMAKE_MODULE_PATH`** (or a documented
   variable to make it do so) so out-of-tree `CMakeDetermine<LANG>Compiler`
   modules can use `try_compile` in `CMakeTest<LANG>Compiler.cmake`. Documented
   rough edge in `FINDINGS.md`.
4. **Document `cmake_initialize_per_config_variable`** in
   `Modules/CMakeAddNewLanguage.txt` (silently-missing flags otherwise).

### Tier 2 — the real fix: a whole-module compile trait (realistic in a year, needs maintainer buy-in first)

From `UPSTREAM-MULTIFILE-MODULES.md`: generalize `IsSplitSwiftBuild()` into a
`CMAKE_<LANG>_COMPILES_WHOLE_MODULE` trait and make the object map able to
express N sources → 1 object. Concretely, in order:

1. Open the design conversation on issue #25308 (the Swift split-compilation
   leftover) with the reproducer: "`$<TARGET_OBJECTS>` names objects a whole-module
   Swift OBJECT library never produces". Ask whether Kitware wants a generic
   abstraction or considers per-language C++ acceptable. Everything below depends
   on the answer.
2. **Fix the object map** (Tier 1 of that document): `map<cmSourceFile const*,
   cmObjectLocations>` → compile groups; `GetObjectName` returns by value/optional;
   the six `ComputeObjectFilenames` overrides. Land it as "fix `TARGET_OBJECTS` for
   whole-module Swift" — a bug fix, reviewable on its own.
3. **Parameterize `WriteSwiftObjectBuildStatement` over language**, splitting the
   Swift-specific parts (output-file-map, `-parse-as-library`) from the generic
   "one edge, N sources, declared outputs, restat". Declared *additional* outputs
   (the archive, the interface hash) become first-class here.
4. Then a `Modules/CMakeHyloInformation.cmake` is a small file: `COMPILE_OBJECT`
   with `<SOURCES>`, `COMPILES_WHOLE_MODULE 1`, and the interface artifact declared
   as an output. `add_executable(app a.hylo b.hylo)` + `target_link_libraries` would
   just work, with `$<COMPILE_LANGUAGE:Hylo>`, `CMAKE_Hylo_FLAGS`, compile
   commands, and OBJECT libraries all correct.

What makes this realistic: Hylo is the *simplest* whole-module consumer (one object,
plain `-o`, no output-file-map, no compilation-mode enum), which makes it a good
forcing function and test case for the abstraction, and the Swift bug gives the
work an upstream-internal motivation that does not require Kitware to care about
Hylo at all.

### Tier 3 — interface artifacts as a generic concept (later)

`.swiftmodule` (emit-module edge), C++20 BMIs, Fortran `.mod`, and Hylo's
`.hylomodule`+hash are four implementations of "publish the interface so consumers
unblock early and skip rebuilds when it is unchanged". `LanguageEmitModuleRule` is
already written generically; the call sites hardcode Swift. Once Tier 2 exists,
generalizing this gives Hylo the split emit-module edge (item 3 in §2) in the
language-module world as well.

## 4. Priorities for the next session

1. Tier 0: PR to hylo-new's release workflow to ship `lib/cmake/Hylo/*.cmake` in
   the toolchain tarballs; propose this repo's `cmake/` as the official support.
2. Tier 1.1 and 1.2 as CMake MRs — both are small and each has a crisp test.
3. On the hc side: the precise interface hash (#321) is the single biggest win the
   build graph is waiting for.
