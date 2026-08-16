# Proper upstream support for multi-file modules in CMake

Research notes: what it would actually take to add a *first-class* whole-module
(N sources → 1 compile) language to CMake, instead of the `HEADER_FILE_ONLY` workaround in
[FINDINGS.md](FINDINGS.md).

Based on CMake 4.4 dev (`Source/CMakeVersion.cmake`: 4.4.20260717), read and **verified by
running a locally built CMake 4.4** against a real `swiftc` 6.3.

## Bottom line

**The feature does not exist, and it cannot be built from `Modules/*.cmake` at all.** Every
non-1:1 language in CMake — Swift, Rust, ISPC, C# — is a hardcoded `lang == "..."` string
compare in C++. There is no aggregate-compile abstraction to hook into.

But the interesting finding is not "it's hard". It's this:

> **Upstream already built the whole-module compile edge for Swift, and its single-object
> variant is broken *today*. Hylo would live permanently in the exact corner where it
> breaks.**

So the work is not "add a feature". It is "finish and generalize a feature upstream started
in 2023 and left with a known hole" — and Hylo is the language that makes that hole
load-bearing rather than incidental.

## 1. What already exists

Four languages already break 1:1, four different ad-hoc ways. None is a mechanism anyone
else can reuse.

| Language | Model | Breaks 1:1 by | Generators |
|---|---|---|---|
| **Swift** | 1 compile edge per target, N sources → 1 *or* N objects | **N sources → 1 edge** (aggregation) | Ninja, Xcode |
| **Rust** | per-source `.rlib` crates + crate root fused into *link* edge | **1 source → 0 objects** (elision) | Ninja + **Makefiles** |
| **ISPC** | 1 source → N objects, via `ImplicitOuts` | **1 source → N objects** (fan-out) | Ninja, Makefiles |
| **C#** | whole target delegated to MSBuild | **target → 0 objects** (delegation) | **VS only** |

**Only Swift is actually whole-module aggregation.** Rust looks like it but isn't: each non-root
`.rs` gets its own per-source edge producing an `.rlib` (a separate crate, passed to the link as
`--extern=name=path` — `cmCommonTargetGenerator.cxx:671`), and the crate root is compiled *at the
link edge* (`cmNinjaNormalTargetGenerator.cxx:1295`), with `rustc` discovering the module tree
itself via `mod` declarations. CMake never hands N sources to one `rustc`. Rust's contribution is
its *classification* mechanism, not its compile model.

`Modules/CMakeDetermineCSharpCompiler.cmake:4` and
`Modules/CMakeDetermineSwiftCompiler.cmake:52` both simply `FATAL_ERROR` on unsupported
generators. That is the established upstream pattern for aggregate-compile languages: refuse
the generator rather than implement it.

### Swift is the closest shape

`cmNinjaTargetGenerator.cxx:1289-1306` is the only whole-module escape hatch in the tree:

```cpp
for (cmSourceFile const* sf : objectSources) {
  if (this->GetLocalGenerator()->IsSplitSwiftBuild() &&
      sf->GetLanguage() == "Swift") {
    swiftSources.push_back(sf);          // hoist out of the per-source loop
  } else {
    this->WriteObjectBuildStatement(sf, config, fileConfig, firstForConfig);
  }
}
WriteSwiftObjectBuildStatement(swiftSources, config, fileConfig, firstForConfig);
```

`WriteSwiftObjectBuildStatement` (`:2081`, ~260 lines) is a parallel reimplementation of
`WriteObjectBuildStatement` that emits **one edge with N `ExplicitDeps`**. Landed in
`9bed4f4d81` "Swift/Ninja: Split compilation model" (Evan Wilde, Nov 2023 → CMake 3.29,
issue #25308), gated by policy **CMP0157**, ~323 insertions across 9 files.

Observed ground truth (CMake 4.4 + swiftc 6.3, `wholemodule`):

```
build CMakeFiles/wm.dir/a.swift.o CMakeFiles/wm.dir/b.swift.o: Swift_COMPILER__wm_unscanned_ a.swift b.swift
  FLAGS = -module-name wm -wmo -output-file-map CMakeFiles/wm.dir//output-file-map.json
  description = Building Swift Module 'wm' with 2 sources
  restat = 1
```

One edge, two sources, two outputs. Note there is **no `<SOURCES>` placeholder** — `<SOURCE>`
is simply bound to ninja's `$in`, the whole list.

### Rust is the better *mechanism*

Rust (experimental in 4.4, `cmExperimental.cxx:65`) introduces a new **SourceKind**
(`cmGeneratorTarget.h:149`) so the aggregating source never enters the object map at all
(`cmGeneratorTarget_Sources.cxx:441-461`):

```cpp
if (sf->GetOrDetermineLanguage() == "Rust") {
  if (this->Target->GetType() == cm::TargetType::OBJECT_LIBRARY) {
    kind = SourceKindObjectSource;
  } else if (!rustMainCrateRootSf) {
    rustMainCrateRootSf = sf;            // defaults to the FIRST Rust source
    kind = SourceKindRustMainCrateRoot;
  }
  ...
```

Two things worth noticing:

- Upstream picks **"the first source"** as the aggregation point, exactly like
  `hylo_add_executable()` does — but with a real classification and a `Rust_MAIN_CRATE_ROOT`
  property to override it. Our `HEADER_FILE_ONLY` hack is a userspace shadow of this: the
  `HEADER_FILE_ONLY → SourceKindHeader` branch sits *four lines above* the Rust code.
- Rust works on **Ninja *and* Makefiles** (8 `Rust` hits in `cmMakefileTargetGenerator.cxx`);
  Swift works on neither Makefiles nor VS (**0** hits each).

## 2. The root obstacle: the object map is 1:1 by type

This is the finding that matters. The assumption is not scattered logic — it is a **data
structure**, `cmGeneratorTarget.h:1205`:

```cpp
mutable std::map<cmSourceFile const*, cmObjectLocations> Objects;
```

One source key → one `cmObjectLocations` value. And `cmObjectLocations`
(`cmObjectLocation.h:37`) is *not* a list — it holds `ShortLoc` / `LongLoc` /
`InstallLongLoc`, which are **path-spelling variants of a single object**.

The accessor cements it (`cmGeneratorTarget.cxx:866`):

```cpp
std::string const& cmGeneratorTarget::GetObjectName(cmSourceFile const* file)
{
  this->ComputeObjectMapping();
  return this->Objects[file].GetPath(useShortPaths);
}
```

Returning `std::string const&` — a reference *into* the map — means the type can express
neither "this source produces **no** object" nor "these N sources **share** one object".
Everything downstream reads through this: `$<TARGET_OBJECTS>`, `install(TARGETS ... OBJECTS)`,
the file API, and all six `ComputeObjectFilenames` overrides.

**Swift's whole-module path does not fix this. It bypasses it** — synthesizing its own name at
`cmNinjaTargetGenerator.cxx:2221` and pushing straight into `Configs[config].Objects`,
sidestepping the map entirely. So the map is left holding stale, source-derived names.

## 3. The consequence, reproduced

The 2023 commit message admitted the hole:

> Object libraries still don't completely work with this patch because... the `TARGET_OBJECTS`
> generator expression expansion has a separate mechanism for determining what the names of the
> objects are based on the input source files, so targets that depend on an object library built
> with a whole-module optimization will depend on objects based on the name of the source file
> instead of the actual emitted object file.

**Still true in CMake 4.4, ~2.5 years later.** Reproduced with a locally built CMake 4.4:

```cmake
add_library(objs OBJECT a.swift)
set_property(TARGET objs PROPERTY Swift_COMPILATION_MODE wholemodule)
```

```
$ cmake -B b2 -G Ninja -DCMAKE_Swift_NUM_THREADS=0
$<TARGET_OBJECTS:objs>  claims:   CMakeFiles/objs.dir/./a.swift.o
the compile edge actually emits:  CMakeFiles/objs.dir/objs.o
```

`TARGET_OBJECTS` names a file that is **never produced**. The generator expression and the
build graph disagree, silently.

### Why this is *the* Hylo problem, not a footnote

The single-object path is guarded by `isSingleOutput` (`cmNinjaTargetGenerator.cxx:2153`):

```cpp
return !isMultiThread && compileMode == cmSwiftCompileMode::Wholemodule;
```

...but `Modules/CMakeSwiftInformation.cmake:114` defaults `CMAKE_Swift_NUM_THREADS` to the
logical core count, so `isMultiThread` is essentially always true. **The single-object path is
dead by default**, which is why the bug has survived: Swift almost always emits one object
*per source*, keeping the 1:1 map accidentally truthful. I had to pass
`-DCMAKE_Swift_NUM_THREADS=0` to reach it.

Hylo has no such escape. `hc` emits **exactly one object per module, always**. There is no
thread count that makes `hc` produce `main.hylo.o` and `support.hylo.o`. So Hylo does not
merely *use* the whole-module path — it lives permanently in the one configuration that is
known-broken and effectively untested.

**Adding Hylo properly therefore requires fixing the object map, not just reusing Swift's
edge.** That is the honest headline.

## 3.5 Can the model be unified across the existing hacks?

**Yes — the *object model* unifies, cleanly, and it is the single highest-value change. The
*emission* does not unify, and should not be forced to.**

### The evidence: four evasions of one data structure

Nobody extended `map<cmSourceFile const*, cmObjectLocations>`. Everybody went around it, each a
different way:

| Language | Evasion | Where |
|---|---|---|
| Swift | **bypasses** the map — synthesizes its own object name, pushes straight into `Configs[config].Objects` | `cmNinjaTargetGenerator.cxx:2221`, `:2237` |
| ISPC | **side-maps** — private `ISPCGeneratedObjects` / `ISPCGeneratedHeaders` on `cmGeneratorTarget` | `cmGeneratorTarget.h:1400`, `:1403` |
| Rust | **reclassifies** — `SourceKindRustMainCrateRoot` removes the source from `SourceKindObjectSource` | `cmGeneratorTarget_Sources.cxx:441` |
| C# | **exempts** — `IsCSharpOnly()` makes the whole target have no objects | `cmGeneratorTarget.cxx:5275` |

Four workarounds, one cause. That is what a missing abstraction looks like. And the cost is
visible: the Swift bypass *is* the reproduced `TARGET_OBJECTS` bug in §3 — the map keeps
source-derived names that no rule ever produces.

### The unification: compile groups

Every case is an instance of **one compile edge owns a set of sources and declares a set of
outputs**:

| Shape | Sources → outputs | Language |
|---|---|---|
| 1 → 1 | one source, one object | C, C++, Fortran |
| 1 → N | one source, many objects | ISPC |
| N → 1 | whole module, one object | **Hylo** |
| N → N | whole module, one object per source | Swift (default) |
| 1 → 0 | source consumed by another edge | Rust crate root |

The current type is hardwired to row 1. Replace

```cpp
mutable std::map<cmSourceFile const*, cmObjectLocations> Objects;
```

with a group-keyed map plus a source→group index, and every row above becomes expressible.
`GetObjectName(sf)` (which returns `std::string const&`, so it can encode neither zero nor
shared) becomes a query on the group.

That one change subsumes all four evasions: Swift stops bypassing, ISPC's side-map becomes the
general case, Rust's SourceKind becomes "group with no object output", and `$<TARGET_OBJECTS>`,
`install(... OBJECTS)`, and the file API get correct answers for free — because they'd finally be
reading the same structure the generator writes.

### Two findings that make this narrower than expected

**Swift's compilation mode is not topology.** Verified against CMake 4.4 + swiftc 6.3 —
`wholemodule` and `incremental` emit the *identical* Ninja graph, differing only in a flag:

```
build .../wm.dir/a.swift.o .../wm.dir/b.swift.o : Swift_COMPILER__wm_  a.swift b.swift
  FLAGS = -module-name wm  -wmo         -output-file-map ...
build .../inc.dir/a.swift.o .../inc.dir/b.swift.o: Swift_COMPILER__inc_ a.swift b.swift
  FLAGS = -module-name inc -incremental -output-file-map ...
```

CMake always emits **one edge per target** for Swift; incrementality is delegated to `swiftc`
via the output-file-map and `.swiftdeps`. So the trait is a **boolean** ("this language batches
per target"), not a mode enum — `cmSwiftCompileMode` is a flag selector that need not be
generalized at all.

**Rust is not aggregation** (see §1), so it is not a second data point for the Swift shape. Swift
is the *only* aggregating language in CMake today. Hylo would be the second — which is precisely
why the abstraction was never forced into existence.

### What does not unify, and shouldn't

- **C# is not a compile model, it's backend delegation.** MSBuild owns the compile; CMake emits
  no edge. It fits row "target → 0 outputs" only trivially, and folding it in buys nothing.
  `IsCSharpOnly()` is target-type routing, not object accounting.
- **Output-naming protocols stay per-language.** swiftc's output-file-map is an Apple driver
  protocol (`cmNinjaTargetGenerator.cxx:2484` cites the spec); `hc` and `rustc` use plain flags.
  This belongs in the rule template, not the model.
- **Link fusion** (Rust, Swift-CMP0157-OLD) is a different axis — arguably a *workaround* for the
  missing object model. With compile groups, Rust's crate root could have a real compile edge.
- **Interface artifacts are a separate, and arguably more duplicated, unification.**
  `.swiftmodule` (emit-module edge, CMP0215), C++20 BMIs (`WriteCxxModuleBmiBuildStatement`),
  and Fortran `.mod` are three implementations of "publish the interface before the
  implementation so consumers unblock early". `LanguageEmitModuleRule` (`:133`) is *already*
  written generically over `lang` — only its call sites hardcode Swift. Hylo does not need this
  yet (it has no module interface artifact — see FINDINGS.md), so it is out of scope here, but
  it is the better second target.

### Honest caveat

This is a refactor of `cmGeneratorTarget`'s core data structure touching ~10 `GetObjectName` call
sites, 6 `ComputeObjectFilenames` overrides, and every object-list consumer. It is the kind of
change that needs a maintainer's buy-in *before* code, not after. The status quo — four bespoke
mechanisms and a documented refusal to support out-of-tree languages
(`Modules/CMakeAddNewLanguage.txt:1-16`) — may well be a deliberate choice to avoid exactly this
churn for a payoff that, today, benefits one-and-a-half languages.

## 4. What a proper design looks like

The pieces exist; none of them are joined up. A real design = **Rust's classification +
Swift's emission + a fixed object map**, with `IsSplitSwiftBuild()`, `== "Swift"`, `== "Rust"`
and `IsCSharpOnly()` all collapsing into one per-language trait.

### 4.1 The trait

Precedent for a Modules-file variable changing graph topology already exists, and it is exactly
this — just hardcoded to Swift (`cmLocalGenerator.cxx:3072`):

```cpp
bool cmLocalGenerator::IsSplitSwiftBuild() const
{
  return cmNonempty(this->GetMakefile()->GetDefinition(
    "CMAKE_Swift_COMPILATION_MODE_DEFAULT"));
}
```

Set in `Modules/CMakeSwiftInformation.cmake:91`, read back in C++, flips per-source vs
per-target. It is undocumented (zero hits in `Help/`).

Generalize to `CMAKE_<LANG>_COMPILES_WHOLE_MODULE`, following the naming of
`CMAKE_<LANG>_USE_LINKER_INFORMATION` (the only per-language trait
`Modules/CMakeAddNewLanguage.txt:30` documents) with the read mechanism of
`COMPILATION_MODE_DEFAULT`. Two read paths exist:

- **Lazy** — `Makefile->GetDefinition` at generate time (what `IsSplitSwiftBuild` does; least
  invasive).
- **Eager** — snapshot into a map in `cmGlobalGenerator::SetLanguageEnabledMaps`
  (`cmGlobalGenerator.cxx:1288`), like `LanguageToLinkerPreference`. Deliberately runs *after*
  the compiler/platform files load (see the comment at `:1256-1267`) precisely so
  `CMake<LANG>Information.cmake` can influence it.

### 4.2 The object map (the hard part)

`GetObjectName` must be able to say "no object" and "shared object". Minimally:

- `map<cmSourceFile const*, cmObjectLocations>` gains a notion of a **target-level** object, or
  aggregating sources get a new `SourceKind` (generalizing `SourceKindRustMainCrateRoot`) and
  are removed from `SourceKindObjectSource`.
- `GetObjectName`'s `std::string const&` return must become optional/by-value.
- `GetTargetObjectLocations` (`cmGeneratorTarget.cxx:4262`) — a *second*, duplicated 1:1
  mapping — must agree with the emission path. This is what fixes the reproduced bug.

`HasKnownObjectFileLocation` (`cmGlobalGenerator.h:592`; only Xcode overrides it) is the
existing "we can't enumerate objects" veto, but it is per-*target* with no per-language
granularity — a hook to generalize, not to reuse as-is.

### 4.3 Work inventory

**Tier 1 — unavoidable, no workaround**
1. `cmGeneratorTarget.h:1205` + `cmLocalGenerator.h:570` — the map type; 6 `ComputeObjectFilenames` overrides.
2. `cmGeneratorTarget.cxx:866` — `GetObjectName` signature; ~10 call sites.
3. `cmGeneratorTarget.cxx:694`/`:711` — `GetObjectSources` / `ComputeObjectMapping`.
4. `cmGeneratorTarget_Sources.cxx:435-465` — generic `SourceKind` for aggregated sources.

**Tier 2 — emission**
5. `cmNinjaTargetGenerator.cxx:1289-1306` + `:2081-2346` — parameterize `WriteSwiftObjectBuildStatement` over language (it hardcodes `std::string const language = "Swift";` at `:2131`); split genuinely-Swift bits (output-file-map, `-parse-as-library`, `-module-link-name`) from generic bits.
6. `cmNinjaTargetGenerator.cxx:715` — the rsp-file carve-out. Whole-module blows command-line limits; the trigger should be "this edge has N sources", not "lang == Swift". **Hylo needs this too.**
7. `cmLocalGenerator.cxx:1427/1538/1574` + `cmNinjaNormalTargetGenerator.cxx:471/540/1239/1633` — `!= "Swift" && !IsSplitSwiftBuild()` link-line branches.

**Tier 3 — consumers**
8. `$<TARGET_OBJECTS>` (`cmGeneratorExpressionNode.cxx:4859`), `install(... OBJECTS)` (`cmInstallCommand.cxx:1003`), export (`cmExportBuildFileGenerator.cxx:61`), file API (`cmFileAPICodemodel.cxx:2213`), plus private mapping copies in `cmGlobalVisualStudioGenerator.cxx:677` and `cmFastbuildNormalTargetGenerator.cxx:674`.

**Tier 4 — other generators**
9. Makefiles: no aggregate path at all, and `cmMakefileTargetGenerator.cxx:623-634` actively *warns and bails* on duplicate object names — it blocks N:1 head-on. Either implement (Rust shows it's possible) or `FATAL_ERROR` in `CMakeDetermineHyloCompiler.cmake` as Swift/C# do.
10. Xcode delegates; VS unsupported. Neither blocks nor helps.

**Tests** (`Tests/RunCMake/Swift/RunCMakeTest.cmake` is the template): a `CMake_TEST_<Lang>` guard + probe, a `RunCMake/<Lang>/` dir, a `NotSupported` case per refused generator, and `--build . -- -n -v` dry-run stdout baselines *per generator* — these assert on the generated command line without needing a working toolchain, which is how to test this without shipping `hc` to CI.

### 4.4 What Hylo needs that Swift does not

| | Swift | Hylo |
|---|---|---|
| Objects per module | N (1 per source) by default | **always exactly 1** |
| Output naming | output-file-map (swiftc driver protocol) | plain `-o <file>` |
| Module interface artifact | `.swiftmodule`, separate emit edge (CMP0215) | none yet (see FINDINGS.md — archive is computed and discarded) |
| Incremental / singlefile modes | yes | no — whole-module is the only mode |
| Scanning / dyndep | no | no |

Hylo is a *simpler* consumer than Swift: no output-file-map, no compilation-mode abstraction,
no emit-module edge. It needs precisely the one path Swift has but does not exercise. That
makes Hylo a good forcing function for fixing the map — and a bad candidate for
"just reuse `WriteSwiftObjectBuildStatement`".

## 5. Recommendation

1. **Do not attempt this out-of-tree.** `Modules/CMakeAddNewLanguage.txt:1-16` disclaims the
   whole layer as internal API with no compatibility guarantee, and every mechanism required
   here lives in C++ that an out-of-tree language cannot touch. The `HEADER_FILE_ONLY` approach
   in FINDINGS.md is the ceiling of what modules alone can express, and it is a genuine ceiling,
   not a lack of cleverness.
2. **The tractable upstream contribution is not "add Hylo".** It is *"make `$<TARGET_OBJECTS>`
   agree with the build graph for whole-module Swift"* — a real, reproducible, already-admitted
   upstream bug (#25308's leftover) with a Swift reproducer that needs no Hylo at all. That
   forces Tier 1, which is the actual blocker. It is independently valuable, reviewable on its
   own merits, and lands the hard part.
3. **Then generalize the trait** (Tier 2), converting `IsSplitSwiftBuild()` into
   `CMAKE_<LANG>_COMPILES_WHOLE_MODULE`. At that point Hylo is a Modules-file + a small trait
   flip, and Rust/C# could plausibly collapse onto it too.
4. **Expect a policy.** Every behavior change here got one (CMP0157 for the split model, CMP0215
   for separate module emission). Fixing `TARGET_OBJECTS` names changes observable output paths,
   so it likely needs its own.

Worth confirming with upstream before writing code: whether Kitware *wants* a generic
whole-module abstraction, or considers per-language special-casing acceptable. The evidence
suggests the latter is the status quo by choice — four languages, four bespoke mechanisms, and
a documented refusal to support out-of-tree languages. That is a design conversation
(issue #25308 is the natural thread), not a patch.

## Reproducing

```sh
# Build CMake 4.4 from this tree (~15 min)
cmake -S . -B build-cm -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && ninja -C build-cm

# The TARGET_OBJECTS bug (needs swiftc)
cd /tmp/swift-objlib   # add_library(objs OBJECT a.swift) + Swift_COMPILATION_MODE wholemodule
build-cm/bin/cmake -B b2 -G Ninja -DCMAKE_Swift_COMPILER=$(which swiftc) -DCMAKE_Swift_NUM_THREADS=0
grep -o "TARGET_OBJECTS=[^ ]*" b2/build.ninja      # => .../a.swift.o
grep -E "^build .*objs.*:" b2/build.ninja          # => .../objs.o     (disagree)
```
