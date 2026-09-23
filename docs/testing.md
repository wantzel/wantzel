# Testing

**How to run the suite, add a test, and what the test groups check.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

One suite, one question: does the language do what the specification says, and does the
compiler translate that correctly? Everything lives in `tests/`; the runner is `./wztest`.

## Groups

| directory | what it checks |
|---|---|
| `tests/lang/` | the language itself: types, expressions, control flow, error messages |
| `tests/compiler/` | the translation: code generation, optimisations, edge cases |
| `tests/lib/` | the standard library |
| `tests/examples/` | every program in `examples/` still compiles, for both targets |
| `tests/limits/` | measured limits (schema fields, tools, include depth) |
| `tests/toolchain/` | the bootstrap fixed point, `test.sh`, the Windows side through Wine, editor grammar keyword coverage |
| `tests/bench/` | speed, with a hard bound beside it |

`tests/toolchain/` runs only with `--toolchain`; its Windows tests need Wine and run only
with `--windows` on top of that; `tests/bench/` only with `--bench`.

## Running

```bash
./wztest                          # lang + compiler + lib + limits, ~1 s
./wztest tests/lang               # one directory
./wztest tests/lang/hello.wz      # one test
./wztest -k curve                 # path filter
./wztest -t W-hhhh-llll           # the tests of one ticket
./wztest -v tests/lang/x.wz       # full diff on failure
./wztest --time                   # duration per test
./wztest --toolchain              # plus the bootstrap fixed point and test.sh
./wztest --toolchain --windows    # and the Windows side, through Wine (twice as slow)
./wztest --bench                  # plus tests/bench/
```

**Don't run the suite more often than necessary.** One green run covers everything in it;
use `-k <pattern>` while working, run the whole suite once before committing. Always use
`--toolchain` when working on the compiler or the bootstrap — it's the only way to notice
`src/wantzel.wz` and `bootstrap/boot.c` have drifted apart.

Two Windows checks need no emulator and run in every `--toolchain` run:
`tests/toolchain/win_backend_bytes.sh` reads the PE header and compares the `.exe` bytes of
`bootstrap/boot.c` against those of `src/wantzel.wz` — a check that once caught the two
counterparts drifting apart on the Windows side while Linux stayed byte-identical, for the
cost of milliseconds. What `--windows` adds on top is *running* a `.exe`
(`win_exe_runs.sh`, `win_syscalls.sh`), the slowest part of the suite — needed when you
touch the Windows runtime, a syscall shim, or the code generator, and for a release (which
`release.py` passes automatically).

A test switched off by a flag must never be started by another test: `win_exe_runs.sh`
fails if a Wine process of its own run outlives its cleanup.

## The bootstrap fixed point

`bootstrap/boot.c` is the compiler in C, `src/wantzel.wz` the same compiler in Wantzel. The
chain is `boot.c` → `wantzel.stage1` → `stage2` → `stage3`, and stage2 and stage3 must be
**byte-identical** — the proof the compiler translates itself correctly. The two sources are
counterparts: same logic, line by line, same output. Change one and you change the other in
the same commit. `./build.sh` builds the chain, `./wztest --toolchain` checks it.

**What the fixed point doesn't catch:** two counterparts can disagree about whether to
*refuse* a program and still reach a fixed point — each still builds itself
byte-identically even if one accepts a program the other rejects. So for any change to the
counterparts, compile the same source with both binaries and compare:

```bash
./bin/wantzel0 case.wz /tmp/a    # the C bootstrap
./bin/wantzel  case.wz /tmp/b    # the self-hosted compiler
```

For a program that should build, the two executables must be byte-identical —
`tests/toolchain/counterparts_agree.sh` checks this. For a program that should be
**refused**, both must refuse it with the same message, and nothing checks that
automatically: an `.err` test compiles with `bin/wantzel` only.

## Watching the speed

`tests/bench/compile_self.sh` measures how fast the compiler compiles its own source, in
lines per second, with a hard lower bound in `compile_lines_per_s.min` beside it. Compile
speed is one of the reasons this language exists, so a regression there is a finding, not
noise.

## Write a test helper in Wantzel, not another language

A helper that reads one field out of a JSON reply or reshapes a line is tempting to write as
a one-liner in whatever interpreted language is on the machine — but the cost is not the
work, it's the interpreter starting up, and a suite calls a helper like that thousands of
times.

| | per call | 1254 calls |
|---|---|---|
| interpreted one-liner | 13.2 ms | 16.6 s |
| the same in Wantzel | 0.46 ms | 0.6 s |

**29× faster.** Nearly all the difference is process startup, not the work itself. A Wantzel
helper costs one exec, needs nothing installed, is built once by the runner like any other
test binary, and exercises the language itself. `json.wz`, `io.wz` and `argc`/`argch` cover
what such a helper usually needs; a worked example is in
[writing-wantzel.md](writing-wantzel.md) under *A whole command-line tool*.

**One warning:** if the helper replaces something, compare output case by case against what
it replaced and put those cases in a test — a difference in *formatting* breaks existing
comparisons just as hard as a difference in value (`{"a": 1, "b": 2}` vs `{"a":1,"b":2}` are
both valid JSON, but only one matches recorded output). A single-field object hides this;
test one with a comma in it.

## Adding a test

1. Pick the directory: `lang/` (the language), `compiler/` (the translation), `lib/` (the
   library).
2. Pick the form:
   - `foo.wz` + `foo.out` — compile, run, compare stdout+stderr
   - `foo.wz` + `foo.err` — compiling must **fail**, stderr must contain that text
   - `foo.sh` — shell script, exit 0 means pass (`$WANTZEL`, `$WANTZEL0`, `$ROOT` are set)
   - optional beside it: `foo.args`, `foo.stdin`, `foo.exit`, `foo.timeout`
   - `progs/` holds helper files, not tests
3. Open with one line saying what the test guards — for an error test, the assertion itself:
   `// Must not compile: "..."` or `// Must stop at run time: "...", with exit status 1.`
4. Keep it small and deterministic: no time, no randomness, no network beyond 127.0.0.1,
   derive ports from `$$`, clean up any background process with a `trap`.
5. Run it alone, then run the whole suite.

**Never use a word from the language's own vocabulary as a test value.** A constant
`"wantzel"` or `"pascal"` is indistinguishable later from a real reference to the language —
pick a neutral word.

**Before a Windows test reaches for Wine, ask whether the bytes answer the question.** Most
of what a compiler gets wrong about Windows is visible in the file: the PE header, the
import table, emission order. Those checks are a `cmp` — milliseconds, no prefix, no
`wineserver`, nothing left running. `wine_only_where_needed.sh` keeps the count from
drifting: if your test really has to run the program, raise the ceiling there and say why.

**A test must never skip anything silently.** If it skips a check because something is
missing, it prints what and why — a test that quietly does nothing is indistinguishable from
one that passes.

## On failure

Report failing tests with the diff; fix the code, not the expectation, unless the change is
explicitly behavioural (record that in the work log). Only adjust an expectation once you've
independently established — by hand, with `od`, with a second implementation — that the new
result is correct.

A test that passes alone but fails in the suite is a finding, not noise: usually a shared
port, a leftover process, or a file two tests both write.
