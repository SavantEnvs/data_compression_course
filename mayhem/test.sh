#!/usr/bin/env bash
#
# mayhem/test.sh — run data_compression_course's OWN compress/check/decompress pipeline
# (mayhem/build.sh already compiled the CLIs into /mayhem/oracle/, unmodified, with the
# project's normal -O2 flags) against the shipped 10-list fixture, and assert an EXACT
# known-answer value: `check` reports "checked 3483756 ints" with zero "error:" lines for
# every one of the 7 codec types this repo implements (gamma/delta/vbyte/rice_k1/rice_k2 from
# 2_integer_codes; ef/bic from 3_list_compressors). 3483756 is the fixture's real integer
# count (verified independently by parsing 2_integer_codes/code/lists.txt.gz's 10 lists), and
# `check` gets it by DECODING and COMPARING every value against lists.txt -- so this is a real
# behavioral oracle: a neutered/no-op `check`/`compress`/`decompress` produces no "checked N
# ints" line at all, and a subtly-wrong decoder produces a mismatched count or an "error:"
# line, either of which this script treats as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

ORACLE=/mayhem/oracle
FIXTURE="$ORACLE/lists.txt"
EXPECTED_INTS=3483756   # verified: 10 lists, sum of list sizes (see build.sh's gunzip step)

for bin in compress2 decompress2 check2 compress3 decompress3 check3; do
  [ -x "$ORACLE/$bin" ] || { echo "missing $ORACLE/$bin — run mayhem/build.sh first" >&2; exit 2; }
done
[ -f "$FIXTURE" ] || { echo "missing $FIXTURE — run mayhem/build.sh first" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dcc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
fail_names=""

run_type() {
  local module="$1" type="$2" compress_bin="$3" check_bin="$4" decompress_bin="$5"
  local out="$WORK/out_${module}_${type}.bin"

  "$compress_bin" "$type" "$FIXTURE" "$out" >"$WORK/compress_${module}_${type}.log" 2>&1
  local check_out
  check_out="$("$check_bin" "$type" "$out" "$FIXTURE" 2>&1)"
  local decompress_out
  decompress_out="$("$decompress_bin" "$type" "$out" 2>&1)"

  if printf '%s\n' "$check_out" | grep -q "^checked ${EXPECTED_INTS} ints\$" \
     && ! printf '%s\n' "$check_out" | grep -q '^error:' \
     && printf '%s\n' "$decompress_out" | grep -q "decompressed ${EXPECTED_INTS} integers"; then
    echo "PASS  ${module}/${type}"
    passed=$((passed + 1))
  else
    echo "FAIL  ${module}/${type}"
    echo "--- check output ---"
    printf '%s\n' "$check_out"
    echo "--- decompress output ---"
    printf '%s\n' "$decompress_out"
    failed=$((failed + 1))
    fail_names="${fail_names:+$fail_names,}${module}/${type}"
  fi
}

run_type intcodes   gamma    "$ORACLE/compress2" "$ORACLE/check2" "$ORACLE/decompress2"
run_type intcodes   delta    "$ORACLE/compress2" "$ORACLE/check2" "$ORACLE/decompress2"
run_type intcodes   vbyte    "$ORACLE/compress2" "$ORACLE/check2" "$ORACLE/decompress2"
run_type intcodes   rice_k1  "$ORACLE/compress2" "$ORACLE/check2" "$ORACLE/decompress2"
run_type intcodes   rice_k2  "$ORACLE/compress2" "$ORACLE/check2" "$ORACLE/decompress2"
run_type listcodec  ef       "$ORACLE/compress3" "$ORACLE/check3" "$ORACLE/decompress3"
run_type listcodec  bic      "$ORACLE/compress3" "$ORACLE/check3" "$ORACLE/decompress3"

if [ -n "$fail_names" ]; then
  echo "failed codec types: $fail_names" >&2
fi

emit_ctrf "dcc-compress-check-decompress" "$passed" "$failed"
