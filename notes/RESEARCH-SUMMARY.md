# Research summary: advancing CMake support for Swift & Hylo

> **Status (2026-08-22):** this document describes the *language-module* integration
> this repository started with (`CMakeDetermineHyloCompiler.cmake` & co.). That
> integration was replaced by a `find_package(Hylo)` + custom-command design when
> moving to hc 0.0.6; see `../cmake/README.md` for the current design and
> `UPSTREAM-PLAN.md` for what changed and why. The analysis below is kept as history;
> its findings about hc and about upstream CMake still hold.

Two-hour research + prototyping session. Everything here is implemented and measured; the Hylo
compiler diff is uncommitted in `~/CMake/hylo-new` (nothing pushed). All 416 Hylo tests pass.

## The five documents

| Doc | What it covers |
|---|---|
| [FINDINGS.md](FINDINGS.md) | Out-of-tree Hylo language support in stock CMake (no C++ patch), C interop, `hc` CLI friction |
| [UPSTREAM-MULTIFILE-MODULES.md](UPSTREAM-MULTIFILE-MODULES.md) | What proper upstream CMake support for whole-module languages takes; the object-map 1:1 assumption; reproduced `TARGET_OBJECTS` bug; can the four hacks unify |
| [SWIFT-CMAKE-VS-SPM.md](SWIFT-CMAKE-VS-SPM.md) | Swift's compile model in CMake vs SPM, observed from real build graphs |
| [HYLO-COMPILER-FOR-BUILD-SYSTEMS.md](HYLO-COMPILER-FOR-BUILD-SYSTEMS.md) | How `hc` should change; multi-module; the interface-hash / `@frozen` design, prototyped |
| this | Ties it together |

## What got built and proven this session

### 1. Multi-module separate compilation in `hc` (new, working)

Hylo's defining advantage over Rust: **true separate compilation** — a module compiles to an
object referencing its dependencies' symbols as undefined, resolved at link, with no
monomorphization pulling dependency bodies into dependents. Confirmed at the symbol level
(`Support.o` defines `answer`, `Main.o` leaves it undefined).

Made it work end-to-end. Added to `hc`:
- `--emit-module-to` — publish a `.hylomodule` (previously the product archive was computed and
  **thrown away**).
- `--import <M>` — load a module and register the dependency (previously only the stdlib could be a
  dependency).
- working `-L` module search (previously `archive(of:)` ignored `librarySearchPaths`).
- transitive resolution: `hc` reads dependency headers and loads the closure, so the build system
  declares only **direct** edges.

Fixed a real front-end bug: cross-module `import` never worked — an inverted guard in the import
table builder (`if table.contains(m)` should be `if !table.contains(m)`). The only `import` in the
entire repo was a *negative* test, so it had never been exercised positively.

Works in CMake with a real module graph (`hylo_add_library` + `IMPORTS`): libraries, a two-module
program, and a diamond all build, order correctly, and run. 4/4 ctest.

### 2. The interface hash — the keystone (new, prototyped, proven)

The problem: Hylo's `.hylomodule` conflates interface and implementation (it contains IR bodies),
so **any body edit changes the archive and cascades a rebuild to every dependent** — throwing away
the separate-compilation advantage. Measured: body `42`→`43` changes the archive.

Prototyped `hc --emit-module-interface-hash` — a compiler-computed digest of the module's
*observable surface*: mangled signatures of ABI-visible functions + ABI-visible struct layouts,
skipping anything private via the existing `isPrivate` predicate. Measured to be:
- **stable** across body edits and private-decl changes,
- **sensitive** to public signature changes, added/removed public decls, and struct field
  add/remove/reorder.

Proven end-to-end in Ninja: with the hash + **write-if-different** + `restat = 1`, a body-only edit
to a dependency **relinks the program without recompiling the dependent**. That is Hylo's
separate-compilation advantage, realized in a build graph for the first time. Rust cannot do this.

### 3. Where the compiler and CMake work meet: `restat`

The interface-hash skip needs the compile rule to `restat`. CMake's generic
`CMAKE_<LANG>_COMPILE_OBJECT` rule doesn't emit `restat = 1` (only link rules do; Swift sets it in
C++). So the payoff is proven but not yet reachable from a Modules-only integration — the same C++
ceiling as `OBJECT_OUTPUTS`-as-phony and the `TARGET_OBJECTS` bug. A whole-module language upstream
needs: its interface artifact as a true compile output, and `restat` on its compile rule.

## The `@frozen` question, answered

The user asked whether `@frozen`-driven invalidation should be tracked by the compiler. **Yes**, and
the interface hash is the mechanism:

- A dependent must recompile iff a dependency's change crosses the **observable ABI surface**:
  public signatures, `@frozen`/inlined layouts, inlinable bodies. Not: private decls, non-frozen
  layouts, ordinary bodies.
- The compiler is the only component that knows which bodies are inlinable and which layouts are
  frozen — it must compute the surface; the build system depends on an opaque hash of it.
- Status in Hylo today: `@frozen` is documented but `isLayoutVisible` is stubbed to `return true`,
  so *all* layouts are currently inlined (effectively all-frozen). The prototype hash folds struct
  layouts in unconditionally to match; once resilience lands, this is the exact spot to consult
  `isLayoutVisible` so non-frozen layout changes stop invalidating dependents.

So: track it in the compiler, expose it as one number, keep the build system dumb.

## Ranked next steps

**For `hc`** (in value order): interface hash + write-if-different (keystone); keep the
multi-module CLI; decouple `--emit-module` from object emission; a depfile; machine-readable
diagnostics; `--version`. Details in HYLO-COMPILER-FOR-BUILD-SYSTEMS.md §4.

**For CMake**: the tractable upstream contribution is not "add Hylo" but *"fix `$<TARGET_OBJECTS>`
for whole-module Swift"* (a reproduced, already-admitted bug), which forces the Tier-1 object-map
fix. Then generalize `IsSplitSwiftBuild()` into a `CMAKE_<LANG>_COMPILES_WHOLE_MODULE` trait that
also carries `restat` and a real interface-output declaration. Details in
UPSTREAM-MULTIFILE-MODULES.md.

**For the model unification**: the object model unifies cleanly (compile groups: N sources → M
outputs); emission and interface-artifact protocols stay per-language. C# is delegation, not a
compile model. Interface artifacts (`.swiftmodule` / BMI / `.mod` / `.hylomodule`) are the
better-duplicated second target — `LanguageEmitModuleRule` is already generic over `lang`.

## `hc` diff (uncommitted, for review)

```
 Sources/Driver/Driver.swift        | 172 ++++  (archive load/write, moduleSearchPaths,
                                                 interface hash + layout, transitive loader)
 Sources/FrontEnd/Module.swift      |  29 ++    (headerAndDependencies)
 Sources/FrontEnd/Typer/Typer.swift |   2 +-   (inverted import-table guard — real bug)
 Sources/hc/CommandLine.swift       | 127 ++    (--import, --emit-module-to,
                                                 --emit-module-interface-hash, write-if-different)
```

Plus the earlier session's `--module-name`, file-valued `-o`, and `--print-stdlib-root`. The
`Typer.swift` one-liner and the discarded-archive fix are genuine bugs worth upstreaming regardless
of the CMake work.
