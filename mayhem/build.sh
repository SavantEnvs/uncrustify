#!/usr/bin/env bash
#
# mayhem/build.sh - builds, under /mayhem (re-runnable, offline):
#   1. build/fuzz    sanitized uncrustify (ASan+UBSan, DWARF 3) linked with mayhem/fuzz_main.cpp, whose main()
#                    feeds the fuzz input to uncrustify's own main() (compiled as uncrustify_main) on stdin
#                    -> /mayhem/uncrustify_format and /mayhem/uncrustify_config (same binary; mode = its name)
#   2. build/oracle  the stock uncrustify with the project's normal flags, which mayhem/test.sh runs.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). 
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Header listing every upstream test config; fuzz_main.cpp indexes it with two input bytes.
mkdir -p build/fuzz/gen
{
  echo "static const char *const kConfigs[] = {"
  find "$SRC/tests/config" -name '*.cfg' | LC_ALL=C sort | sed 's/.*/  "&",/'
  echo "};"
  echo "static const unsigned kConfigCount = sizeof(kConfigs) / sizeof(kConfigs[0]);"
} > build/fuzz/gen/cfg_list.h

# 1) Sanitized build. main() is renamed only after configure: CMake's compiler checks need a real main.
FUZZ_WRAPPER_OBJS="$SRC/build/fuzz/fuzz_main.o $SRC/build/fuzz/lsan_off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 -I"$SRC/build/fuzz/gen" -c mayhem/fuzz_main.cpp -o build/fuzz/fuzz_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -c mayhem/lsan_off.cc -o build/fuzz/lsan_off.o
cmake -S . -B build/fuzz/cmake -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1" >/dev/null
cmake -S . -B build/fuzz/cmake \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -Dmain=uncrustify_main" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $FUZZ_WRAPPER_OBJS" >/dev/null
cmake --build build/fuzz/cmake --target uncrustify -j"$MAYHEM_JOBS"
cp build/fuzz/cmake/uncrustify /mayhem/uncrustify_format
cp build/fuzz/cmake/uncrustify /mayhem/uncrustify_config

# 2) The stock build with normal flags, for mayhem/test.sh (never compiled there).
cmake -S . -B build/oracle -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" >/dev/null
cmake --build build/oracle --target uncrustify -j"$MAYHEM_JOBS"
