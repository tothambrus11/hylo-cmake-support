# Hylo language support in CMake — experiment findings

> **Status (2026-08-22):** this document describes the *language-module* integration
> this repository started with (`CMakeDetermineHyloCompiler.cmake` & co.). That
> integration was replaced by a `find_package(Hylo)` + custom-command design when
> moving to hc 0.0.6; see `../cmake/README.md` for the current design and
> `UPSTREAM-PLAN.md` for what changed and why. The analysis below is kept as history;
> the upstream-CMake findings still hold. The hc gaps it originally recorded —
> no multi-module CLI, no `--version` — are fixed in current hc and no longer
> documented here.

## Verdict

**Hylo can be added to CMake entirely out-of-tree.** No patch to upstream CMake is needed.
`project(HyloExperiment LANGUAGES Hylo)` configures, builds, links, runs, and rebuilds incrementally, using stock CMake
3.28.3 with only five files on
`CMAKE_MODULE_PATH`.

This works because CMake's language machinery is genuinely generic: the compiler-id plumbing, the linker-preference
logic, and the Ninja/Makefile generators all key off
`CMAKE_<LANG>_*` variables and never hardcode a language list on the path we use. The result runs and returns the
expected value from a two-file module with a cross-file call.

Caveat matching `Modules/CMakeAddNewLanguage.txt`: this is *internal* API with no compatibility guarantee. Everything
below is pinned to a CMake version and will need re-porting.

## What the integration looks like

```
cmake/CMakeDetermineHyloCompiler.cmake   # find hc, configure the compiler file
cmake/CMakeHyloCompiler.cmake.in         # persisted compiler info
cmake/CMakeHyloInformation.cmake         # compile/link rules
cmake/CMakeTestHyloCompiler.cmake        # verify hc works
cmake/AddHylo.cmake                      # hylo_add_executable()
cmake/RunExpectExit.cmake                # ctest helper: assert exact exit status
```

Two targets, both passing under `ctest`:

| target      | what it covers                                         | exit |
|-------------|--------------------------------------------------------|------|
| `hello`     | multi-source Hylo module, cross-file call              | 42   |
| `c-interop` | `@extern_c_indirect` FFI + C sources compiled by CMake | 13   |

The compile rule is now a plain, direct `hc` invocation:

```
hc -O --module-name hello .../support.hylo --emit object -o .../main.hylo.o .../main.hylo
```

## The central mismatch: whole-module vs. per-source

CMake compiles **one object per source**. `hc` compiles **one object per module**, consuming all sources at once. These
cannot be reconciled directly.

Writing `add_executable(foo a.hylo b.hylo)` naively would make CMake emit one compile command per source, each compiling
the *whole* module, producing N identical objects that collide at link time with duplicate `main` symbols.

`hylo_add_executable()` works around it:

- The **first** source carries the whole-module compilation.
- The rest are marked `HEADER_FILE_ONLY`, so CMake keeps them in the target (they still appear in IDEs) but never
  compiles them.
- The remaining sources reach the compile rule via source-level `COMPILE_OPTIONS`.
- They are also listed in `OBJECT_DEPENDS`, so editing any of them rebuilds the module. **Verified**: editing
  `support.hylo` (a non-primary source) correctly rebuilds and the new value propagates.

### What this costs

The module is **opaque to CMake**. It sees one object with a pile of dependencies, not a set of compilable sources.
Consequences:

- No per-source flags (there is only one real compile).
- No `add_library(OBJECT)` composition of Hylo sources.
- Any source edit rebuilds the entire module.
- The "first source" is load-bearing but arbitrary — a wart users will trip on.

This is the same problem Swift has. CMake solves it for Swift **in C++**, and only for the Ninja generator. Doing it
*properly* for Hylo — one compile command per target, sources not special-cased by position — is exactly the part that
requires upstream C++ changes. The `HEADER_FILE_ONLY` trick is a userspace approximation of that.

**See [UPSTREAM-MULTIFILE-MODULES.md](UPSTREAM-MULTIFILE-MODULES.md)** for what proper upstream support would take.
Short version: upstream's own Rust support picks "the first source" as the aggregation point exactly like
`hylo_add_executable()` does, so this hack is a userspace shadow of an upstream mechanism. And the whole-module path
Hylo needs is broken upstream *today* — `$<TARGET_OBJECTS>` names objects that are never produced, reproduced against a
locally built CMake 4.4.

## Changes made to `hc` (in `hylo-new`)

All three were driven by concrete friction hit while writing the CMake rules. All 416 Hylo tests still pass.

Together they make the integration a set of plain `hc` invocations with no guessing: the build system states the module
name, states the output path, and asks the compiler where its standard library is.

### 1. `--module-name <name>` (new)

Previously the module name was *inferred* from the shape of the input list (`productName()` in
`Sources/hc/CommandLine.swift`): a single input yielded that file's basename, anything else yielded `Main`. So
`hc m.hylo` produced module `m` but
`hc a.hylo b.hylo` produced `Main` — **adding a second file to your project silently renamed your module and its output
file.**

A build system cannot predict the output path from the command line it is constructing. Before this flag, the CMake
integration had to *reimplement `productName()` in CMake* and then glob the output directory as a fallback. That
coupling is now gone.

### 2. `--emit object -o` now names a FILE, not a directory

`--emit object -o X` treated `X` as a **directory to fill**. Every other output type (`ast`, `ir`, `llvm`, `asm`,
`binary`) treats `-o` as a file — object was the sole exception. CMake's `<OBJECT>` placeholder is an exact file path,
so the integration needed a `cmake -P` wrapper script purely to run `hc` into a scratch directory and copy the result to
the requested path.

With `-o` meaning a file, **the wrapper script was deleted entirely** and
`CMAKE_Hylo_COMPILE_OBJECT` became a direct `hc` call.

This is a **breaking change** for anyone passing a directory to `-o`. The break is loud, not silent
(`LLVMError: Is a directory`) — it caught my own compiler test immediately. Note the pre-existing failure mode it
replaces was worse: passing a *nonexistent*
directory produced a bare `LLVMError(description: "No such file or directory")`, which reads like a missing source file.

The `FIXME: output the dependencies of module, including the standard library` above this code wants to emit *several*
objects, which is presumably why it was a directory. That should be a separate mode or a separate invocation per
module — not a reason for `-o` to mean something different here than everywhere else.

### 3. `--print-stdlib-root` (new)

Prints the standard library's root directory and exits, with no other side effects (in particular it does not create a
module cache). Needed because the stdlib location is baked into the compiler at build time, making the compiler the only
thing that can report it.

`Driver.standardLibraryRoot` is now `public static` (it was a private instance property, so answering the query would
otherwise have required constructing a whole `Driver` with a target spec). `Driver.standardLibraryCShim` is exposed
alongside it for in-process clients.

Anyone linking Hylo objects outside `hc` needs this — it is not CMake-specific.

## C interop under CMake

The `c-interop` target is a port of
`hylo-new/Tests/CompilerTests/positive/c-ffi-calls.package` (Hylo `struct Point` and `Int`
operations bound to C via `@extern_c_indirect`, plus `malloc`/`free` through the stdlib shim). It builds and **exits
13**, matching the package's `"exit-status:13"` manifest.

### This is the part of the integration that is genuinely nicer than hc

Hylo's C interop needs *no help from hc at all* under CMake. `hc` compiles only the Hylo module; CMake compiles
`foreign.c` and `shims.c` with its own C support and links everything together:

```
[1/7] Building C object    .../shims.c.o
[3/7] Building C object    .../foreign.c.o
[5/7] Building Hylo object .../main.hylo.o
[7/7] Linking Hylo executable c-interop
```

`hylo_add_executable()` just partitions its arguments: `.hylo` sources form the module, everything else is handed to
CMake untouched. `project(LANGUAGES C Hylo)` does the rest, and Hylo's higher `CMAKE_Hylo_LINKER_PREFERENCE` (40 vs. C's
10) makes it the linker language automatically.

**This is strictly better than `hc --emit binary`.** `Driver.generateExecutable`
recompiles every C source into a fresh temporary directory on each link. Under CMake the C objects are cached and
tracked:

- Touching `foreign.c` rebuilds **only** the C object, then relinks.
- Touching `LibC.hylo` rebuilds **only** the Hylo module, then relinks.

Verified, including a negative control: perturbing `Int_add_indirect` in `foreign.c` to add 100 changed the exit status
13 → 213 (the function is called twice), proving the CMake-built C object is the one linked. The exit-status tests
assert the exact code (`RunExpectExit.cmake`) and were checked to fail when given a wrong expectation.

The lesson for the CLI: `withCSources:` is hc solving a problem that build systems already solve better. It is the right
default for `hc file.hylo` on the command line, but the `--emit object` + external-link path is what integrations want,
and it should stay first-class.

### Locating the stdlib shim

`shims.c` implements the `@extern_c_indirect` functions the stdlib declares (`c_malloc_indirect`, `c_free_indirect`).
Any Hylo program that allocates needs it linked in. `hc --emit binary` appends it automatically
(`Driver.generateExecutable`), but when you link yourself — which every build-system integration does — you must supply
it, and its path is baked into the compiler at build time. This is what motivated `--print-stdlib-root` (change 3
above): the compiler is the only thing that knows the path, and asking it works for local and bundled layouts alike.

## Other rough edges found

### `try_compile()` is unusable for out-of-tree languages

`CMakeTestHyloCompiler.cmake` deliberately does **not** use `try_compile()`. It generates a throwaway project that calls
`enable_language(Hylo)`, which needs our
`CMakeDetermine*/Information/Test` modules on *its* module path — but `try_compile` does not propagate
`CMAKE_MODULE_PATH`. So the generated project cannot find the language definition and configuration fails. The
workaround is a direct `execute_process`, which means the compiler test does not exercise the real compile+link rules.

This is a genuine upstream gap for the "languages outside CMake" use case that
`CMakeAddNewLanguage.txt` explicitly sanctions.

### `cmake_initialize_per_config_variable` is easy to miss, and fails silently

Setting `CMAKE_Hylo_FLAGS_RELEASE_INIT` does nothing on its own. Something must convert the `_INIT` variables into
per-config cache entries:

```cmake
cmake_initialize_per_config_variable(CMAKE_Hylo_FLAGS "Flags used by the Hylo compiler")
```

Without it there is **no warning** — the flags simply never appear on the command line. I hit this exactly: `-O` was
silently absent from Release builds until I added the call.
`CMakeAddNewLanguage.txt` does not mention it.

### The installed `hc` does not match `hylo-new` HEAD

The `hc` on `PATH` (via proto, built May 9) differs from the tree:

|                        | installed `hc`              | `hylo-new` HEAD           |
|------------------------|-----------------------------|---------------------------|
| `-O`                   | `-O <0-3>`                  | bare `-O` flag            |
| `--stdlib`             | present                     | gone                      |
| `--emit object` output | `Main.o` + `stdlib_shims.o` | `Main.o` only             |
| stdlib shim path       | `Shims/shim.c`              | `shims.c` (`cShimSource`) |

Anyone testing against `PATH`'s `hc` is testing a different compiler. This experiment uses the freshly built
`.build/release/hc`.

Incidentally, `stdlib_shims.o` (installed `hc` only) contains **no symbols at all** — not even local ones — so linking
it is currently a no-op.

## Reproducing

```sh
cd hylo-new && swift build -c release --product hc     # ~83s cold, ~8s warm
cd ../hylo-cmake-experiment
cmake -S . -B build -G Ninja -DCMAKE_Hylo_COMPILER=$PWD/../hylo-new/.build/release/hc
ninja -C build && ./build/hello; echo $?   # => 42
```
