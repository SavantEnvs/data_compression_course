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
# 2) Fuzz harnesses, sanitized + DWARF-3. Ship them as a non-compiling `.cpp.src` name so they
#    are never picked up as an ordinary project file; we copy/compile them into place here.
#    Header-only codecs => these two harness TUs ARE the fuzzed library for coverage purposes
#    (there is no separate .a/.o that $SANITIZER_FLAGS could fail to reach).
$CXX -std=c++11 -x c++ $CSTDINT_FIX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -I"$SRC" \
    mayhem/fuzz_intcodes.cpp.src -o /mayhem/fuzz_intcodes

$CXX -std=c++11 -x c++ $CSTDINT_FIX $SANITIZER_FLAGS $DEBUG_FLAGS $EF_FLAGS $LIB_FUZZING_ENGINE -I"$SRC" \
    mayhem/fuzz_listcodec.cpp.src -o /mayhem/fuzz_listcodec

# ---------------------------------------------------------------------------------------------
# 3) Standalone (non-fuzzer) reproducers: the same harnesses linked against
#    $STANDALONE_FUZZ_MAIN instead of the fuzzing engine -- one input file, runs
#    LLVMFuzzerTestOneInput once, crashes naturally, no libFuzzer runtime. $STANDALONE_FUZZ_MAIN
#    is a C file: compile it as C once so our harnesses' `extern "C" LLVMFuzzerTestOneInput`
#    keeps C linkage (clang++ would otherwise mangle a fresh compile of it).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

$CXX -std=c++11 -x c++ $CSTDINT_FIX $SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC" \
    mayhem/fuzz_intcodes.cpp.src -x none /tmp/standalone_main.o -o /mayhem/fuzz_intcodes-standalone

$CXX -std=c++11 -x c++ $CSTDINT_FIX $SANITIZER_FLAGS $DEBUG_FLAGS $EF_FLAGS -I"$SRC" \
    mayhem/fuzz_listcodec.cpp.src -x none /tmp/standalone_main.o -o /mayhem/fuzz_listcodec-standalone
