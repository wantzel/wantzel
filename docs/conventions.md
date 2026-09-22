# Conventions

Agreements that give direction without being rules. Nothing here is enforced by the
compiler, nothing here will make a program fail to build, and a program that ignores all of
it is still a correct Wantzel program.

That is the point. The bar for changing the language is deliberately high — it takes
evidence, not preference, and [`design.md`](design.md) explains why. But plenty of useful
agreements do not deserve a language change and still should not be re-decided in every
project. This is where those live.

For what the language *means*, see [`language.md`](language.md), which is binding. For how
it is *written*, see [`syntax.md`](syntax.md). For how to write it *well*, see
[`writing-wantzel.md`](writing-wantzel.md). This file is the softest of the four, and it
says so on purpose.

---

## How something gets in here, and how it leaves

```
an idea  ->  a convention  ->  used in practice  ->  measured  ->  maybe the language
```

A convention is a **proposal that has been written down and is being tried**. It earns its
place by being followed, and it keeps its place by staying useful.

**Promotion.** When a convention has been followed long enough that departing from it is
surprising, and there is a count behind it, it is a candidate for
[`language.md`](language.md) or for the compiler. That move needs the same evidence any
language change needs — the convention having been popular is not itself the evidence.

**Removal.** A convention nobody follows is deleted, not left standing. A document full of
agreements that are quietly ignored teaches readers to ignore the document. If something
here has drifted from what the code does, the code usually wins: describe reality, or
change reality, but do not let the two disagree in silence.

---

## 1. The entry point of an application is `main.wz`

**A program made of several files names its entry point `main.wz`.**

### The problem it solves

Nothing marks which file is the program. A `.wz` file is a program when it has a top-level
`begin ... end.` and an include when it does not, and that difference appears nowhere in
the name. To find the entry point of an application you have to open its files and look.

That is a small irritation for a person reading five files and a real one for a tool. It is
worse for an AI writing code against an unfamiliar project, which is the audience the
language is built for: there is no signal to go on, so it guesses.

### What it costs when there is no convention

Measured, not imagined. An editor that compiles the file you have open when you press F9
runs into this constantly. In one application's Windows directory, of twenty-two source
files exactly one is a program — so twenty-one times out of twenty-two the compiler
answers:

```
wantzel: src/theme.wz:1: missing begin of the main program
```

— a message that says nothing about your code and everything about what the editor handed
the compiler. With a convention, a tool can *propose* `main.wz` instead of guessing.

### The rule, in three parts

1. **An application of several files** names its entry point `main.wz`.
2. **A single-file program** is named after itself: `hello.wz`, `cat.wz`, `httpd.wz`.
   A directory of eleven examples all called `main.wz` would be unusable — which is exactly
   why this is a convention and not a compiler rule.
3. **Several programs in one project** each get their own directory with a `main.wz` in it.

### It already is the convention

Counted on 16 September 2026 over every file with a top-level `end.`, with "files in the
directory" as the measure — crude, but it is the thing a reader or a tool can see without
parsing anything:

| entry point | `.wz` in its directory | named `main.wz` |
|---|---|---|
| a desktop editor, Windows build | 22 | yes |
| a task server | 7 | yes |
| the same editor, X11 build | 6 | yes |
| one program built five ways | 2–4 each | yes |
| `wantzel/src/wantzel.wz` | 2 | no |

**Every multi-file application measured already does it**, with one exception, named below.
The applications themselves are not in this repository; what carries over is the count and
the rule it supports.

`examples/` sits outside this table on purpose. Its twelve programs share one directory, so
by the measure above each has eleven "siblings" — and every one of them is a single-file
program that includes only from `lib/`. That is part 2 of the rule, not a departure from it,
and it is the clearest argument for why this can never be a compiler requirement: eleven
files called `main.wz` in one directory would be unusable.

Five implementations of one program, in five directories with five `main.wz`, is the
pattern for part 3.

### The exception, and why it keeps its name

**`wantzel/src/wantzel.wz`** — the compiler's own source. It has a counterpart in
`bootstrap/boot.c` that must stay in step with it line for line, and it is named in scripts
and documentation throughout. Renaming it is risk with no return.

**It is not being renamed.** A convention that reaches back and disturbs working code is a
convention people learn to ignore. New applications follow it; existing ones are left alone.

### What this convention is *not*

- **Not a compiler requirement.** `wantzel anything.wz out` works and will keep working.
  The compiler does not know or care what a file is called.
- **Not an automatic search.** The compiler will not look for a `main.wz` when you omit the
  source argument. That is magic, and it guesses wrong the moment a directory holds two
  programs.
- **Not retroactive.** See the exception above.

---

## 2. A module prefixes its names

**Names that belong to one file share a prefix: `tree.paint`, `doc.save`, `run.go`.**

The language has no namespaces, and `include` is textual — everything lands in one flat
scope. The prefix *is* the namespace, and it is doing real work: it says where a name comes
from, it keeps two modules from colliding, and it makes a name greppable to exactly one
file.

This is already universal in `lib/` (`json.parse`, `io.puts`, `http.get`) and in every
application of any size. It is written down here because it has never been written down
anywhere, and a newcomer reading one file cannot tell it is a convention rather than an
accident.

The prefix matches the file: `tree.wz` defines `tree.*`. Where a file is one obvious noun
the short form is fine — `doc.wz` defines `doc.*`, not `document.*`.

---

## 3. Constants are `SCREAMING_CASE`

**A compile-time constant is written in capitals with underscores: `DOCMAX`,
`FILE_SHARE_READ`, `TH_KEYWORD`.**

Case does not distinguish names in Wantzel, so this carries no meaning to the compiler — it
is purely for the reader, and it earns its place by being reliable enough to *act* on. An
editor can colour a name teal when it is all capitals, without a symbol table and without
asking the compiler, and be right essentially always.

That is the test for a convention worth keeping: a tool can lean on it.

---

## Candidates, not yet conventions

Written down so they are not lost, and marked clearly so nobody mistakes them for settled.

- **Where tests live and what they are called.** Each repository currently decides for
  itself. Worth an agreement once there are more repositories than the ones here.
- **How an application lays out its directories.** `src/`, `docs/`, `bin/` is what everything
  does, but "what everything does" is not the same as having been agreed.

Add to this list freely. The cost of a bad candidate is one paragraph; the cost of a bad
language rule is everything downstream of it.
