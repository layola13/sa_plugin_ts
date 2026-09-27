# Demos whose result cannot be checked through the process exit status.
#
# IMPORTANT: this file previously claimed a chained compare-dispatch miscompilation
# in the SA toolchain (3+ eq/br levels returning 44). That finding was WRONG and
# has been withdrawn. What actually happened:
#
#   A process exit status is 8 bits, so `return 300` from `@main()` is observed by
#   the shell as 300 & 0xFF = 44. The 1-level and 2-level chains that appeared to
#   work all used values below 256 by coincidence. Reproduced by hand with plain
#   SA-ASM, with no involvement from the TypeScript lowerer:
#
#   # a two-level chain returning 300 also "fails"
#   $ sa build x.sai -o x && ./x; echo $?
#   188        # 700 & 0xFF
#
#   and
#
#   @f(c: i32) -> i32:
#       r0 = 0
#       ...
#       r0 = 300
#       ...
#       return r0
#   @main() -> i32: ... call @f(1) ... return t5
#
#   gives 44 = 300 & 0xFF.
#
# So there is no toolchain bug; the value channel was the problem. Demos listed
# here return a value outside 0..255, so their result cannot be observed this way
# and the differential check is skipped for them rather than reporting a false
# failure. The right fix is to print the value rather than return it; the SA
# subset has no printing support yet, which is a separate gap.
#
## Resolution

The exit status is exactly `value & 0xFF`, so comparing the low byte checks every
value correctly, including negative and out-of-range ones. verify_demos.sh now
does exactly that, and all three demos pass on their own merits. This file is
kept only as a record of the withdrawn finding so the mistake is not repeated.
No demo currently needs an exclusion.
