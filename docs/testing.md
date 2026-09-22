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
| `tests/toolchain/` | the bootstrap fixed point, `test.sh`, the Windows side through Wine, and that the editor grammar still knows every keyword |
| `tests/bench/` | speed, with a hard bound beside it |

`tests/toolchain/` runs **only** with `--toolchain`; the Windows tests inside it need
Wine and run **only** with `--windows` on top of that; `tests/bench/`
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
./wztest --toolchain              # plus the bootstrap fixed point and test.sh
./wztest --toolchain --windows    # and the Windows side, through Wine (twice as slow)
./wztest --bench                  # plus tests/bench/
```

**The Windows tests sit behind `--windows`, and the split is on whether an emulator is
needed at all.** Two checks need none and run in every `--toolchain` run:
`tests/toolchain/win_backend_bytes.sh` reads the PE header and compares the `.exe` bytes
of `bootstrap/boot.c` against those of `src/wantzel.wz`. That is the check that earns its
keep -- on 14-09-2026 it caught the two counterparts drifting apart on the Windows side
while everything on Linux was byte-identical -- and it costs milliseconds.

What `--windows` adds is *running* a `.exe`: `win_exe_runs.sh` and `win_syscalls.sh`.
Those are the slowest thing here (measured 14-09-2026: 19 of the 40 seconds of a full run)
and they start processes that outlive them. Use `--windows` when you touch the Windows
side of the runtime, a syscall shim, or the code generator -- and when you release, where
`release.py` passes it for you, because a release publishes an `.exe`.

**A test switched off by a flag must not be started by another test.** Until 15-09-2026
`all_suites_green.sh` called `test-win.sh` unconditionally, so Wine ran on every
`--toolchain` run however you had set the flag: about ten times in one evening, leaving 29
orphan `wineserver64` and `winedevice.exe` processes, the oldest nearly an hour old. The
call is gone, and `win_exe_runs.sh` now **fails** if a wine process of its own run
survives its cleanup -- a leak that nobody reports is how 29 of them got there. It finds
its own processes through `/proc/<pid>/environ`, because the prefix never appears in a
command line (`pgrep -f "$WINEPREFIX"` matched nothing, which is why the old cleanup
silently did nothing).

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

### What the fixed point does not catch

**Two counterparts that disagree about whether to REFUSE a program still reach a fixed
point.** Measured on 16 September 2026, while adding a compile-time check: the check went
into `src/wantzel.wz` and into the wrong one of the two functions in `boot.c` that parse an
index. The result was a self-hosted compiler that refused a bad program and a C bootstrap
that accepted it — and `./build.sh` reported the fixed point reached, correctly, because
both compilers still built themselves byte-identically.

The fixed point proves each compiler translates *itself* the same way. It says nothing about
whether they agree on a program neither of them is.

So for any change to the counterparts, compile the same source with **both binaries** and
compare:

```bash
./bin/wantzel0 case.wz /tmp/a    # the C bootstrap
./bin/wantzel  case.wz /tmp/b    # the self-hosted compiler
```

For a program that should build, the two executables must be byte-identical — which
`tests/toolchain/counterparts_agree.sh` checks. For a program that should be **refused**,
both must refuse it with the same message, and nothing checks that automatically: an `.err`
test is compiled by `bin/wantzel` only. That gap is why the mistake above survived a green
suite.

## Watching the speed

`tests/bench/compile_self.sh` measures how fast the compiler compiles its own source, in
lines per second, with a hard lower bound in `compile_lines_per_s.min` beside it. Compile
speed is one of the reasons this language exists — the short loop between writing and
knowing-whether-it-holds is the most valuable thing a language can give you — so a
regression there is a finding, not noise.

## Write a test helper in Wantzel, not in another language

A test suite grows small helpers: read one field out of a JSON reply, reshape a line,
count something. The obvious move is a one-liner in whatever scripting language is already
on the machine. Measure that before you reach for it, because **the cost is not the work,
it is the interpreter starting up** — and a suite calls a helper like that thousands of
times.

Measured on a suite that did exactly this (15 September 2026). A one-line interpreted
helper that pulled one value out of a JSON reply, against the same thing as a Wantzel
program compiled once by the runner:

| | per call | 1254 calls |
|---|---|---|
| the interpreted one-liner | 13.2 ms | 16.6 s |
| the same in Wantzel | 0.46 ms | 0.6 s |

**29× faster, and 15 seconds off a suite that ran in about four minutes.** Nearly all of
the difference is process startup: the work itself — parsing a few hundred bytes of JSON —
is a fraction of a millisecond either way. The interpreter has to load before it can begin.

That makes it the same argument as *no external dependencies*, arriving from a different
direction. A helper written in Wantzel:

- **costs one exec**, because it is a static binary with nothing to load;
- **needs nothing installed**, so the suite runs on a machine that has only a C compiler;
- **is built once by the runner**, exactly like any other binary the tests use, so it costs
  no more than the build it already does;
- **exercises the language**, which is the honest test of whether it can carry real work.

The standard library has what such a helper usually needs — `json.wz` for reading and
writing JSON, `io.wz` for the file descriptors, `argc`/`argch` for the command line. The
whole program is typically under 200 lines. There is a worked example of one in
[`writing-wantzel.md`](writing-wantzel.md) under *A whole command-line tool*.

**One warning from the conversion.** If the helper replaces something, compare the output
case by case against what it replaced, and put those cases in a test — the existing tests
compare its output, so a difference in *formatting* breaks them just as hard as a
difference in value. In the measured case the interpreter's JSON writer emitted `{"a": 1, "b": 2}`
with a space after `:` and `,`, while echoing the source bytes gives `{"a":1,"b":2}`. Both
are valid JSON and neither is wrong; one of them matched a few hundred recorded outputs and
the other did not. A single-field object hides this, so test one with a comma in it.
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
