# elias_fano::size()/decode() divides by zero when the list is exactly dense (u == n)

**Where:** `3_list_compressors/code/elias_fano.hpp:61-63` (`size()`), reached from
`decode()`/`access()`.

**Cause:** `elias_fano::encode` sets `m_l = std::ceil(std::log2(double(u) / n))`, where `u` is the
largest (last) element and `n` is the list length. When `u == n` — e.g. the list is exactly
`1,2,3,...,n`, i.e. every gap is `1`, the densest possible strictly-increasing list, not a
malformed or even unusual input — `log2(u/n) == log2(1) == 0`, so `m_l == 0`. `size()` then
computes:

```cpp
uint32_t size() const {
    return m_low_bits.num_bits() / m_l;   // divide by zero when m_l == 0
}
```

`decode()` calls `size()` unconditionally as its first step, so **any** round trip of a dense
list crashes (UBSan: `division by zero`; a plain build would SIGFPE).

**Impact:** this is not an edge case an attacker has to search for — a caller storing the
sequence `1..n` (or any list whose max equals its length) hits it on an ordinary `encode()` +
`decode()`/`size()` pair.

**Reproduce (standalone, no fuzzer needed):** see `repro.cpp` in this directory. Compile with:

```sh
g++ -std=c++11 -include cstdint -mbmi -mbmi2 -msse4.2 -mpopcnt -fsanitize=undefined \
    -fno-sanitize-recover=all repro.cpp -o repro && ./repro
```

It reports `runtime error: division by zero` at `elias_fano.hpp:62`.

**Suggested upstream fix:** special-case `m_l == 0` in `size()` (return `m_low_bits.num_bits()`,
i.e. one bit position per element, since `access()` for `m_l == 0` degenerates to reading the
high-bits `darray` alone) — or refuse to construct such an instance and document the constraint.

**Note on `mayhem/fuzz_listcodec.cpp.src`:** the shipped harness round-trips `elias_fano`/
`interpolative` over lists derived from fuzz bytes (deltas of `1..64`), and increments the final
element by one before encoding so `u > n` strictly (`m_l >= 1` always). That is a harness-input-
shaping decision, not a workaround in upstream code: once a coverage-guided run found the trivial
"every delta is 1" input (an easy, common mutation — e.g. an all-zero-byte input), every
subsequent execution that reused it re-hit this identical, already-fully-demonstrated
division-by-zero, which empirically flatlined fork-mode coverage (549/1458 edges/features, ~4000
identical crashes in 100s, corpus stuck at 85 — the "rediscovering one bug forever" pattern).
Forcing `u > n` let coverage keep climbing (561/1673 edges/features, 0 crashes, corpus 126 over
the same window) while the defect itself stays fully reproducible via `repro.cpp` above.
