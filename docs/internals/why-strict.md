# Why a language written by a generator is stricter

*Derived from 100 recorded mistakes in generated Wantzel, counted 15 September 2026.*

Wantzel is deliberately narrow: one type per concept, one way per concept, procedural only,
no pointers, no heap. That reads like asceticism. It is not — it is a response to a
measurement, and the measurement is what makes it arguable rather than a matter of taste.

## What actually goes wrong

A hundred real mistakes in generated Wantzel were recorded as they happened, with the error
message, the cause and the fix. The categories are not evenly sized:

| category | share | what it looks like |
|---|---|---|
| **library use** | **30 / 100** | a routine name that does not exist, arguments in the wrong order |
| namespace | 15 / 100 | a name that collides with something already there |
| syntax | 7 / 100 | a comment form, a literal, a declaration in the wrong place |

The largest category is **not syntax**. It is bigger than syntax and namespace together.
That is the finding that shapes the language, and it points somewhere unexpected: a
generator does not mostly get the grammar wrong. It gets *the shape of a call* wrong.

## Why that argues for strictness rather than flexibility

A permissive language answers a wrong call by doing something. A strict one refuses. When
the writer is a generator running in a loop, those two outcomes are not close:

- a **refusal** is a message, and the next iteration has something to work with
- a **silent wrong answer** is a bug that ships, and nothing in the loop notices

That asymmetry is the whole argument. It is also why the compiler's error messages are
treated as a feature with the same weight as code generation: an error that does not name
the identifier costs an extra round trip every single time, and those rounds are the budget.

## One way per concept, and what it buys

Many modern languages want to be object-oriented *and* functional *and* procedural. Each
addition is reasonable alone; together they produce constructions nobody fully oversees, and
a generator will happily mix three styles in one file because all three appear in its
training data.

Wantzel does one thing. A generator that has seen the language has seen the only way to
express something, so there is no style to choose and no mixture to get wrong. The narrowness
is not a limitation imposed on the writer — it removes a decision that has no right answer.

## What follows for a library

If wrong library use is the largest category, the fix is not more reference tables. "`io.push`
takes `(buffer, at, s)`" is a fact you have to remember. A complete, working fragment that
fills a buffer and guards its bound is a shape to copy, and copying a shape is what a
generator is good at.

That is why [`writing-wantzel.md`](../writing-wantzel.md) carries whole working programs
rather than only reference tables, and why `tests/toolchain/doc_programs_compile.sh`
compiles every one of them on each run. A fragment that no longer compiles is a failing
test, not a quietly rotting file.

It is also why the compiler answers `undeclared identifier: io.puts` with the library the
name lives in and the include line to add: the fix arrives with the diagnosis instead of
requiring a lookup.

### The history worth knowing

This has been tried before. The **Source Ware Archival Group** distributed thousands of
complete Turbo Pascal fragments from the late 1980s, filed by subject, insertable straight
into an editor. It worked, and then it died — for three reasons that all still apply:

- **the language moved out from under it.** Fragments for one version stopped compiling
  under the next. Nobody maintained them; there were thousands.
- **the distribution model disappeared.** A package you downloaded and kept locally made
  sense before the web.
- **nobody owned the content.** People contributed; nobody removed.

The first is the sharp one. Version 0.2.0 of this language removed `{ }` as a comment form —
every fragment using block comments would have broken at that moment, silently, because a
collection nobody compiles notices nothing.

Hence the two rules that follow from it: **fragments are extracted from running code, not
invented**, and **a test compiles all of them**. And the collection stays small on purpose.
Thousands was SWAG's strength in an age without search; it is now exactly the size nobody
maintains.

## How this would be shown to be wrong

The claim is that fragments reduce wrong library use. That is measurable: the category stands
at 30 of 100. If it stays there while the collection grows, the bet was wrong — and that
should be written down rather than left out.
