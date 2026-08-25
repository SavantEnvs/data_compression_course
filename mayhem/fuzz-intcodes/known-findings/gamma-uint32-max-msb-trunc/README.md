# write_gamma(x) aborts for x == UINT32_MAX (msb() argument truncation)

**Where:** `1_introduction/code/util.hpp:17` (`msb`) via `2_integer_codes/code/integer_codes.hpp:38-44`
(`write_gamma`).

**Cause:** `write_gamma` computes `uint64_t xx = x + 1;` and then `uint64_t b = msb(xx);`, but
`msb`'s parameter is declared `uint32_t`:

```cpp
static uint32_t msb(uint32_t x) {
    assert(x > 0);                 // if x is 0, the result is undefined
    return 31 - __builtin_clz(x);
}
```

`xx` is computed in `uint64_t`, so at exactly `x == UINT32_MAX` (`0xFFFFFFFF`), `xx == 2^32`
(`0x100000000`). Passing that into `msb(uint32_t)` silently truncates to `0`, and `msb(0)` hits
its own `assert(x > 0)`.

**Impact:** any caller of `write_gamma` (directly, or transitively via `write_delta`, which calls
`write_gamma` on its own exponent) with `x == UINT32_MAX` aborts the process. `compress.cpp`
encodes *gaps* (`x - prev_x`) as `uint32_t`, so this is reachable from a legitimate input list
whose gap between two consecutive values is exactly `UINT32_MAX` — not a contrived value.

**Reproduce (standalone, no fuzzer needed):** see `repro.cpp` in this directory. Compile with:

```sh
g++ -std=c++11 -include cstdint repro.cpp -o repro && ./repro
```

It aborts with `Assertion 'x > 0' failed.` in `util.hpp:18`.

**Suggested upstream fix:** change `msb`'s parameter to `uint64_t` (or have `write_gamma` clamp
`xx` before calling `msb`), i.e. compute the bit-width of a `uint64_t` value with a `uint64_t`-
taking helper instead of silently narrowing it.

**Note on `mayhem/fuzz_intcodes.cpp.src`:** the shipped harness fuzzes `write_gamma`/`write_delta`
(and `write_vbyte`/`write_rice`) as an encode-then-decode round trip across the full `uint32_t`
domain, but clamps the single value `0xFFFFFFFF` down to `0xFFFFFFFE` before encoding. That is a
harness-input-shaping decision, not a workaround baked into upstream code: once a coverage-guided
run discovers `0xFFFFFFFF` (an easy, common mutation target), every subsequent execution that
reuses it re-hits this identical, already-fully-demonstrated abort, which empirically flatlined
fork-mode coverage (270/587 edges/features, ~1000 identical crashes in 100s, corpus stuck at 29 —
the "rediscovering one bug forever" pattern). Clamping just that one value let coverage keep
climbing (275/1170 edges/features, 0 crashes, corpus 118 over the same window) while the defect
itself stays fully reproducible via `repro.cpp` above.
