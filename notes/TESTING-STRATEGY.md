# Testing strategy for the CMake integration

What it takes to trust `FindHylo.cmake`/`HyloTargets.cmake` as *the* way to build
Hylo with CMake: which properties must hold, how each is tested, what the CI
matrix should look like, and which experiments are still needed to find the
integration's real limits. Current state (2026-08-29, phase 1 of section 10
implemented; phases 2–3 on 2026-08-29 as well): 17 behaviour tests + the
randomized incremental fuzzer + exit-status tests; 17 PR CI jobs — hc v0.0.8
default, every config tested on both CMake 3.30.0 and latest (a matrix
axis), gating Visual Studio 2022/2026
jobs (Xcode: unsupported, curated diagnostic) — plus a Nightly workflow
(toolchain variants, macOS x64, Windows arm64, CMake latestrc, latest-hc
canary, aarch64+qemu cross job, fuzzer). The `probe_hash_precise` capability
probe drives the incremental assertions and reports its verdict in their
output.
Remaining hand experiments: MinGW, case-collision (§7).

## 1. The invariants

Everything below tests one of five properties. Naming them keeps the matrix
honest: a new job or test should say which invariant it strengthens.

| # | invariant | nature |
|---|---|---|
| **I1** | **Soundness**: after any sequence of edits, an incremental build produces a program behaviorally identical to a from-scratch build. Never under-rebuild. | must hold on **every** generator/OS/version |
| **I2** | **Precision**: when a dependency's interface hash is unchanged, dependents are not recompiled. | Ninja-family only (restat); elsewhere over-rebuild is acceptable, under-rebuild never is |
| **I3** | **Fidelity**: flags, imports, search paths, and the target triple reach `hc` exactly as declared, with correct PRIVATE/PUBLIC/INTERFACE and per-config scoping. | everywhere |
| **I4** | **Portability**: the same CMakeLists works unmodified across OSs, C toolchains, generators, and supported CMake versions. | the matrix itself |
| **I5** | **Diagnostics**: everything unsupported fails *loudly at configure time* with a curated message (CMake < 3.30, OBJECT libraries, hc too old / missing / broken). | everywhere |

I1 deserves emphasis because the current interface hash is conservative (a hash
of the whole archive, bodies included — hylo-lang/hylo-new#321). That
conservatism *masks* under-rebuild bugs: today a body edit changes the hash and
cascades, so a missing dependency edge would go unnoticed. **The day the hash
becomes precise, every latent under-rebuild bug surfaces at once.** The strategy
must therefore (a) test soundness independently of the hash's precision, and
(b) be ready to flip precision expectations without rewriting the suite — see §3.

## 2. Matrix dimensions and tiering

The full cross product (5 OS/arch × 4 CMake versions × 7 generators × 4 C
toolchains × configs × cross-targets) is thousands of cells. Tier it:

- **Tier 1 — every PR** (~12 jobs, < 15 min): one job per *risk*, not per
  combination. Each generator appears once, each OS at least once, the CMake
  floor and latest each once.
- **Tier 2 — nightly/weekly** (`workflow_dispatch` + `schedule`): the fuller
  spread, the incremental fuzzer (§3.4), CMake `dev` nightly, hc-HEAD canary
  (§8), cross-compile + qemu jobs.
- **Tier 3 — one-off experiments**: run by hand to answer "does X work at all",
  then either promoted into tier 1/2 or written down as a limitation in
  `cmake/README.md` (§7).

### 2.1 CMake versions

| version | why | tier |
|---|---|---|
| **3.30.0 exactly** and **latest stable** | the two ends of the supported range, as a full matrix axis: **every PR config runs on both** (`cmake-version` × `config` in ci.yml; the one excluded cell is VS 2026 × 3.30, whose generator CMake 3.30 predates). Custom transitive properties were brand new in 3.30 — the most likely place for behavior differences. | 1 (every job) |
| one middle version (3.31 or 4.0) | catches "worked at both ends, broke in the middle" (the 3.x→4.0 policy break) | 2 |
| CMake `latestrc` | advisory only, in Nightly (get-cmake ships no dev-nightly builds; RCs are the earliest warning available) | 2 |
| **3.28 (negative)** | `find_package(Hylo)` must die with the curated "requires CMake 3.30" message, not an obscure `define_property` error. Verified by hand (2026-08-29); not in CI — installing a second, older CMake per run is not worth the complexity. | manual |

Also once per release cycle: configure with `-Wdev --warn-uninitialized` and
with a fixture whose `cmake_minimum_required` is 4.0 (max policy sweep) — the
modules must be warning-clean under both.

### 2.2 OS / arch / C toolchain

hc releases ship all six platforms — linux/macos/windows × x64/arm64 (verified
on the v0.0.6/v0.0.7 release assets; v0.0.8 publishes the same set) — so the
matrix is bounded by GitHub runners, not by hc.

| cell | C toolchain | status |
|---|---|---|
| Linux x64, arm64 | gcc (default) | in CI |
| Linux x64 + **clang** | clang | in Nightly |
| macOS arm64 (macos-26) | AppleClang | in CI |
| **macOS x64** | AppleClang | in Nightly (`macos-26-intel`) |
| Windows x64 | MSVC | in CI |
| **Windows arm64** | MSVC arm64 | in Nightly (`windows-11-arm`) — the only cell where the MSVC force-link fix runs on a non-x64 CRT |
| Windows x64 + **clang-cl** | clang-cl | in Nightly — validates that the `/INCLUDE:c_malloc_indirect` force-link (fd49534) is not MSVC-linker-specific |
| Windows + MinGW | gcc/COFF | tier 3 experiment: hc emits COFF via LLVM, so MinGW ld *should* link it; nobody has tried. Outcome → README either way. |

### 2.3 Generators

"All generators" concretely means the CMake generators that can appear on a
supported OS. Nothing in the integration is generator-specific except restat
(I2), so the expectation everywhere is: I1 + I3 + I4 hold; I2 is Ninja-only.

| generator | today | plan | expected friction |
|---|---|---|---|
| Ninja | full suite | keep (tier 1) | — |
| Ninja Multi-Config | full suite + dedicated test | keep (tier 1) | — |
| Unix Makefiles | dedicated test (Linux, macOS) | keep (tier 1) | no restat → over-rebuild, accepted |
| **Visual Studio** | **supported** — dedicated test (probes the installed VS — `cmake -E capabilities` lists supported names, not instances) + gating CI jobs for **VS 2026** (windows-latest) and **VS 2022** (windows-2022 image), promoted 2026-08-29 |  | multi-output custom commands become MSBuild CustomBuild steps — supported, but: no restat; `--verbose` output format differs, so the `hc_command` grep in `per-config-flags` needs an msbuild-aware matcher (or that test stays Ninja-only and VS gets its own per-config assert via `-- /v:d` or checking the generated `.vcxproj`); per-project parallelism only |
| **Xcode** | **verdict reached (2026-08-29): unsupported** | negative test asserts the curated diagnostic | the experiment never got to the external-object question: Xcode has no per-config sources, so the per-configuration object path (`$<CONFIG>`) dies at generate time with a literal `NOCONFIG`. `hylo_target_module` now fails at configure with a curated message; README documents it. |
| NMake Makefiles | in Nightly | — | slow, single-config |
| MinGW Makefiles | untested | tier 3, with the MinGW toolchain experiment | — |
| VS + `-T ClangCL`, Watcom, Borland, Green Hills | — | out of scope; say so in README | — |

### 2.4 hc versions

hc now moves faster than this repo (0.0.7 "enable cross-compilation", 0.0.8
"fix build system support & inlinable float ops" — both released within days
of 0.0.6). That makes the compiler version a first-class matrix dimension with
an explicit support policy, mirroring the CMake one:

| version | why | tier |
|---|---|---|
| **v0.0.8 (floor = latest)** | first release with the current stdlib bundle layout (hylo-new#523); 0.0.6–0.0.7 were dropped rather than supported with a dual-layout shim. While floor and latest coincide, one version covers both roles; they split again on the next hc release. | 1 |
| hylo-new HEAD | drift canary, §8; reports `development`, which must satisfy any version request (policy, §6) | 2 |

Version-check semantics are already minimum-style on both paths
(`HyloConfigVersion.cmake` sets `PACKAGE_VERSION_COMPATIBLE` unless
`VERSION_LESS`; FindHylo goes through FPHSA `VERSION_VAR`), so
`find_package(Hylo 0.0.6 REQUIRED)` accepts 0.0.8 — pin that with a test
(request 0.0.6, run 0.0.8, assert found). If a future hc breaks the CLI, the
right response is raising the floor (and the error message), not
compatibility shims; a §6 negative test should cover the too-old direction
(hc 0.0.5, or simulate with a stub `hc` script that has no
`--module-search-path`).

One release-engineering lesson to encode in CI rather than trip over: a
release can exist **before or without its binary assets** (the original 0.0.8
release sat asset-less — and tagged without the `v` prefix — for days before
being rebuilt as `v0.0.8` on 2026-08-29), so the "install Hylo" step should
fail with a clear message when the asset for the cell is missing, not
half-configure. The version-parsing regexes tolerate an optional `v` either
way.

Per-generator portable core (one parametrized behaviour script instead of
copies of `generator-unix-makefiles.cmake`): configure → build → run → edit
propagates (I1) → **second build is a no-op** → `clean` removes `.o`,
`.hylomodule`, `.iface` → for multi-config generators, Debug and Release from
one tree with per-config flags each on their own hc command line.

The "second build is a no-op" check should become a harness rule applied after
*every* mutation in *every* behaviour test (cheap, and it catches always-dirty
edges, restat loops, and commands that touch their own inputs — classic
custom-command bugs).

## 3. Incremental correctness (I1/I2) in depth

### 3.1 The oracle

The only trustworthy oracle for I1 is a clean build: after each mutation,
`(incremental build in tree A) ≡ (fresh configure+build in tree B)` — compared
by program exit status (the repo's convention) and, where cheap, by hashing the
produced objects/archives. Hand-written cases assert specific recompile sets;
the oracle catches everything else.

### 3.2 Separate soundness from precision

The problem: after "edit `Base`'s body", should the test expect `Left` and
`App` to recompile? The honest answer is "it depends on the compiler": with
today's whole-archive hash they do; once hylo-new#321 makes the hash
interface-only they won't. `incremental-interface-hash` currently hard-codes
today's answer, so it will *fail* the day hc improves — and rewriting it then
under time pressure is how soundness checks get lost.

Fix: split every incremental test's assertions into two classes.

**Class 1 — soundness (I1), asserted identically forever.** After any
mutation: the edited module itself recompiled; the resulting program behaves
exactly like a from-scratch build; a second build is a no-op. These
assertions never mention dependents, so they are immune to hash precision.

**Class 2 — recompile set (I2), expectation chosen at runtime.** These
assertions *do* say which dependents recompiled — but instead of hard-coding
either answer, the harness probes the compiler first: compile the same tiny
module twice, with only a function *body* differing, and compare the two
emitted `.iface` files. The result is the `HASH_PRECISE` variable the rest of
this document refers to:

- files differ → `HASH_PRECISE=OFF`, hash is conservative (today): expect
  body edits to cascade;
- files identical → `HASH_PRECISE=ON`, hash is precise (post-#321): expect
  body edits pruned.

| mutation | expected recompiles, conservative hash | expected recompiles, precise hash |
|---|---|---|
| touch, no change | none (restat) | none (restat) |
| body-only edit | module + all dependents | **module only** |
| interface edit | module + all dependents | module + all dependents |

Both branches carry real assertions (the conservative branch isn't a skip:
it's what makes the flip — or any accidental hash change — visible in test
output the moment it happens), and the suite needs zero edits when hc
switches over.

The precise-hash branch also unlocks one soundness case that is *impossible
to test today*: body edited → `Base.o` changed but `Base.iface` didn't →
`Left`/`App` correctly pruned → the executable must still **relink** and pick
up the new body. If the link dependency on the object were ever missing, this
is exactly where a stale binary would slip through — today the conservative
hash forces the recompiles that mask such a bug.

### 3.3 Mutation catalogue

Covered today: touch-without-change, body edit, interface addition, delete
archive, mixed C/Hylo partial rebuild, `target_sources` late addition. Add:

| mutation | must cause | why it's a real risk |
|---|---|---|
| interface *removal* (delete a public fun a dependent doesn't call) | dependents recompile (hash changed) and build still succeeds | asymmetric with addition; exercises hash-shrink |
| comment/whitespace-only edit | module recompiles; with a precise hash, dependents pruned | the flagship #321 payoff case |
| **`Hylo_FLAGS` / `hylo_target_compile_options` change** | affected modules recompile | custom commands rerun on command-line change — but only if the flag genexes actually land in the COMMAND; a flag reaching hc via a response file or env would silently break this |
| dependency edge added/removed in CMakeLists (`target_link_libraries`) | reconfigure; importer recompiles; removed edge → `import` now *fails* (visibility, I3) | the edge set is the whole design |
| new `.hylo` file added to / removed from SOURCES (reconfigure path) | module recompiles with the new file list | complements `late-target-sources`, which only covers `target_sources()` |
| module renamed (`MODULE_NAME`) | old outputs cleaned or ignored; importers rebuilt against new name | stale `.hylomodule` with the old name sits in a search path — can hc pick it up by accident? |
| delete `.o` / delete `.iface` / corrupt `.iface` (truncate) | regenerate, converge | only archive deletion is covered today |
| transitive-only interface change (`Right` in the diamond, not imported by `App` but in its link closure) | App recompiles | the documented conservative closure rule; also the first place to *relax* once the hash is precise, so pin it with a test either way |
| edit during build / two edits within one mtime tick (`file(WRITE)` twice, same size) | eventual convergence: at most one extra rebuild, never a stale binary | restat + write-if-different + coarse mtimes is exactly the combination that produces "sometimes stale" bugs |

### 3.4 Randomized incremental fuzzing (tier 2)

Hand-picked mutations won't find the weird interleavings. Nightly job:

1. Generate a random module DAG (8–15 modules, random PRIVATE/PUBLIC edges,
   each module's functions summing constants from its imports so the exit
   status is a checksum of the whole DAG).
2. Loop ~50 iterations: pick a random mutation from §3.3's catalogue → build
   incrementally → build a pristine copy from scratch → compare exit statuses
   → assert second incremental build is a no-op.
3. Log the seed; on failure upload both trees as artifacts.

This is the single strongest under-rebuild detector, and it is precisely the
test that keeps working unchanged when the hash becomes precise — the oracle
doesn't care which modules recompiled.

### 3.5 Parallelism stress

`-j 16` on a fixture with ~10 modules and wide fan-out, tier 2. Ninja's
scheduler ordering differs run to run; a missing edge between an `.iface`
producer and a consumer shows up as a flaky failure here long before a user
hits it. Run the fuzzer's DAG builds with high `-j` for free coverage.

## 4. Flags (I3)

`per-config-flags` covers: Debug vs Release defaults, `Hylo_FLAGS`,
per-target PRIVATE options. Missing:

- **Propagation scoping**: `hylo_target_compile_options(dep PUBLIC …)` must
  appear on dependents' hc lines (via `TRANSITIVE_COMPILE_PROPERTIES
  HYLO_COMPILE_OPTIONS`); `PRIVATE` must not; `INTERFACE` only on dependents.
  This transitive-options plumbing is currently *untested* — it is the same
  mechanism as imports, but a distinct property list.
- **Generator expressions** in options (`$<$<CONFIG:Release>:-O>` written by
  the user) — documented CMake practice, easy to break in the genex-wrapping
  the helper already does.
- **Multi-config trees**: today's flag assertions use two single-config trees.
  Add: one Ninja Multi-Config (and later VS) tree, build both configs, assert
  each config's hc line has exactly its own `Hylo_FLAGS_<CONFIG>`.
- **Quoting**: a flag value containing a space and a path containing a space
  (`separate_arguments(NATIVE_COMMAND)` behaves differently on Windows —
  assert on all three OSs).
- **Bad flag**: `Hylo_FLAGS=--no-such-flag` → the *build* fails with hc's
  diagnostic visible in the output (not swallowed by the custom command), and
  the configure-time works-check still passes (flags shouldn't apply there —
  or should they? decide, then pin with a test).
- **Flag change triggers rebuild** — listed in §3.3; it's both a flags test
  and an incremental test.

## 5. Cross-compilation

The ev3 subproject is the living proof (armel via C4EV3 toolchain file), but
nothing in CI exercises `Hylo_TARGET_TRIPLE` — and cross-compilation is no
longer a fringe feature: it is v0.0.7's headline ("Enable cross-compilation"),
so the integration's `--target` plumbing should be tested at the same level as
native builds, against hc ≥ 0.0.7. Plan, in order of increasing faith:

1. **Command-line fidelity (tier 1, cheap)**: fixture with a toolchain file
   setting `CMAKE_C_COMPILER_TARGET=aarch64-linux-gnu`; assert `--target
   aarch64-linux-gnu` appears on every hc line and that an explicit
   `-DHylo_TARGET_TRIPLE=` overrides it. No cross C compiler needed if
   configure-time link checks are skipped (`CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`).
2. **Artifact inspection (tier 1)**: with `gcc-aarch64-linux-gnu` installed on
   the Linux runner, build the diamond; assert the linked executable's
   architecture via `file`/`readelf -h` (AArch64), and that the *stdlib shim*
   and Hylo objects are all target-arch (a host-arch object sneaking in is the
   classic cross bug).
3. **Execution under emulation (tier 2)**: `qemu-user` (`CMAKE_CROSSCOMPILING_EMULATOR
   "qemu-aarch64;-L;/usr/aarch64-linux-gnu"`), run the exit-status tests.
   **Harness fix required first**: `RunExpectExit.cmake` invokes `${EXE}`
   directly and bypasses the emulator — teach it (and `assert_exit` in
   `tests/Harness.cmake`) to honour `CMAKE_CROSSCOMPILING_EMULATOR`. Worth
   doing regardless; it's what makes every existing exit-status test
   cross-capable for free.
4. **Second target (tier 2)**: armv5/armel with the ev3-style triple — the
   32-bit soft-float case is where `--cpu`/ABI defaults differ most from
   native. macOS arm64 → x86_64 (`CMAKE_OSX_ARCHITECTURES=x86_64`, executed
   under Rosetta on the same runner) covers the Apple side; with the
   `macos-x64` hc asset and an Intel runner (§2.2) the reverse direction is
   also natively verifiable.

Cross-specific behaviour to pin down with tests (these are open questions —
each answer goes in README):

- Does FindHylo's configure-time "compile a trivial module" works-check use the
  target triple? If it compiles host-only, a broken cross setup passes
  configure and fails at build — decide which behavior is wanted and assert it.
- Stdlib cache keying: `Hylo_MODULE_CACHE_DIR` defaults into the build tree —
  verify a host build and a cross build in *different* trees never share, and
  that two configs / two triples in one multi-config tree don't collide.
  (The related native case — a build tree surviving its *toolchain* being
  moved or replaced — is covered by `behaviour.toolchain-swap`.)
- `Hylo_TARGET_TRIPLE` is still marked experimental in FindHylo's docs, but
  the compiler side graduated in 0.0.7 — these tests are what justifies
  dropping the "experimental" label.

## 6. find_package / packaging / versioning (I5)

- `find_package(Hylo 0.0.6 REQUIRED)` against hc 0.0.6 — covered implicitly
  everywhere; against a *newer* hc → accepted (minimum semantics, §2.4). Add a
  negative: request a version newer than the installed hc → clean configure
  failure naming both versions.
- **Policy: a `development` hc (non-numeric `--version`) satisfies any
  requested version.** Both paths already implement this —
  `HyloConfigVersion.cmake` reports it compatible, FindHylo accepts it with a
  status note that the requested version cannot be checked — but neither is
  tested; pin both with a stub `hc` wrapper script that reports
  `development`. This is what keeps compiler developers' from-source builds
  usable against any project, and it's the path every hc-HEAD canary run
  (§8) goes through.
- `Hylo_COMPILER` pointing at a broken/absent binary → curated failure, not a
  cryptic execute_process error.
- Package-config path (`HyloConfig.cmake` in `<toolchain>/lib/cmake/Hylo`) —
  covered on Unix via symlinks; the Windows exclusion (`NOT WIN32`) should be
  lifted by having the fixture *copy* the toolchain instead of symlinking when
  symlinks are unavailable, since the toolchain-tarball layout is the primary
  distribution path and Windows is where it's untested.
- `install-export` — covered; add a *cross-config* consumer check (library
  installed from Release, consumed by a Debug project) since the installed
  `.hylomodule` is config-less.

## 7. Environment robustness (tier 3 experiments → README "Limitations")

Each of these is one cheap fixture run; the deliverable is the *documented
answer*, promoted to a regression test only if it works (or if the failure
mode needs guarding):

- Source and build paths containing **spaces**; non-ASCII path; Windows long
  paths (> 260 chars, `MAX_PATH` off and on).
- Case-insensitive filesystems (macOS, Windows): two modules whose names
  differ only by case → the archives collide in a search directory. Expected:
  configure-time error from the helper, not a silent overwrite. Today: unknown.
- Symlinked source tree (partially covered by `package-config`).
- Read-only source tree (out-of-source hygiene: nothing may write next to the
  `.hylo` files).
- `ccache`/`sccache` masquerading as the C compiler launcher — must be inert
  for hc edges, still apply to shim/C edges.

## 8. Compiler-drift canary (tier 2)

The 0.0.5→0.0.6 CLI break (`-I` removed) is the shape of the biggest external
risk. Nightly job building against hc from hylo-new HEAD (setup-hylo
`version: nightly`, or built from source, `continue-on-error: true`): the full
behaviour suite plus the §3.2 capability probe. The day the probe reports
`HASH_PRECISE=ON`, or a flag disappears, the canary says so *before* a release
does. The probe result should be printed in every CI run's "Toolchain info"
step so the transition is visible in logs.

## 9. Mechanics

- Keep the `cmake -P` script harness — zero dependencies, runs on every
  platform CMake runs on. Grow `Harness.cmake` with: `assert_noop_rebuild()`,
  emulator-aware `assert_exit`, the msbuild-aware `hc_command` matcher, the
  `HASH_PRECISE` probe, and a `fixture_mutate`/oracle-compare pair for §3.4.
- Labels as tiers: `behaviour` (tier 1), `behaviour-slow`, `fuzz` (tier 2);
  CI selects with `ctest -L`.
- On failure, `actions/upload-artifact` the test's `WORK_DIR` (both trees for
  the fuzzer, plus the seed).
- The CI matrix stays an explicit `include:` list — every job is one named
  risk (§2), not a generated cross product.
- `cmake/README.md`'s platform-coverage table (started in faab779) is the
  user-facing contract; every tier-1 addition and every tier-3 verdict updates it.

## 10. Rollout order

0. **DONE (2026-08-29)**: the suite runs green against hc v0.0.8 and the CI
   default is `HYLO_VERSION: 0.0.8`. The bump surfaced exactly the drift
   this step exists for: 0.0.8 moved `--print-stdlib-root`'s answer from
   `.../Sources` up to the bundle root (hylo-new#523), which broke the
   shims.c lookup. Decision: accept only the new layout and raise the hc
   floor to 0.0.8 (no dual-layout compatibility), so the floor and latest
   hc coincide until the next release.
1. **DONE (2026-08-29)**: VS 2022 and Xcode CI jobs (experimental until first
   green) with dedicated behaviour tests; CMake-3.30.0-pinned floor job (the 3.28
   negative was verified by hand and deliberately kept out of CI); `assert_noop_rebuild` after every mutation; the
   §3.2 `probe_hash_precise` restructure of `incremental-interface-hash`;
   `behaviour.flag-change-rebuild` and `behaviour.transitive-options`;
   interface-removal mutation.
2. **DONE (2026-08-29)**: `RunExpectExit`/`assert_exit` honour an emulator
   (each target's `CROSSCOMPILING_EMULATOR`); `behaviour.cross-target`
   (triple fidelity + pure-CMake ELF `e_machine` check, no cross C toolchain
   needed — runs in every PR job); nightly `cross-aarch64` job
   (`tests/toolchains/aarch64-linux-gnu.cmake`, gcc-aarch64 + qemu-user,
   exit-status tests run under qemu).
3. **DONE (2026-08-29)**: `.github/workflows/nightly.yml` — the DAG fuzzer
   (`tests/fuzz-incremental.cmake` behind `-DHYLO_FUZZ=ON`, seeded/replayable,
   oracle = from-scratch build), clang, clang-cl, NMake, macOS x64
   (macos-26-intel), Windows arm64 (windows-11-arm), CMake `latestrc`
   (advisory; get-cmake has no dev-nightly builds), and a latest-hc-release
   canary (an hc-HEAD canary needs nightly hc artifacts, which don't exist
   yet). `behaviour.development-version` pins the §6 policy with a stub hc.
4. **Experiments**: paths-with-spaces is a permanent behaviour test
   (`behaviour.paths-with-spaces`); MinGW and case-collision remain hand
   experiments — verdicts into README's Limitations.
