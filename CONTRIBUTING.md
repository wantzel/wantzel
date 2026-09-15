# Contributing

Thanks for looking. Wantzel is a small project and contributions are genuinely welcome —
bug reports and worked-out pull requests alike.

One thing to set expectations: this is a one-person project. Reckon on days rather than
hours for a reply, and do not read silence as disinterest.

## What is welcome

**Bug reports.** The most useful kind by far. See below for what to include.

**Pull requests**, in all three parts of the project:

- **The language specification** ([docs/language.md](docs/language.md)) — before 1.0
  anything here can still change, but the bar is **evidence, not preference**: a proposal
  needs a count behind it, ideally real errors from real programs. Two changes landed that
  way recently — `{ }` stopped being a comment because it caused six of seven recorded
  syntax errors, and a dotted name part may now start with a digit because a schema
  generated a constant the compiler could not read back. If the specification is unclear,
  contradicts the compiler, or describes something that cannot be expressed, that is worth
  fixing outright.
- **The compiler** (`src/wantzel.wz` and `bootstrap/boot.c`) — bug fixes, better error
  messages, code generation.
- **The standard library** (`lib/`) — the same, plus routines that are genuinely missing.

Documentation, examples and tests are welcome everywhere, and a PR that only improves a
confusing error message is a good PR.

## Reporting a bug

Include these four things and there is a good chance it can be fixed without a round trip:

1. **The output of `wantzel --version`.**
2. **Your platform** — Linux or Windows, and which distribution if that seems relevant.
3. **A `.wz` file that reproduces it**, as small as you can make it. If a program stops
   failing when you cut it down, that itself is worth mentioning.
4. **What you expected, and what happened** — including the exact message. Compiler errors
   look like `wantzel: file.wz:12: ...` and runtime errors like
   `runtime error: ... at file.wz:42`; both name the line, so please paste them whole.

A bug in the *specification* — where the compiler and [docs/language.md](docs/language.md)
disagree — is worth reporting too. The specification is binding, so that is always a real
bug in one of the two.

## What is unlikely to be accepted

Written down **before** it comes up rather than after, because deciding under the pressure
of someone's finished work is how a project ends up with things it did not want. None of
this is a judgement on the idea; it is about what this project is.

- **A dependency.** Not a small one either. The build and the test suite use a C compiler
  and a POSIX shell, and that is the whole list — no Python, no build system, no package
  manager. "Zero dependencies" is the claim the project makes, so accepting one ends it.
- **A package manager, or anything that fetches code at build time.** The download is the
  whole toolchain: one binary with the standard library inside it. Sharing a library here
  means sharing a `.wz` file.
- **A second way to do something that already has one.** The language removes choices
  between things that mean the same; it keeps distinctions. A convenience form beside an
  existing one is the kind of addition that is easy to accept once and impossible to
  remove.
- **A language feature without a count behind it.** "Other languages have it" is not an
  argument here, and neither is elegance. What counts is evidence that its absence makes
  real programs wrong.
- **A change to only one platform.** Linux and Windows move together, always.
- **A rewrite.** Of the compiler, the library, or a substantial part of either. Not because
  the current code is sacred but because reviewing it honestly would cost more than writing
  it, and this is a one-person project.
- **Formatting-only changes across files you are not otherwise touching.** They make the
  history harder to read for everyone after you.

If you are unsure whether something falls in here, an issue first costs both of us far
less than a finished pull request.

## Before you open a pull request

```bash
./build.sh              # bootstrap, and check the fixed point
./wztest --toolchain    # the whole suite, including the toolchain checks
```

Both must be green. `--toolchain` matters: it rebuilds the compiler with itself and
checks the result is byte-identical, which is the check that catches most compiler
changes going subtly wrong.

Four things that are easy to miss, all of which the suite will tell you about:

- **`src/wantzel.wz` and `bootstrap/boot.c` are counterparts.** They implement the same
  compiler, one in Wantzel and one in C. Change one and you change the other in the same
  commit, or the bootstrap fixed point breaks.
- **Both targets, always.** A change to the compiler, the runtime or `lib/` carries the
  Linux and the Windows side. "The tests run on Linux anyway" is not an argument.
- **No external dependencies.** Zero is a hard requirement, not a score. The build and the
  test suite use nothing beyond a C compiler and a POSIX shell — not even Python.
- **A new keyword means a new grammar entry.** The syntax highlighting in
  `editors/vscode/` is generated from the compiler's own keyword table, so a word the
  lexer learns must be added there too, under the rule it belongs to.
  `tests/toolchain/grammar_matches_compiler.sh` fails if it is not.
- **A test with the change.** [docs/testing.md](docs/testing.md) explains the forms a test
  can take; the shortest is a `.wz` file with a `.out` file beside it.

If you are unsure whether an idea fits, open an issue before writing the code. That is
cheaper for both of us than a finished PR that turns out to be the wrong direction.

## Sign your commits (DCO)

Please add a `Signed-off-by` line to your commits:

```bash
git commit -s -m "Your message"
```

That line is how you agree to the
[Developer Certificate of Origin](https://developercertificate.org/) — a short statement
used by the Linux kernel, Git and many others. In one sentence: you are saying you have
the right to submit this code, because you wrote it, or because it came from somewhere
with a compatible licence and you may pass it on.

**You keep the copyright on what you write.** Nothing is assigned and there is no
agreement to sign. Your contribution goes in under the same MIT licence as the rest of the
repository, and your name stays on it in the history.

## Style

Match the code around what you are changing. Beyond that:

- **Comments say why, not what.** The code already says what it does.
- **English**, everywhere: code, comments, commit messages, documentation.
- **A commit message explains the change**, not the file list. Why it was wrong, and why
  this fixes it.

## Security

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).
