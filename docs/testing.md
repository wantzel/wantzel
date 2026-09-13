# Testing

One suite, one question: **does the language do what the specification says, and does the
compiler translate that correctly?** Everything lives in `tests/`; the runner is `./wztest`
in the root.

| directory | what it checks |
|---|---|
| `tests/lang/` | the language itself: types, expressions, control flow, error messages |
| `tests/compiler/` | the translation: code generation, optimisations, edge cases |
| `tests/lib/` | the standard library |
| `tests/examples/` | that every program in `examples/` still compiles, for both targets |
| `tests/limits/` | the measured limits (schema fields, tools, include depth) |
| `tests/toolchain/` | the bootstrap fixed point, `test.sh`, the Windows side through Wine |
| `tests/bench/` | speed, with a hard bound beside it |

`tests/toolchain/` runs **only** with `--toolchain` (slow, needs Wine); `tests/bench/`
only with `--bench`.

## Running

```bash
./wztest                          # lang + compiler + lib + limits, ~1 s
./wztest tests/lang               # one directory
./wztest tests/lang/hello.wz      # one test
./wztest -k curve                 # path filter
./wztest -t W-hhhh-llll           # the tests of one ticket
./wztest -v tests/lang/x.wz       # full diff on failure
./wztest --time                   # duration per test
./wztest --toolchain              # plus the bootstrap fixed point, test.sh and Wine
./wztest --bench                  # plus tests/bench/
```

**Always use `--toolchain` when working on the compiler or the bootstrap.** It is the only
way to notice that `src/wantzel.wz` and `bootstrap/boot.c` have drifted apart, and
otherwise you find out much later.

**Do not run the suite more often than necessary.** One green run covers everything in
it, so there is no point repeating it per change; use `-k <pattern>` while working to aim
at the tests you are busy with, and run the whole suite once before you commit.

## The bootstrap fixed point

`bootstrap/boot.c` is the compiler in C, `src/wantzel.wz` the same compiler in Wantzel.
The chain is `boot.c` → `wantzel.stage1` → `stage2` → `stage3`, and stage2 and stage3 must
be **byte-identical**. That is the proof that the compiler translates itself correctly.

The two sources are **counterparts**: the same logic, line by line, and the same output.
Change one and you change the other in the same commit. `./build.sh` builds the chain,
`./wztest --toolchain` checks it.

## Watching the speed

`tests/bench/compile_self.sh` measures how fast the compiler compiles its own source, in
lines per second, with a hard lower bound in `compile_lines_per_s.min` beside it. Compile
speed is one of the reasons this language exists — the short loop between writing and
knowing-whether-it-holds is the most valuable thing a language can give you — so a
regression there is a finding, not noise.

## Adding a test

1. Pick the directory: `lang/` (the language), `compiler/` (the translation), `lib/` (the
   library).
2. Pick the form:
   - `foo.wz` + `foo.out` — compile, run, compare stdout+stderr
   - `foo.wz` + `foo.err` — compiling must **fail**, and stderr must contain that text
   - `foo.sh` — shell script, exit 0 means pass (`$WANTZEL`, `$WANTZEL0`, `$ROOT` are set)
   - optional beside it: `foo.args`, `foo.stdin`, `foo.exit`, `foo.timeout`
   - `progs/` holds helper files, not tests
3. Open with one line saying what the test guards — for an error test, the assertion
   itself: `// Must not compile: "..."` or `// Must stop at run time: "...", with exit
   status 1.`
4. Keep the test small and deterministic: no time, no randomness, no network beyond
   127.0.0.1, derive ports from `$$`, and clean up any background process with a `trap`.
5. Run it on its own, then run the whole suite.

**Never use a word from the language's own vocabulary as a test value.** A constant
`"wantzel"` or `"pascal"` is indistinguishable later from a real reference to the
language. Pick a neutral word.

**A test must never skip anything silently.** If a test skips a check because something is
missing, it prints what it skipped and why. A test that quietly does nothing is
indistinguishable from a test that passes.

## On failure

Report the failing tests with the diff; **fix the code, not the expectation**, unless the
ticket is explicitly a behavioural change — record that in the work log. Only adjust an
expectation once you have independently established (by hand, with `od`, with a second
implementation) that the new result is the correct one.

A test that passes alone but fails in the suite is a finding, not noise: usually a shared
port, a leftover process, or a file two tests both write.
