#!/usr/bin/env bash
#
# mayhem/build.sh — build data_compression_course's fuzz harnesses + the oracle CLIs.
#
# This repo is a teaching/reference repo with NO build system at all (upstream's own
# run_all.sh just invokes g++ by hand per README) and header-only codecs (bit_vector.hpp,
# integer_codes.hpp, elias_fano.hpp, interpolative.hpp, darray.hpp all live entirely in
# headers). That means:
#   - there is no separate library .a/.o to (mis-)instrument: each fuzz harness TU #includes
#     the codec headers directly, so compiling the harness with $SANITIZER_FLAGS instruments
#     the fuzzed codec logic too (see C/C++ point in the net-new brief §6 — no
#     -fsanitize=fuzzer-no-link split-object dance needed here);
#   - "build upstream" (step 1 in the usual build.sh shape) IS "compile the harness", so
#     there's nothing else to build for the fuzz side.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has an LLVMFuzzer entry)
#   STANDALONE_FUZZ_MAIN  LLVM's run-once driver (a C file) for the non-fuzzer reproducer binary
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#   DEBUG_FLAGS          -g -gdwarf-3   (DWARF must stay < 4 for Mayhem triage)
#   SRC                  /mayhem (the repo source)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# Upstream's own headers rely on their TYPES (uint32_t/uint64_t from <cstdint>) and stream
# usage (std::cout/std::ofstream/std::ifstream from <iostream>/<fstream>) leaking in
# TRANSITIVELY from whichever .cpp happens to include them first -- true for upstream's own
# compress.cpp/decompress.cpp/check.cpp (which always #include <iostream>/<fstream> before
# pulling the codec headers in), but NOT a safe assumption in general: on this image's
# clang/libstdc++, 1_introduction/code/util.hpp (uint32_t/uint64_t), bit_vector.hpp (std::cout)
# and darray.hpp (std::ofstream/ifstream) all fail to compile standalone. Fixed ADDITIVELY via
# a compiler flag (force-include), never by editing the upstream headers.
CSTDINT_FIX="-include cstdint -include iostream -include fstream"

# Elias-Fano's darray::select() (3_list_compressors/code/darray.hpp) uses the pdep/tzcnt/popcnt
# intrinsics upstream's own README documents needing -mbmi2 -msse4.2 for; -mbmi is ALSO
# required on this toolchain (bmiintrin.h's _tzcnt_u64 needs BMI, pdep needs BMI2 -- the
# README only mentions the latter two, but compiling without -mbmi fails here with "inlining
# failed ... target specific option mismatch"). Applied to every module-3 compile for
# consistency (harmless on the compress-only TUs that never call select()).
EF_FLAGS="-mbmi -mbmi2 -msse4.2 -mpopcnt"

# ---------------------------------------------------------------------------------------------
# 1) Oracle (clean, NON-sanitized, upstream's own -std=c++11 -O2) build: the project's own CLI
#    tools, used UNMODIFIED by mayhem/test.sh as the functional/known-answer oracle, plus the
#    shipped fixture (10 sorted integer lists, gunzipped once here). No sanitizer, no
#    -gdwarf-3 -- this build must stay an honest, unmodified oracle.
mkdir -p /mayhem/oracle
gunzip -k -c 2_integer_codes/code/lists.txt.gz > /mayhem/oracle/lists.txt

$CXX -std=c++11 $CSTDINT_FIX -O2 2_integer_codes/code/compress.cpp   -o /mayhem/oracle/compress2
$CXX -std=c++11 $CSTDINT_FIX -O2 2_integer_codes/code/decompress.cpp -o /mayhem/oracle/decompress2
$CXX -std=c++11 $CSTDINT_FIX -O2 2_integer_codes/code/check.cpp      -o /mayhem/oracle/check2

$CXX -std=c++11 $CSTDINT_FIX -O2 $EF_FLAGS 3_list_compressors/code/compress.cpp   -o /mayhem/oracle/compress3
$CXX -std=c++11 $CSTDINT_FIX -O2 $EF_FLAGS 3_list_compressors/code/decompress.cpp -o /mayhem/oracle/decompress3
$CXX -std=c++11 $CSTDINT_FIX -O2 $EF_FLAGS 3_list_compressors/code/check.cpp      -o /mayhem/oracle/check3

# ---------------------------------------------------------------------------------------------
# 2) Backport fuzz target: the ORIGINAL mayhemheroes target `compress` (reconstructed from the
#    mayhemheroes fork at the fuzzed commit, ghcr.io/mayhemheroes/data_compression_course@dd92efd)
#    is the project's own 2_integer_codes/code/compress.cpp CLI, driven file-at-a-time as
#    `compress <type> <input_lists_filename> <output_filename>` -- an AFL/@@-style command
#    target, not a libFuzzer harness (there is no LLVMFuzzerTestOneInput entry point here, so no
#    $LIB_FUZZING_ENGINE / $STANDALONE_FUZZ_MAIN; the CLI binary itself IS the one-shot
#    reproducer, run to completion once per input). mayhemheroes built it with plain unsanitized
#    g++; here it gets $SANITIZER_FLAGS + $DEBUG_FLAGS like every other v2 fuzz binary so we
#    catch memory/UB defects the original run's smoketest-only setup couldn't.
#
# LeakSanitizer off (fleet policy, sanctioned build-time hook — see mayhem/lsan_off.cc): compress
# builds its output with bit_vector_builder/std::vector and returns early on a malformed input
# without always releasing them, so LSan would flag a "leak" on inputs that aren't the memory
# defect we're after. ASan's real memory-safety checks and halting UBSan stay fully on.
ASAN_OPTS_OBJ=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  $CXX -x c++ -std=c++11 $SANITIZER_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
  ASAN_OPTS_OBJ=/tmp/lsan_off.o
fi

$CXX -std=c++11 $CSTDINT_FIX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 \
    2_integer_codes/code/compress.cpp $ASAN_OPTS_OBJ -o /mayhem/compress
