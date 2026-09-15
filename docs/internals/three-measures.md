# Three measures: compile time, binary size, run time

*Measured 15 September 2026 on one machine (Intel Core Ultra 7 258V, 6 cores, 16 GB).*

A compiler with no optimisation stage translates a program in three milliseconds, produces a
binary ninety times smaller than the equivalent in Go, and the result keeps up with that Go
binary at run time. The third is the surprising one, because the first two are normally
bought with it.

## What was measured

Same job in every case: count lines containing `" 500 "` in a generated 2 GB log file. Page
cache warmed first, so this measures the program and not the disk. **Every implementation
answers 25492** — which is what makes the comparison worth anything.

### 1. Compile time

| | time | how |
|---|---|---|
| Wantzel, a 189-line program | **3 ms** | one pass, no optimisation stage |
| Wantzel, the compiler itself (6,772 lines) | **~10 ms** | same |
| Go, the same program — cold | 2,651 ms | SSA, register allocation, inlining |
| Go, the same program — warm cache | 112 ms | same |

"No optimiser" is a fact rather than a claim: searching the compiler's source for
`optimi[sz]`, `peephole`, `register alloc`, `constant fold` and `inline` returns nothing.

### 2. Binary size

| | bytes | linkage |
|---|---|---|
| the Wantzel program | **22,786** | static, no shared libraries at all |
| the same in Go | 2,040,611 | static |

**A factor of 89.6.** Both statically linked, so this compares like with like — there is no
runtime hidden on the other side. Python, awk and bash additionally need an installed
interpreter and cannot be compared this way at all.

### 3. Run time

| | time | peak RSS |
|---|---|---|
| Wantzel, `mmap` + scan | **0.72 s** | 2,097,152 kB |
| Go, `mmap` + `bytes.Index` | 0.82 s | 2,098,816 kB |
| Go, `read()` in blocks | 1.17 s | 24,452 kB |
| `ugrep -c` | 1.33 s | 2,304 kB |
| Python, `count()` per block | 2.43 s | 27,000 kB |
| `awk` | 3.26 s | 3,840 kB |
| Python, per line | 4.79 s | 40,040 kB |
| `bash` read loop | ~29 s (extrapolated) | — |

## The caveats, which are not optional

Anyone who finds these numbers interesting will measure for themselves. So:

1. **The run-time lead is mostly `mmap`, not code generation.** Go with `read()` takes
   1.17 s, Go with `mmap` 0.82 s, Wantzel 0.72 s. The gap against a fair comparison is
   therefore **14%, not 62%** — and that 14% is not yet explained, so it is not claimed.
2. **The class of program is narrow.** This is a tight loop over bytes with a SIMD scan
   underneath, which is exactly where an optimiser has least to find. Code leaning on deep
   abstraction, generics or many small functions is where inlining earns its keep. The claim
   is for this kind of work, not in general.
3. **Go's warm build belongs next to the cold one.** Quoting 2.65 s without the 112 ms warm
   figure is cheap scoring. Even at 112 ms the difference is 37×, which is plenty.
4. **The sources are not the same size.** 189 lines against 37 — Go leans harder on its
   standard library. That does not make the run-time comparison unfair, since the answer is
   identical, but line counts are not evidence of anything here.
5. **The memory column is not a language property.** Go-with-`mmap` shows the same 2 GB
   resident. Anything that maps a file has every paged-in page counted as resident;
   `Private_Dirty` was 24 kB. That holds in any language, so it is not a price paid here.
6. **"grep" on this machine is ugrep 7.8.4**, not GNU grep. They are different programs with
   different performance.

## Why this is worth stating at all

The usual trade is: fast builds or fast output, pick one. A debug build compiles quickly and
runs slowly; a release build the other way round.

For this kind of work that trade did not appear — and the size comparison is the one measure
of the three that needs no qualification at all: 22,786 bytes against 2,040,611, both
statically linked, no shared libraries, no runtime, no dependencies.
