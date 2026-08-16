# How Hylo's compiler should change for build-system support

Findings and prototypes from driving `hc` under CMake. Everything here is **implemented and
measured** in this session's `hylo-new` tree unless marked "proposal". The Hylo test suite (416
tests) passes with the changes.

Companion docs: [FINDINGS.md](FINDINGS.md) (out-of-tree CMake support),
[UPSTREAM-MULTIFILE-MODULES.md](UPSTREAM-MULTIFILE-MODULES.md) (upstream CMake),
[SWIFT-CMAKE-VS-SPM.md](SWIFT-CMAKE-VS-SPM.md) (how Swift does it).

## The headline

Hylo has a property Rust and Swift-in-CMake lack: **true separate compilation** — a module
compiles to an object referencing its dependencies' symbols as undefined, resolved at link. No
monomorphization forces the dependency's body into the dependent. That means Hylo *can* have a
real per-module build graph, the thing CMake is actually good at.

This session made that work end to end for the first time (§1). But separate compilation only
pays off if the build system can tell when a dependent *doesn't* need rebuilding — and today it
always does, because Hylo's module archive conflates interface and implementation (§3). That is
the single most valuable thing to fix, and it is exactly where the `@frozen` question lives.

## 1. Multi-module separate compilation — implemented and working

### What was missing in `hc`

Three gaps, all fixed this session:

1. **The product archive was computed and discarded.** `CommandLine.swift` built the archive,
   logged its size, and dropped it (see FINDINGS.md §"Multi-module"). No `.hylomodule` for your own
   module ever reached disk.
2. **`-L` did nothing for modules.** `archive(of:)` only searched `moduleCachePath`, ignoring
   `librarySearchPaths` entirely.
3. **No way to declare a dependency.** `addDependency` was only ever called with the stdlib.

### The changes

- `hc --emit-module-to <file>` — publish the module's archive (new).
- `hc --import <Module>` (repeatable) — load `<Module>.hylomodule` from `-L` paths and register it
  as a dependency (new).
- `archive(of:)` now searches `librarySearchPaths` + the cache (`Driver.moduleSearchPaths`).
- `Driver.loadArchivedModule` — loads an archive and its dependencies **depth-first**, because
  deserializing a module requires its dependencies' identities to be registered first
  (`Program.load` reserves identities from already-loaded modules).
- `Module.headerAndDependencies` — reads name + fingerprint + dependency list from an archive
  without deserializing the body, so the loader knows what to load first.

### A real front-end bug this uncovered

Cross-module import *never worked* — the only `import` in the entire repo is a **negative** test
(`Tests/CompilerTests/negative/undefined-module.hylo`). The import table builder had an inverted
guard, `Typer.swift`:

```swift
// Avoid importing a module more than once.
if table.contains(m) { table.append(m) }     // BUG: appends only if ALREADY present
```

So an imported module was never added to the import table; only the stdlib worked, because it is
appended explicitly above the loop. Fixed to `if !table.contains(m)`. With that one-character fix,
`import Support; … answer()` resolves across a module boundary.

### Proof it is genuine separate compilation

Two modules compiled by independent `hc` invocations, linked:

```
$ hc --module-name Support --emit object Support.hylo -o Support.o --emit-module-to Support.hylomodule
$ hc --module-name Main -L . --import Support --emit object Main.hylo -o Main.o
$ nm Support.o | grep answer  →  T $hM9SupportU10F08answer…   (defined)
$ nm -u Main.o | grep answer  →  U $hM9SupportU10F08answer…   (undefined, linker-resolved)
$ clang Main.o Support.o shims.c -o app && ./app; echo $?  →  42
```

`Support.o` *defines* the symbol; `Main.o` leaves it *undefined*. That is what Rust cannot do for a
generic without instantiating it in the dependent. Confirmed the archive header records the
dependency chain (`Main` → `Hylo`, `Support`).

### Transitive resolution — the CLI only needs direct imports

`hc` resolves dependencies transitively: `loadArchivedModule` reads each archive's dependency
header and loads those first, depth-first. Measured with a diamond (`Base` ← `Left`, `Base` ←
`Right`, `Left` ← `App`):

- `App` compiled with only `--import Left` (no `--import Base`) succeeds — `hc` reads
  `Left.hylomodule`'s header, sees `Base`, and loads it recursively.
- Remove `Base.hylomodule` and the same compile fails cleanly: `no archive found for module
  'Base'`. So the transitivity is real, not accidental.

This is a good CLI contract: the build system declares only **direct** edges, and the compiler
walks the closure. In CMake terms, `IMPORTS Left` is enough; CMake's own transitive
`target_link_libraries` then carries `Base`'s objects to the link. Verified the diamond executable
links `libLeft.a` + `libBase.a` (transitively) but **not** `libRight.a`, which `App` never imports.

### It works in CMake, with a real module graph

`hylo_add_library` / `hylo_add_executable` with `IMPORTS` (see `../cmake/AddHylo.cmake`). The archive
is declared via `OBJECT_OUTPUTS` and imported archives via `OBJECT_DEPENDS`, so CMake orders the
graph itself:

```
[5] Building Hylo object  Support.hylo.o
[6] Linking  Hylo static  libSupport.a
[10] Building Hylo object  Main.hylo.o        # after Support.hylomodule exists
[12] Linking  Hylo executable multi           # ./multi → 42
```

`ctest`: 3/3 pass (hello=42, c-interop=13, multi-module=42).

## 2. The CMake limitation this hits: OBJECT_OUTPUTS is not a real output

`set_source_files_properties(... OBJECT_OUTPUTS foo.hylomodule)` does **not** tell Ninja the
compile *produces* `foo.hylomodule`. CMake lowers it to a **phony alias**:

```ninja
build …/Main.hylo.o: Hylo_COMPILER__… Main.hylo | hylo-modules/Support.hylomodule
build hylo-modules/Support.hylomodule: phony …/Support.hylo.o     # <-- alias, not a real output
```

Measured consequence: delete `Support.hylomodule`, keep the `.o`, run `ninja` → **"no work to
do"**, archive not regenerated, and the next `Main` compile dies with `no archive found for module
'Support'`. The archive's freshness is tracked only transitively through the object file.

This is the same gap as ISPC's extra objects, which upstream solved *in C++* with real
`ImplicitOuts` (`cmNinjaTargetGenerator.cxx:1852`). An out-of-tree language cannot declare true
additional outputs — it is a hard ceiling of the Modules-only approach, and a concrete item for the
upstream trait work in UPSTREAM-MULTIFILE-MODULES.md: **a whole-module language needs its interface
artifact to be a first-class compile output, not a phony.**

For now the phony is *correct as long as nobody deletes the archive by hand* — the object and
archive are produced by the same command, so whenever the `.o` is rebuilt the archive is too. It is
fragile, not wrong.

## 3. The core issue: interface ≠ implementation, but the archive conflates them

This is the most important finding, and it is what the `@frozen` question is really about.

### Measured

Same public interface, different function body:

```
public fun answer() -> Int32 { 42 }   →  Support.hylomodule sha = c334b4bc… (645 bytes)
public fun answer() -> Int32 { 43 }   →  Support.hylomodule sha = c3cc934b… (645 bytes)
```

**The archive changes on a pure implementation edit.** Inspecting `Module.archive` confirms why: it
serializes syntax trees, semantic properties, *and* `ir.functions` (the lowered function bodies).
The `.hylomodule` is simultaneously:

- the **interface** a dependent needs to type-check against, and
- the **compiled IR** — the implementation.

So any change that touches a body perturbs the archive, and every dependent that lists it in
`OBJECT_DEPENDS` rebuilds — even though nothing they can observe changed. Hylo's separate-compilation
advantage is silently thrown away at the build-graph level.

### Why this matters more for Hylo than for Swift

Swift sidesteps this: `.swiftmodule` is the interface, object files are separate, and CMake depends
on the `.swiftmodule`. A Swift implementation-only change *still* often invalidates
`.swiftmodule` (it contains `@inlinable` bodies, SIL for optimization, etc.), but Swift's model
never promised otherwise. Hylo's whole pitch is that a non-`@frozen`, non-inlinable change should
**not** reach dependents. The current archive breaks that promise.

### The `@frozen` axis

The user's framing is exactly right: a dependent must rebuild when a dependency's change is
*observable to it*, and not otherwise. Observability has layers:

| Change to a dependency | Must a dependent recompile? | Must it relink? |
|---|---|---|
| private function body | no | yes (new object) |
| public non-frozen type's layout | no (accessed opaquely) | yes |
| public function signature | **yes** | yes |
| `@frozen` type's layout | **yes** (dependent inlines the layout) | yes |
| adding a public declaration | no (unless it changes overload resolution) | yes |
| `@inlinable` body | **yes** (dependent may inline it) | yes |

The relink column is almost always "yes" — a new object means a new link. The *recompile* column is
the valuable one, and it is governed by whether the change crosses the module's **ABI/API surface**,
of which `@frozen` layout and inlinable bodies are the sharp cases.

### Status of `@frozen` / resilience in Hylo today

Checked the tree. `@frozen` is **documented but not enforced**: `Program.isLayoutVisible`
(`Sources/FrontEnd/Program.swift:685`) currently hardcodes `return true`, with the doc comment
describing the intended resilience behavior ("if resilience is enabled … visible if `d` is in the
same module or annotated with `@frozen`"). So *today* Hylo always inlines struct layouts across
module boundaries — every struct behaves as if `@frozen`. `storedPropertyIndex`
(`IREmitter.swift:1949`) already routes through `isLayoutVisible`, so the hook is in place; only the
policy is stubbed.

This matters for the interface hash: **once resilience lands**, a non-`@frozen` struct's layout
change must *not* invalidate dependents, but a `@frozen` struct's layout change *must*. The
interface hash is exactly where that distinction should be encoded — and because the compiler
already has `isLayoutVisible`, it is the right place to decide it. The build system stays oblivious.

Until resilience is implemented, the conservative-correct behavior is that *any* layout change
invalidates dependents (because every layout is effectively frozen/inlined). The prototype hash
below folds struct layouts in explicitly to match this (§"Prototype limitations"), and is the
natural place to consult `isLayoutVisible` once resilience makes some layouts non-observable.

### Proposal: split the interface hash from the archive

The build system does not need the compiler to be clever. It needs **one number**: a hash of the
module's *externally observable surface*, stable across changes that cannot affect dependents.

Concretely, have `hc` emit, alongside the archive, an **interface fingerprint** — a hash over:

- public/exported declaration signatures (names, types, mangled symbols),
- `@frozen` type layouts (because dependents encode them),
- `@inlinable` / generic bodies that dependents may instantiate or inline,
- **but not** private declarations or non-frozen, non-inlinable bodies.

Then:

- `hc --emit-module-interface-hash <file>` writes just that hash (proposal).
- The build system depends on **the hash file**, not the archive. Ninja `restat = 1` on the hash's
  producing edge means: if a rebuild leaves the hash unchanged, downstream compiles do not fire.
- The dependent still relinks against the new object (correctness), but does not re-typecheck.

This is the same idea as Swift's `.swiftmodule`-vs-`.swiftdeps` split and C++20 BMIs, but Hylo can
make the interface genuinely minimal *because it has separate compilation* — the interface need not
carry bodies at all except the inlinable/generic ones.

Who should track `@frozen`? **The compiler**, because only it knows the layout and which bodies are
inlinable. The build system should treat "did the interface hash change?" as opaque. Putting
`@frozen`-invalidation logic in the build system (or worse, in `AddHylo.cmake`) would duplicate
compiler knowledge and rot. This directly answers the user's "maybe that should be tracked by the
compiler, idk" — yes, and the interface hash is the API boundary that lets the build system stay
dumb.

### Cheap first step, before the full split

Even without separating interface from implementation, a large win: make the archive
**deterministic and content-stable for non-observable changes** by computing the fingerprint over
the *interface* rather than the *sources*. Today `Module.fingerprint` is
`SourceFile.fingerprint(contentsOf: sources)` — a **source-text** hash. So even a comment edit
invalidates it. An interface-derived fingerprint would already skip comment/whitespace/body-only
edits for the caching path in `Driver.load`.

### Prototype: implemented and measured

Implemented `hc --emit-module-interface-hash <file>` this session (`Driver.moduleInterfaceHash`).
It hashes the sorted mangled names of the module's IR functions — mangled names encode the full
signature (name, parameters, output) but not the body — and **skips functions that are ABI-private**
via the existing `Program.isPrivate(_:in:)` predicate.

Measured behavior (FNV-1a of sorted mangled signatures):

| Edit to `Support` | interface hash | archive sha | correct? |
|---|---|---|---|
| `answer()` body `42` | `ad46…a917` | `cb7e…` | baseline |
| `answer()` body `43` | `ad46…a917` (same) | `795f…` (changed) | ✓ dependent skips recompile |
| `answer()` body `99` | `ad46…a917` (same) | changed | ✓ content-addressed |
| add private `helper()` | `ad46…a917` (same) | changed | ✓ private is ABI-invisible |
| change private `helper` body | `ad46…a917` (same) | changed | ✓ |
| rename `answer`→`the_answer` | `c9e7…2790` (changed) | changed | ✓ dependent rebuilds |
| add public `bonus()` | `9405…9fef` (changed) | changed | ✓ |
| make `answer` private | `cbf2…2325` (changed) | changed | ✓ symbol left the ABI |

**End-to-end payoff, demonstrated:** edit `Support`'s body `42`→`99`, rebuild `Support` → interface
hash unchanged → `Main.o` (compiled against the old body) is **not** recompiled, only **relinked**
against the new `Support.o` → the program returns `99`. The new behavior is picked up without
recompiling the dependent. That is Hylo's separate-compilation advantage, realized at the build
level for the first time. Rust cannot do this for a generic; it would have monomorphized `answer`
into `Main`.

All 416 Hylo tests still pass with these changes.

### Capstone: the skip works in a real build graph — and needs one more thing from CMake

Modeled the full incremental scenario in hand-written Ninja (compile rule with `restat = 1`,
dependent depending on `Support.iface`). Editing `Support`'s body `42`→`99`:

```
[1/3] hc … --emit-module-interface-hash Support.iface … Support.hylo   # Support recompiles
[2/2] clang Main.o Support.o shims.c -o app                            # <-- note: 2/2, not 3/3
```

Ninja ran the `Support` compile, its `restat` found `Support.iface` **unchanged**, and it
**pruned `Main.o` from the build** — the dependent was not recompiled, only the final link ran.
`./app` → `99`: the new body is present, picked up purely by relinking.

This required a **third** compiler change beyond the hash itself: **write the interface-hash file
only when its content changes.** Ninja's `restat` compares mtime; if `hc` rewrote an identical
`.iface` every run, the mtime would bump and the skip would never fire. `hc` now reads the existing
file and leaves it untouched when unchanged — the same discipline swiftc uses (CMake's Swift code
notes "swiftc leaves outputs untouched"). Without it, `Main.o` rebuilt every time; with it, it is
correctly skipped. Verified both ways.

**The one missing piece for real CMake:** the generic `CMAKE_<LANG>_COMPILE_OBJECT` rule does not
emit `restat = 1` (only link rules do; Swift sets it in C++ via `vars.emplace("restat", "1")`).
Measured: in the actual CMake build, a body-only edit to `Support` *does* recompile the dependent
`multi`, because the Hylo compile edge lacks restat and the dependent depends on the archive.
So the payoff is real and proven, but landing it in CMake needs the same C++ trait work as
everything else — a whole-module language needs (a) its interface artifact as a true output and
(b) `restat` on its compile rule. This is the concrete link between the `hc` changes here and the
upstream work in UPSTREAM-MULTIFILE-MODULES.md: they meet exactly at restat.

### Prototype limitations (honest)

1. **Layout is now folded in explicitly (implemented).** The hash was extended beyond function
   signatures to include, for each ABI-visible struct, its name plus its ordered
   `(fieldName, mangled fieldType)` list. Measured on a struct with a body-only sibling change:

   | Change to a module with `struct P { a, b }` + `fun f` | hash | correct? |
   |---|---|---|
   | `f`'s body `1`→`2` | stable | ✓ ignored |
   | add public field `c` | moved | ✓ caught |
   | reorder fields `a,b`→`b,a` | moved | ✓ caught |

   This closes the earlier signature-only soundness gap for struct layouts. Two caveats remain:
   (a) it is gated on nothing yet — once resilience/`@frozen` lands, a *non-*`@frozen` struct's
   layout change should stop invalidating dependents, which means consulting `isLayoutVisible`
   here; (b) enums and other aggregate layouts are not yet folded in. The mechanism (compiler walks
   ABI-visible decls, emits a stable digest) is proven; extending it to every layout-bearing type
   is mechanical.
2. **Empty-module sentinel.** A module with no ABI-visible functions hashes to the FNV offset basis
   (`cbf29ce484222325`). Distinct from any populated hash, so correct, but worth a real "no
   exports" marker.
3. **Not conformances/witness tables.** Trait conformances a dependent relies on should be in the
   hash; the prototype only covers functions. `witnessTables` is already in the archive, so the
   data is available.
4. **Mangling stability = hash stability.** The hash inherits whatever the mangler encodes. If two
   observably-different signatures mangle identically (they should not), the hash would miss it.

None of these are blockers for the design; they are the difference between a 60-line prototype and a
production interface digest. The prototype proves the *mechanism* — a compiler-computed,
body-independent, ABI-scoped fingerprint the build system can depend on — works and is cheap.

Two more honest gaps in the prototype, for completeness:

5. **Only top-level structs.** The layout walk iterates `topLevelDeclarations`; structs nested in
   namespaces/extensions are not folded in. Mechanical to extend, same as enums (limitation 1).
6. **Cyclic imports would recurse unboundedly.** `loadArchivedModule` guards against *already
   loaded* modules but registers a module only after its `program.load` returns, so a hypothetical
   A→B→A cycle would recurse. Hylo module dependencies are a DAG by construction (you cannot import
   a module that transitively imports you — it must be compiled first), so this cannot arise today;
   a visiting-set guard would make it defensive.

## 4. Ranked recommendations for `hc`

Ordered by value-to-effort, from this session's evidence:

1. **Interface fingerprint / `--emit-module-interface-hash`** (§3). The keystone, prototyped and
   proven end-to-end. Unlocks Hylo's separate-compilation advantage at the build-graph level.
   Compiler tracks `@frozen`/inlinable; build system depends on the hash. **Must write-if-different**
   (only rewrite the file when content changes) or mtime-based restat can't skip — this is not
   optional, it is what makes the whole thing work.
2. **Keep the multi-module CLI** (§1) — `--emit-module-to`, `--import`, working `-L`. Implemented;
   should be upstreamed. It is the foundation everything else builds on.
3. **`--emit-module` as a distinct output type** decoupled from object emission, so the interface
   can be produced on its own earlier edge (like Swift's `CMAKE_Swift_EMIT_MODULE` / CMP0215).
   Lets dependents unblock before the dependency's codegen finishes.
4. **Depfile / `-MD` equivalent.** `hc` should be able to emit the list of files/modules a
   compilation actually read, so the build system tracks real dependencies instead of the whole
   source list. Swift does this via the output-file-map's `dependencies` entries.
5. **Stable diagnostics/exit contract for build tools.** The `-o`-as-directory foot-gun is fixed
   (FINDINGS.md); a machine-readable diagnostic mode (`--diagnostics-format json`) would let IDEs
   and CMake surface errors without scraping text.
6. **`--version`** (still missing) so the language module can report a real compiler version and key
   the module-cache format on it.

## 5. What this says about the CMake side

- The Modules-only integration can now express a real Hylo **module graph** (libraries + imports +
  ordering), not just single targets. That is further than I expected to get without patching CMake.
- The two remaining ceilings are both in UPSTREAM-MULTIFILE-MODULES.md: (a) the interface artifact
  can't be a true compile output (phony workaround, §2), and (b) `$<TARGET_OBJECTS>` on a
  whole-module target is still wrong. Both want the same C++ trait —
  `CMAKE_<LANG>_COMPILES_WHOLE_MODULE` + a fixed object map.
- With the interface hash (§3), the CMake side would depend on `Support.iface-hash` instead of
  `Support.hylomodule`, and unnecessary dependent rebuilds would vanish — the payoff of Hylo's
  separate compilation, finally visible in the build graph.
