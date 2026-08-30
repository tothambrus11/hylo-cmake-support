# Randomized incremental fuzzing (the strategy's strongest under-rebuild
# detector, notes/TESTING-STRATEGY.md 3.4): generate a random module DAG whose
# program's exit status is a checksum of every module, then repeatedly mutate
# a random module and require that
#   (a) the incremental build's program behaves exactly like a from-scratch
#       build of the same sources (the oracle -- catches under-rebuilds), and
#   (b) a second incremental build is a no-op.
# Deterministic per seed; the seed is printed first so any failure is
# reproducible with -DFUZZ_SEED=<n>.  Ninja only; registered behind
# -DHYLO_FUZZ=ON (nightly).
include("${CMAKE_CURRENT_LIST_DIR}/Harness.cmake")

if(NOT FUZZ_SEED)
  string(TIMESTAMP FUZZ_SEED "%s")
endif()
if(NOT FUZZ_ITERATIONS)
  set(FUZZ_ITERATIONS 25)
endif()
if(NOT FUZZ_MODULES)
  set(FUZZ_MODULES 8)
endif()
message(STATUS "fuzz: seed=${FUZZ_SEED} iterations=${FUZZ_ITERATIONS} modules=${FUZZ_MODULES}")

# Lehmer LCG so a failure reproduces from the seed alone.
math(EXPR _rng "(${FUZZ_SEED} % 2147483646) + 1")
function(rand out bound)
  math(EXPR _rng "(${_rng} * 48271) % 2147483647")
  set(_rng "${_rng}" PARENT_SCOPE)
  math(EXPR _v "${_rng} % ${bound}")
  set(${out} "${_v}" PARENT_SCOPE)
endfunction()

# ---- Model: module i has constant K_i, an optional extra public fun, and
# depends on a random subset of earlier modules.  m<i>() returns K_i plus the
# sum of its dependencies' values; main() sums every module.  The DEPS_* lists
# are fixed for the run; K_* and EXTRA_* are what mutations change.
set(_all)
foreach(i RANGE 1 ${FUZZ_MODULES})
  rand(_k 5)
  set(K_${i} "${_k}")
  set(EXTRA_${i} 0)
  set(DEPS_${i})
  if(i GREATER 1)
    math(EXPR _prev "${i} - 1")
    foreach(j RANGE 1 ${_prev})
      rand(_edge 3)
      if(_edge EQUAL 0)   # ~1/3 of possible edges
        list(APPEND DEPS_${i} ${j})
      endif()
    endforeach()
  endif()
  list(APPEND _all ${i})
endforeach()

# Writes module i's source from the current K/EXTRA state.  Integer literals
# only coerce to Int32 in a return position (hc 0.0.8), so the constant lives
# in its own function and the value is a sum of calls.
function(write_module i)
  set(_src "")
  foreach(j IN LISTS DEPS_${i})
    string(APPEND _src "import M${j}\n")
  endforeach()
  string(APPEND _src "fun k${i}() -> Int32 { ${K_${i}} }\n")
  set(_expr "k${i}()")
  foreach(j IN LISTS DEPS_${i})
    string(APPEND _expr " + m${j}()")
  endforeach()
  string(APPEND _src "public fun m${i}() -> Int32 { ${_expr} }\n")
  if(EXTRA_${i})
    string(APPEND _src "public fun extra${i}() -> Int32 { ${EXTRA_${i}} }\n")
  endif()
  file(WRITE "${WORK_DIR}/src/fuzz/M${i}.hylo" "${_src}")
endfunction()

# ---- Fixture: one directory, one library per module, one executable.
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}/src/fuzz")
set(_cml "")
set(_main_imports "")
set(_main_expr "m1()")
foreach(i IN LISTS _all)
  write_module(${i})
  string(APPEND _cml "hylo_add_library(M${i} SOURCES M${i}.hylo)\n")
  foreach(j IN LISTS DEPS_${i})
    string(APPEND _cml "target_link_libraries(M${i} PUBLIC M${j})\n")
  endforeach()
  string(APPEND _main_imports "import M${i}\n")
  if(i GREATER 1)
    string(APPEND _main_expr " + m${i}()")
  endif()
endforeach()
string(APPEND _cml "hylo_add_executable(app MODULE_NAME MainFuzz SOURCES Main.hylo)\n")
foreach(i IN LISTS _all)
  string(APPEND _cml "target_link_libraries(app PRIVATE M${i})\n")
endforeach()
file(WRITE "${WORK_DIR}/src/fuzz/Main.hylo"
  "${_main_imports}public fun main() -> Int32 { ${_main_expr} }\n")
file(WRITE "${WORK_DIR}/src/fuzz/CMakeLists.txt" "${_cml}")
file(WRITE "${WORK_DIR}/src/CMakeLists.txt" "
cmake_minimum_required(VERSION 3.30)
project(Fuzz LANGUAGES C)
list(APPEND CMAKE_MODULE_PATH \"${SOURCE_DIR}/cmake\")
find_package(Hylo REQUIRED)
add_subdirectory(fuzz)
")

fixture_configure()
fixture_build(out)
assert_build_ok(out)

# The oracle: a from-scratch build of the same sources in a second tree.
function(oracle_exit out_var)
  file(REMOVE_RECURSE "${WORK_DIR}/oracle")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -S "${WORK_DIR}/src" -B "${WORK_DIR}/oracle" -G "${GENERATOR}"
      "-DHylo_COMPILER=${Hylo_COMPILER}" "-DCMAKE_C_COMPILER=${C_COMPILER}"
      "-DCMAKE_MAKE_PROGRAM=${MAKE_PROGRAM}"
    RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
  if(NOT _r EQUAL 0)
    message(FATAL_ERROR "seed ${FUZZ_SEED}: oracle configure failed:\n${_o}${_e}")
  endif()
  execute_process(COMMAND "${CMAKE_COMMAND}" --build "${WORK_DIR}/oracle"
    RESULT_VARIABLE _r OUTPUT_VARIABLE _o ERROR_VARIABLE _e)
  if(NOT _r EQUAL 0)
    message(FATAL_ERROR "seed ${FUZZ_SEED}: oracle build failed:\n${_o}${_e}")
  endif()
  execute_process(COMMAND "${WORK_DIR}/oracle/fuzz/app" RESULT_VARIABLE _r)
  set(${out_var} "${_r}" PARENT_SCOPE)
endfunction()

foreach(_iter RANGE 1 ${FUZZ_ITERATIONS})
  rand(_mi ${FUZZ_MODULES})
  math(EXPR _mi "${_mi} + 1")
  rand(_what 4)
  if(_what EQUAL 0)         # touch, no change
    set(_desc "touch M${_mi}")
    file(TOUCH_NOCREATE "${WORK_DIR}/src/fuzz/M${_mi}.hylo")
  elseif(_what EQUAL 1)     # body change
    rand(_k 5)
    math(EXPR K_${_mi} "${_k} + 1")
    set(_desc "body M${_mi} -> K=${K_${_mi}}")
    write_module(${_mi})
  elseif(_what EQUAL 2)     # interface: add (or change) an extra public fun
    rand(_e 9)
    math(EXPR EXTRA_${_mi} "${_e} + 1")
    set(_desc "interface add/change extra${_mi}=${EXTRA_${_mi}}")
    write_module(${_mi})
  else()                    # interface: remove the extra fun, if present
    set(EXTRA_${_mi} 0)
    set(_desc "interface remove extra${_mi}")
    write_module(${_mi})
  endif()

  fixture_build(out)
  if(NOT out_RESULT EQUAL 0)
    message(FATAL_ERROR "seed ${FUZZ_SEED} iteration ${_iter} (${_desc}): incremental build failed:\n${out}")
  endif()
  execute_process(COMMAND "${WORK_DIR}/build/fuzz/app" RESULT_VARIABLE _incremental)
  oracle_exit(_fresh)
  if(NOT _incremental STREQUAL _fresh)
    message(FATAL_ERROR "seed ${FUZZ_SEED} iteration ${_iter} (${_desc}): "
      "incremental build exits ${_incremental}, a from-scratch build exits ${_fresh} -- under-rebuild")
  endif()
  assert_noop_rebuild("seed ${FUZZ_SEED} iteration ${_iter} (${_desc})")
endforeach()
message(STATUS "fuzz: ${FUZZ_ITERATIONS} iterations survived (seed ${FUZZ_SEED})")
