# The design of Wantzel

Why this language exists, what it deliberately leaves out, and where the idea does not
hold. What the language *is*, rather than why, is [language.md](language.md), which is
binding.

---

## The name is the idea

Pierre Wantzel proved in 1837 what **cannot** be done. Trisecting an angle with compass and
straightedge, doubling a cube — people had tried for centuries, and he showed it is
impossible. Not "not managed yet", but *impossible*.

That is what a compiler should do: **say what cannot work, before you find out the hard
way.** It sounds like a limitation and it is the opposite. A proof that something is
impossible is liberating: you stop looking, and the time you would have spent on a dead end
goes to the road that does exist.

Everything below follows from that one idea.

---

## Three problems this language is an answer to

### 1. Dependencies

A program that needs packages needs all of their versions to agree, today and on every
machine it runs on, for as long as it runs. Each one is someone else's release schedule,
someone else's breaking change, someone else's security advisory. The count grows on its
own: you add one library, it brings thirty.

The cost is not only maintenance. It is that you cannot answer a simple question — *will
this still build in five years?* — without checking a tree you did not plant.

**What Wantzel does.** Zero dependencies, as an invariant rather than a target. The
standard library lives in this repository and changes in the same commit as the compiler.
There is no package manager, so there is no mechanism by which a dependency could be added.
Building needs a C compiler exactly once, for `bootstrap/boot.c`; after that the compiler
builds itself.

What you deploy is one static binary. No runtime to install on the target, no container to
describe the runtime, no migration step, no connection string. Deploying is copying a file.

### 2. Stacks that grew

Look at a mature project in a dynamically typed language and you find an enormous amount of
tooling that exists to compensate for the language: type checkers that add the types the
language lacks, linters that find errors a compiler could have found, frameworks that
impose the structure the language does not enforce, virtual environments to keep packages
from destroying each other.

Each of those is sensible on its own. Together they are a tower that has to stand upright
before a single line of your code runs, and every combination of versions is slightly
different from every other. When something breaks, the message can come from any layer.

The same thing happened to build times. Computers got a thousand times faster, and builds
got slower, because a build stopped being one compiler and became a compiler plus a bundler
plus a transpiler plus a package manager plus a test runner plus a container layer — each
with its own configuration and its own way of failing.

**What Wantzel does.** One binary that does everything, in **one pass**. The compiler reads
the source once and emits machine code as it goes: no AST, no intermediate representation,
no optimiser pass, no separate assembler or linker. Forward jumps are backpatched where
they stand.

That design is why compiling stops being a step you wait for. Trying something is free,
and the short loop between writing a line and knowing whether it holds is the most
valuable thing a language can give you.

It is measured rather than claimed: `./wztest --bench` reports lines per second and fails
against a hard floor kept beside it, so a regression in the thing this language exists for
shows up as a failing test rather than as a slow afternoon a year later.

The layers that a stack adds are either in the language or not needed. HTTP, JSON, MCP and
OAuth are ordinary library code in `lib/`, not a framework you configure. There is nothing
to keep in sync because there is nothing beside the compiler.

### 3. Errors that surface too late

An error that a compiler could have caught, but did not, becomes an error at run time —
which means in front of a user, or in a log nobody reads, or on the one code path the tests
do not cover. The worst case is code that exists, was reviewed, passes its tests, and could
never have worked.

This matters more now that an AI often writes the code. An AI that does not know something
is impossible **keeps searching**: it writes something plausible, gets a vague error, tries
a variation, builds a workaround, and sometimes produces something that runs — until one
day it does not. What it needs instead is a fast, hard answer at compile time, with a line
number. Then the loop is short: write, compile, error, fix, where each round takes seconds
and each error points at its own cause.

**What Wantzel does.** It moves as much as possible to compile time, and says exactly what
is wrong and where. Declarations are mandatory, a `forward` must be fulfilled, signatures
are compared, a function result may not be discarded, a procedure may not return a value,
and there are no implicit conversions anywhere.

What genuinely cannot be decided until the program runs is checked there, and reported with
file and line: every array index against both bounds, division by zero, `chr()` out of
range, a function that ends without a `return`. Locals are zeroed on every call, so there
are no undefined initial values.

Not checked, and stated plainly rather than implied: integer overflow, and anything reached
through `addr`, `view` or `sysN`.

---

## Why these three together

Each answer above is useful on its own, and they reinforce each other when a lot of code
is written quickly — by one person trying things, or by several at once.

**Starting has to be cheap, not just running.** There is no daemon, no incremental build
state, no lock file and no warm cache to share or corrupt: a process reads source and
writes a binary. So you can run the compiler as often as you like, in as many copies as
you like, and nothing coordinates them because there is nothing to coordinate.

**The error has to be the whole answer.** A message that names the file, the line and the
actual problem turns a failure into the next edit. A vague one, or a failure that only
appears at run time on one path, turns it into guessing.

**The pieces have to merge cleanly.** This is where zero dependencies stops being hygiene
and becomes structural: there is no package to add, so no two branches can disagree about
one, and no environment to reconcile. Every branch compiles against the same standard
library, which lives in this repository and moves in the same commit.

The same properties make the result reproducible. Any machine with a C compiler gets the
same binary from `bootstrap/boot.c`, byte for byte, with no network access and nothing
pinned — so a build can be rebuilt and checked rather than trusted.

None of this was designed for agents; it fell out of wanting a program you can copy instead
of install. But it is why the combination suits this way of working better than a faster
compiler alone would.

---

## A compiler for when you rarely write or read the code yourself

There is a shift underneath all of this that is worth naming plainly, because it changes
what a language is *for*.

A growing number of programmers rarely type their own code any more, and read only some
of it. The AI writes, they review and steer. That changes which properties of a language
matter.

When you wrote every line, you carried the program in your head: which function could be
trusted, which corner was fragile, where the assumption lived that everything leaned on.
That knowledge was the real safety net, not the compiler.

**When you did not write it, that net is gone.** You are reviewing code you have never
seen, and you cannot tell by eye whether a conversion is safe or whether an index can run
past the end. The code looks fine — plausible code is exactly what a generator is good at
producing.

So the tool has to hold what you used to hold:

- **What the compiler refuses, you do not have to check.** Every implicit conversion that
  does not exist is a review question you never have to ask. Strictness is not there to
  discipline the writer; it is there so the reader can stop looking.
- **Small enough to read cold.** One way per concept means an unfamiliar file uses the
  same constructions as a familiar one.
- **Nothing hidden.** No allocation you cannot see, no destructor on the way out, no
  dispatch you cannot follow. What the code says is what happens.
- **The specification is short enough to check against.** [language.md](language.md) is
  one document, and it binds.

None of that removes the need to review. It changes what a review is: reading for whether
the program does the right thing, rather than whether it is allowed to do what it says.

### The standard every compiler decision is measured against

Stated by the maintainer, 14 September 2026, as the sentence to weigh a proposal against:

> **A compact, fast, strict language, fit to be used in iterations by AI when agents write
> code.**

Four words, and each of them decides something. Compact: the whole specification is
readable in a sitting, so an agent that must consult it does not spend its attention
there. Fast: a build is short enough that a loop can afford to compile on every change,
which is what makes iteration possible at all. Strict: what the compiler refuses is what
nobody has to review. And *in iterations* is the one that is easy to miss -- the unit of
work is not a program a person writes once, but a cycle that runs many times, where every
signal is read by a machine before a human sees it.

That last point turns several ordinary preferences into requirements. None of these was
reasoned out in advance: each one is a bug that was fixed once the yardstick made the
answer obvious, and they are listed with the case that produced them because the case is
the argument.

- **An error must name the SOURCE, not the compiler.** A source that filled the data
  segment used to fail with `array index out of range at src/wantzel.wz:495`. Every word
  of that is true and all of it points the wrong way: the reader goes looking in the
  compiler, or — worse, if the reader is a generator — in its own code, for a fault that
  is not there. It now says `<file>:<line>: data segment overflow: the source is too
  large`. Naming the input is not politeness; it is the difference between a loop that
  converges and one that thrashes.

- **A limit must REFUSE — not truncate, not crash.** Three kinds of failure, and only one
  of them is usable. A crash gives a caller nothing to act on. Silent truncation gives it
  something worse: a result that looks complete. A clean refusal is a fact it can respond
  to. The distinction is not academic — it decided the shape of two different repairs on
  the same day. `io.push` may truncate, because its output is a *message* and a shortened
  error string is still a readable error string. A generated `<Schema>.write` must refuse,
  because its output is a *JSON object* that goes out as a protocol reply: truncating
  hands the peer an unparseable envelope, which moves the failure from "this one call
  failed cleanly" to "the session is broken and the reason is invisible". That is strictly
  worse than the crash it replaced, because at least a crash is loud.

- **Both halves of an operation must fail the same way.** When `io.push` was given a
  truncating contract, three neighbouring writers were left overrunning their buffers. The
  result was not two bugs but one worse property: a caller could form no model at all of
  what happens when output does not fit, because it depended on which half of the append
  it reached. Consistency here is not tidiness; an inconsistent contract cannot be
  remembered, and what cannot be remembered gets written wrong.

- **Silence must mean correct.** Exit 0 has to be trustworthy on its own, because
  something machine-read acts on it without weighing tone or context. This is where the
  no-warnings rule below comes from, and the yardstick is why it is not negotiable.

- **A routine's docstring is part of its contract, and a wrong one is a bug.**
  `kv.match` promised "subset match as used by entity searches" and delivered something
  narrower: a stored list could not contain anything, not even itself. The trap survived
  as long as it did because the repository *argued with itself* — one document called the
  behaviour a deliberate choice while the docstring implied the opposite, so a reader
  could find support for either belief and neither was tested. Prose about behaviour is
  either checked or it is a liability.

- **One way per concept, even where two would be convenient.** A second way is a second
  thing to learn, a second thing to review, and a second chance to pick the wrong one.

- **A behaviour change costs more here than elsewhere, and this is the rule most easily
  underestimated.** Code a generator produced last week is not reread when the rules shift
  underneath it; it simply starts being wrong, silently, in a place nobody is looking. So
  a change that alters what existing working code does needs a stronger argument than one
  that merely refuses something new — and when it is made anyway, both directions of the
  change get written down, including the shape that used to work and now does not.

- **Linux and Windows stay as identical as they can be made.** Floris, 14-09-2026: a
  platform difference is one more thing the writer has to hold in their head, and that is
  exactly what this language is trying to take off them. It weighs heavier here than in a
  language people write by hand: a human learns "on Windows this one is different" once
  and remembers it, while a generator has no such memory and will produce the Linux shape
  every time. So the difference belongs in the runtime, not in the program -- one call,
  one meaning, both targets. Where a platform genuinely cannot be hidden, it is named in
  [language.md](language.md) rather than left for a reader to discover, because an
  undocumented difference is the one that gets written wrong.

What those have in common is worth stating on its own: none of them makes the language
more powerful. Every one of them makes a failure easier to read correctly by something that
cannot ask a follow-up question. That is the whole of *fit to be used in iterations* -- the
yardstick does not ask what the language can express, it asks what a machine can conclude
from the answer.

Weigh a proposal against those, and a surprising number of questions answer themselves.
Where it does not decide, say so in the ticket instead of guessing -- a yardstick used to
justify a guess is worse than no yardstick, because the guess then arrives with a citation.

### So this compiler is built a little differently

- **No warnings — only errors.** A warning and an error are two ways of saying the same
  thing with a grey zone between them, and the grey zone does not survive contact with
  time: warnings pile up, get suppressed, and eventually nobody can tell whether a clean
  run means clean code or silenced noise. Here either something is wrong and compilation
  stops with one message, or there is silence. For anything reading that signal, exit 0
  means correct as far as the compiler can tell — a loop can be built on that, and not on
  "it worked, but there were nine remarks".

- **No exceptions either.** An index out of range, a division by zero, a function that
  ends without returning: each prints `runtime error:` with the file and line, and stops.
  There is no handler to swallow it and no log level to lower.

- **Both failures leave the same kind of trace.** `wantzel: file.wz:12: type error in
  assignment: expected int, found bool`, or `runtime error: array index out of range at
  file.wz:42`. One line on stderr, always that shape, with the source location in it.
  Anything reading the output — a test runner, a CI job, a person — can jump straight to
  the line and try again, without reproducing the problem under a debugger first.

  One honest limit. This covers what the *language* guarantees. A system call that fails —
  a file that is not there, a port already taken — is not a trap: it returns a negative
  number (`fs.open` on a missing path gives `-2`, which is `-ENOENT`) and your code decides
  what to do. That is deliberate, because a missing file is often an expected outcome
  rather than a defect, but it does mean an unchecked return value is the one way a failure
  can still pass by quietly. `lib/log.wz` exists for that side: one JSON line per event on
  stderr, in a shape a machine can read, so a handled failure leaves a trace as legible as
  an unhandled one.
- **The error text is the interface, not a by-product.** Every message names the file, the
  line and the actual problem in plain words — "a procedure has no value", "this parameter
  needs an array" — because for an agent that message is the entire feedback channel, and
  for a reviewer it is often the only explanation they will get. A message that does not
  point at its own cause is treated here as a defect in the compiler and filed as such —
  "forward declared routine is never defined" used to say only that, without naming the
  routine or pointing at its declaration, and that was fixed as a bug rather than tolerated
  as a quirk.
- **No optimiser.** Not from laziness: an optimising pass is the one thing that makes the
  generated code stop corresponding to the source you are reviewing. Straightforward code
  generation keeps what runs recognisable as what you read, and it is a large part of why
  compiling takes milliseconds.
- **The language changes rarely, and only on evidence.** A moving target is one more thing you would have to keep
  in your head, and one more way for code written last month to mean something else today.

### And it makes writing it by hand pleasant again

This is not only tooling for machines, and it would be a poor outcome if it were. The same
properties are what made programming feel light before the stacks grew: you press a key and
it runs; the error tells you exactly what is wrong and where; there is one way to express
the thing so you are not choosing between three; nothing is hidden, so you can follow what
happens; and there is no environment to set up before you start.

That combination is why Turbo Pascal was fun, and there is no reason it should have stopped
being available. So this language is not an AI-only language with humans tolerated — it is
a small, fast, strict language that happens to suit a generator for exactly the reasons it
suits a person. If you want to write every line yourself, the loop is as short as it ever
was, and the compiler is just as unwilling to let something wrong through.

This is the same idea as the name, arriving from the other side. A compiler that says
quickly and firmly what cannot work is worth most precisely when you are not the one who
wrote it — and it is still worth a great deal when you are.

---

## Influences

Two languages shaped this one, in different ways.

**Turbo Pascal**, for what a short loop feels like. I worked with it a great deal. It
compiled in the blink of an eye — you pressed a key and your program ran — and that speed
made something possible I have rarely experienced as well since: you *iterated in thought*,
not in waiting time. You simply tried things, because trying was free. One environment, one
step, strict enough to catch your mistakes, complete enough to build a whole project with.

Later everything got slower, and it is worth asking why, because computers got a thousand
times faster in the meantime. The gain went into layers: not one compiler but a compiler
plus a bundler plus a transpiler plus a package manager plus a linter plus a test runner
plus a container layer, each with its own configuration and its own way of breaking. The
speed target here is not nostalgia; it is a claim that the old loop is still available if
you decline the layers.

The syntax comes from the same place, for a plainer reason: Pascal reads almost like
pseudocode, with `begin`/`end` instead of braces, `:=` for assignment and `=` for
comparison, and types after the name. Little syntactic noise, and nothing to learn before
you can read the standard library.

**Go**, for what a deployable artifact should be. A static binary with no runtime to
install, fast builds, a standard library that can serve HTTP on its own rather than through
a framework, and a deliberately small language that resists clever constructions — those
are the right instincts, and this language shares all four. It pushes two of them further,
at a cost Go had good reason not to pay: dependencies are not merely few but structurally
impossible, and the contract for an API is a language construct rather than a code
generator run as an extra build step. The price is an ecosystem of one.

Neither is a model to copy. What is taken from Turbo Pascal is the loop, and what is taken
from Go is the shape of the thing you ship.

---

## One way per concept

Many languages want to be object-oriented *and* functional *and* procedural. Constructions
then appear that nobody fully oversees — three ways to do the same thing, each with its own
edge cases. For a person that is hard to hold. For a generator it is an invitation to be
inconsistent: one function in one style, the next in another, and nobody notices until it
matters.

Wantzel is procedural, strictly typed, and deliberately small: no heap, no pointers, no
function pointers, no overloading, no generics, no exceptions, no threads, no implicit
conversions. One type per concept.

That is a choice, not poverty. Fewer ways to express a thing means fewer ways to get it
wrong, and the expressiveness given up comes back as predictability — which is exactly what
both a reader and a generator need.

The rule is not only about types. Wherever two mechanisms would overlap, there is one:
`bool` and no `boolean`, `include` and no module system, and — as the
section above works out — errors and no warnings, because "valid" and "valid but I have
remarks" are two answers to a question that should have one. The deviations from Pascal are
the same rule applied case by case:

| Pascal | Wantzel | why |
|---|---|---|
| `boolean`, `integer`, `real`, `single`, `double` | `bool`, `int`, `real` | one type per concept; no choice is no mistake |
| pointers, `new`/`dispose` | absent | no heap means no memory leak and no use-after-free |
| `string`, `ansistring`, `pchar` | `str` (literal) + `array of char` | no hidden allocation |
| units, `uses` | `include` | one mechanism |
| `(* *)` and `{ }` | only `//` | `{ }` ended at the first `}`, so a brace in the comment text turned the rest of the sentence into code |

### The test that decides a syntax question

The rule above is easy to state and easy to misapply, because "one way per concept" sounds
like an argument for removing anything that has a neighbour. Every row in that table has
one thing in common, and it is the actual test:

> **Each deviation removes a *choice* between alternatives that meant the same thing.
> None of them removes a *distinction*.**

Six integer types collapse to one because they were six spellings of the same idea. `units`
and `include` were two mechanisms for one job. But `procedure` and `function` are not two
ways to say one thing — one returns a value the caller must use, the other does not, and the
rule that a result may not be discarded depends on telling them apart. Removing that would
cost something; removing `longint` cost nothing.

Two more things follow from it, and they settle most cases before an argument starts:

- **A familiar spelling is kept where it costs nothing — and "nothing" is a measurement,
  not an assumption.** The `{ }` comment looked free by this test: familiar to a Pascal
  reader, one branch in the lexer, arguably a second concept rather than a second spelling.
  The error log said otherwise — six of seven recorded syntax errors came from it, because
  it ended at the first `}` and a brace in the comment text turned prose into code. It was
  removed. Where a count exists, it outranks the argument.
- **Compatibility is not a goal; familiarity is.** Wantzel is not an ISO-7185 dialect and
  does not try to be. But "if you have written Pascal you will read Wantzel without
  explanation" is a promise worth keeping, and a change that *creates* a deviation where
  none existed — `end;` instead of `end.` — pays that price for nothing.

Where the two genuinely pull against each other, the yardstick above decides: a familiar
spelling that makes a *generator* likelier to be wrong loses, however comfortable it is for
a person. Case-insensitive identifiers with a merely cosmetic dot are the live example —
faithful to Pascal, and the largest single source of errors we have measured.

---

## Why schemas are compiled

This is problem 2 and problem 3 in their sharpest form, so it gets its own keyword.

Exposing one function to the outside world normally takes a stack of layers: a schema file,
a validation layer that reads it, a parser that turns JSON into objects, a serialisation
layer that turns them back, a router that decides which function to call, and a generator
that makes the documentation. Six pieces to describe one function, and the function itself
is the smallest of them.

Every one of those layers is *configured* rather than compiled. That has a direct
consequence: almost nothing they can get wrong is caught before the program runs. A field
arrives in a shape the parser did not expect, a route does not match what the schema
promised, a validator is skipped on one path, a serialiser silently drops a value. Each of
those is a runtime failure — in front of a caller — for a mistake that was fully knowable
while compiling.

**What Wantzel does.** The declaration *is* the implementation. A `schema` in your source
is compiled into the parser, the writer and the JSON Schema; there is no DOM, no reflection
and no allocation, and the parser reads straight out of the input buffer. A `tools` block
compiles into the MCP tool table, the argument parsing, the dispatch, the REST route and
the OpenAPI document.

The point is not that those layers are easier to configure here. It is that they are gone:
nothing is left to misconfigure, nothing has to be kept in sync, and the whole class of
runtime failure above cannot happen. A field that is not in the schema is not a validation
error at run time; it is a program that does not compile. Same idea as the name — make the
impossible impossible rather than catch it afterwards.

Two things follow from that, and both are the point rather than a bonus. The schema, the
code and the documentation cannot drift apart, because they are one source rather than
three that have to agree. And the generated parser is faster than a configured one, because
it does no lookup, allocates nothing, and knows every field at compile time.

The distinction that matters is what belongs *in the language* and what belongs in the
library. The contract goes in the language, because that is what otherwise falls apart
across six layers. The HTTP client does not: put that in the language and you can no longer
replace it.

---

## Where the idea does not hold

The question is not whether this is right for everyone. It is whether it is the right tool
for a given job, and what you give up is not little:

- **No ecosystem.** Every library you need, you write.
- **No debugger, no profiler, no IDE support.** Printf and tests.
- **Almost nobody knows this language.** The bus factor is very small.
- **No proven memory safety.** Only "no pointers" and a test suite — not years of work on a
  type system that proves it.
- **Every bug in the compiler is your bug.** An example: an enum level starting with a digit
  produces an invalid constant name. Elsewhere that is someone else's issue to fix; here it
  is a ticket with your own name on it.
- **A small language says no often.** Sometimes it says no to something reasonable, and the
  answer is to write more code rather than reach for a feature.

That list is the price, and it is a defensible price for a program that has to keep working
for years on a machine nobody maintains, where the number of moving parts matters more than
the speed of writing the first version. For a great deal of other work it is a bad price,
and the honest answer is to use something else.

An honest, measured comparison against other languages — one yardstick, and where each of
them beats this one — is still outstanding. Until that exists, everything above is a
reasoned position and not proof.

---

## What it comes down to

One binary you can copy instead of a stack you have to install. A compiler that answers in
milliseconds and says plainly what cannot work. One declaration where there were five
descriptions that could disagree.

The need was never "a new programming language". The need was a program you can copy rather
than install, that still builds in five years. That the language had to be new for that is a
consequence, not a goal.
