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
| `tests/examples/` | every program in `examples/` still compiles |
| `tests/limits/` | measured limits (schema fields, tools, include depth) |
| `tests/toolchain/` | the bootstrap fixed point, `test.sh`, reproducibility, editor grammar keyword coverage |
| `tests/bench/` | speed, with a hard bound beside it |

`tests/toolchain/` runs only with `--toolchain`; `tests/bench/` only with `--bench`.

## Running

```bash
./wztest                          # lang + compiler + lib + limits, ~1 s
./wztest tests/lang               # one directory
./wztest tests/lang/hello.wz      # one test
./wztest -k curve                 # path filter
./wztest -v tests/lang/x.wz       # full diff on failure
./wztest --time                   # duration per test
./wztest --toolchain              # plus the bootstrap fixed point and test.sh
./wztest --bench                  # plus tests/bench/
```

**Don't run the suite more often than necessary.** One green run covers everything in it;
use `-k <pattern>` while working, run the whole suite once before committing. Always use
`--toolchain` when working on the compiler or the bootstrap — it's the only way to notice
the fixed point has broken.

A test switched off by a flag must never be started by another test: `tests/bench/` runs
only when `--bench` was typed, and nothing under `tests/toolchain/` calls it.

## The bootstrap fixed point

`bootstrap/boot.c` is a small C compiler for exactly what `src/wantzel.wz` needs to compile
itself: no `schema`, no `tools`, no `--debug`. `src/wantzel.wz` is the real compiler,
self-hosted, and it implements the whole language.

The chain is `boot.c` → `wantzel.stage1` → `stage2` → `stage3`. **stage2 and stage3 must be
byte-identical** — the proof that the self-hosted compiler reproduces itself correctly.
Stage1 does not have to match them: `boot.c` only has to produce a *correct* stage1, not an
identical one. `./build.sh` builds the chain, `./wztest --toolchain` checks
it.

This is why `boot.c` and `src/wantzel.wz` are **not** counterparts any more, and nothing
keeps them in step: a change to the self-hosted compiler only touches `boot.c` when it
changes something `src/wantzel.wz` itself needs to compile — a new keyword or construct
the compiler's own source starts using, for example.
Anything the compiler's source does not use (schema, tools, `real` arithmetic beyond what
it already has, `--debug`) can change freely in the self-hosted compiler without touching
`boot.c` at all. What `boot.c` must still do is *refuse* anything it does not implement,
loudly and with a clear message, rather than miscompile it — `test.sh` checks that for
`schema`, `tools` and `--debug`.

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
   pick a port with `tests/lib/portlib.sh` (see *Picking a port*, below), clean up any
   background process with a `trap`.
5. Run it alone, then run the whole suite.

**Never use a word from the language's own vocabulary as a test value.** A constant
`"wantzel"` or `"pascal"` is indistinguishable later from a real reference to the language —
pick a neutral word.

**Before a test runs a program, ask whether the bytes answer the question.** Most of what
a compiler gets wrong is visible in the file: the header, emission order, reproducibility.
Those checks are a `cmp` — milliseconds, nothing started, nothing left running.

**A test must never skip anything silently.** If it skips a check because something is
missing, it prints what and why — a test that quietly does nothing is indistinguishable from
one that passes.

## Picking a port

A test that needs a TCP port sources `tests/lib/portlib.sh` and calls `free_port` (one) or
`free_ports <n>` (several, always distinct from each other): each asks the kernel for a
currently-unused port by binding port 0 and reading the real number back with
`getsockname`, rather than guessing one from a fixed range or from `$$`. A guessed range —
even one derived from the test's own PID — is not safe under many parallel `./wztest` runs:
different worktrees' PIDs can coincide, different scripts' ranges can overlap, and the
number guessed can already be an ephemeral *source* port some unrelated connection on the
machine is using. `wait_port <port> [<tries>]` polls until something listens, and
`port_owner <port>` names who (if anyone) holds a port, for a clear failure message instead
of a bare "did not start" — see `tests/lib/portlib.sh` for the reasoning and the four
functions it provides.

## On failure

Report failing tests with the diff; fix the code, not the expectation, unless the change is
explicitly behavioural (record that in the work log). Only adjust an expectation once you've
independently established — by hand, with `od`, with a second implementation — that the new
result is correct.

A test that passes alone but fails in the suite is a finding, not noise: usually a shared
port, a leftover process, or a file two tests both write.
