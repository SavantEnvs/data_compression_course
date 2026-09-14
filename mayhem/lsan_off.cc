// Build-time LSan disable hook (sanctioned form — see mayhem/build.sh). Fleet policy disables
// LeakSanitizer preventively for every ASan-built target; ASan's real memory-safety checks
// (overflow, use-after-free, …) and halting UBSan stay fully on.
extern "C" int __lsan_is_turned_off(void) { return 1; }
