# Design

**Why the language is the way it is, and how the compiler works underneath it.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

What the language *is* belongs in [language.md](language.md), which is binding. This page
argues why: the yardstick every change is weighed against, the choices that follow from it,
and — in the second half — how the compiler itself is built.

The case for the compiler, stated plainly by the maintainer: **it is strict, fast and
verbose, has no dependencies, and gives errors an agent can act on.** Everything below
explains that sentence. It does not argue it against other languages — no benchmarks, no
essays — because the sentence is the argument.

## The yardstick

> **A compact, fast, strict language, fit to be used in iterations by AI when agents write
> code.**

| word | what it decides |
|---|---|
| compact | the whole specification is readable in one sitting; an agent does not spend its attention re-reading it |
| fast | a build is short enough to run on every change, which is what makes iteration possible at all |
| strict | what the compiler refuses is what nobody has to review by hand |
| in iterations | the unit of work is a cycle that runs many times, and every signal is read by a machine before a person sees it |

Weigh a proposal against those four. Where it does not decide, that is a ticket, not a
guess — a yardstick used to justify a guess is worse than none, because the guess then
arrives with a citation.

## The main choices, and their one-line reason

| choice | reason |
|---|---|
| **No pointers, no heap, no garbage collector** | an index into an array cannot dangle, is bounds-checked at every use, and survives being written to disk — every linked structure normally built with pointers has been built this way instead |
| **Strict typing, no implicit conversions** | what the compiler refuses is a review question nobody has to ask; a wrong call is a compile error, not a silent bug that ships |
| **One way per concept** | a second way is a second thing to learn, review, and get wrong; `bool` and no `boolean`, `include` and no module system, errors and no warnings |
| **No dependencies** | the standard library lives in this repository and moves in the same commit as the compiler; there is no package manager, so there is no mechanism by which a dependency could be added |
| **No optimiser** | the generated code stays recognisable as the source you reviewed, and it is most of why compiling takes milliseconds |
| **No warnings, only errors** | a grey zone between "wrong" and "fine, but" does not survive contact with time — it piles up and gets ignored; exit 0 has to mean correct |
| **Schemas are compiled, not configured** | a `schema` or `tools` block *is* the parser, the writer and the JSON Schema — nothing to keep in sync, and a wrong field is a compile error instead of a run-time surprise |

**`tools` deserves a separate mention.** It is the language construct that turns a group of
routines into an MCP tool table, argument parsing, dispatch, REST route and OpenAPI document
— all from one declaration. See [language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration).
It solves problem 3 below in its sharpest form: a contract that would otherwise be five
things that can disagree becomes one thing that cannot.

### Why a generator makes this stricter, not more permissive

A hundred recorded mistakes in generated Wantzel put library misuse (wrong routine, wrong
argument order) at 30 of 100 — bigger than syntax and namespace mistakes combined. A
permissive language answers a wrong call by doing something; a strict one refuses. For a
generator running in a loop, a refusal is a message the next iteration can act on; a silent
wrong answer is a bug that ships unnoticed. That asymmetry is why the language stays narrow
rather than growing convenience features.

### Three problems, answered once each

| problem | what happens without an answer | what Wantzel does |
|---|---|---|
| **Dependencies** | a tree you did not plant, and "will this still build in five years" has no answer | zero dependencies as an invariant; one static binary, nothing to install on the target |
| **Stacks that grew** | a build becomes compiler + bundler + transpiler + package manager + linter, each with its own way of failing | one binary, one pass, no AST, no intermediate representation; `hello.wz` compiles in ~3 ms |
| **Errors that surface too late** | a mistake a compiler could catch instead ships to a user or a log nobody reads | declarations mandatory, signatures checked, every array index and division checked at run time with file and line |

### Where the idea does not hold

No ecosystem — every library you need, you write. No debugger, no profiler, no IDE support
beyond `printf` and tests. Almost nobody knows this language. No proven memory safety, only
"no pointers" plus a test suite. Every compiler bug is your bug. A small language says no
often, including to reasonable requests. That is a real price, and the honest answer for a
lot of other work is to use something else.

---

## How the compiler works

One pass, no AST, no intermediate representation: the compiler reads source once and emits
machine code as it goes, backpatching forward jumps where they stand. It compiles itself
(6,772 lines) in about 10 ms.

### Two targets, one source

Library code names no platform. `lib/io.wz` writes a file with one line:

```pascal
return sys3(SYS.write, fd, a, n);
```

| target | what `sys3` emits |
|---|---|
| Linux | the `SYSCALL` instruction, literally — the kernel, nothing in between |
| Windows | a call into `__wsys`, generated by the compiler **in Wantzel**, which dispatches the Linux call number onto the matching kernel32/ws2_32 call |

`__wsys` emulates a Linux syscall interface on top of the Windows API; it covers what the
standard library needs, not all of Linux. Reaching a Windows API the compiler has never
heard of is a line of source, not a compiler change:

```pascal
winapi("user32.dll", "MessageBoxA", 0, text, title, 0);
```

The name is written into the executable's import table at compile time. The compiler itself
carries 48 built-in imports (27 kernel32, 11 ws2_32, 1 advapi32, 9 user32) — not for
convenience, but because the loader fills the import table *before the first instruction
runs*, so the startup path cannot look itself up. Anything needed only after the program has
started can be named from source instead.

On Linux there is no such table at all: the ELF this compiler writes has no dynamic section,
no `PT_INTERP`, nothing for `ld.so` to do. The kernel is reached directly through `sysN`, and
a shared library that was not there at build time cannot be called — calling it as a
**process** (`lib/proc.wz`, `fork`+`execve`, ~300 µs) is the answer that needs no compiler
change.

### Callbacks: letting Windows call you back

Linux events arrive on a socket and the program reads them in its own loop. Windows instead
*calls into* the program — it needs the address of a function, which this language does not
expose, on purpose: a function pointer is something nothing checks.

The compiler adds exactly one builtin, `winproc(handler)`, which does not return the
routine's address. It generates a small adapter beside the routine and returns the address
of *that* — moving arguments between the register conventions the two platforms disagree
about, and preserving the registers Windows expects untouched. Every Windows callback shape
(window procedures, hooks, timers, comparators) fits the same four-argument, one-result
adapter, so this is one mechanism, not a window-shaped special case. `winproc` compiles only
for `--target=windows`.

### Memory: an index is the pointer

No heap, no pointers, no garbage collector. Instead:

1. **All memory is an array with an upper bound.** A global array costs nothing until
   touched: pages are 4 KB each. Local arrays live on the stack and are zeroed.
2. **An index replaces a pointer.** It cannot dangle, is bounds-checked at every use, and
   still means the same thing after being written to disk and read back.
3. **Anything larger than the program wants to pin down comes through `mmap` and `view`**,
   which turns an address and a length into an ordinary, bounds-checked array — the capacity
   is disk or virtual memory, not RAM.

| situation | pattern |
|---|---|
| a growable list | array + counter, `-1` past the bound |
| text of unknown length | one arena array + `(offset, length)` slices |
| linked structures (list, tree, graph) | index fields, `-1` for none, a free list for reuse |
| key → value | open-addressed hash table on two parallel arrays |
| bigger than RAM, or must survive a restart | `mmap` on a file; the array *is* the file format |

The one thing an index cannot replace is the **address of a routine** — `addr(myroutine)` is
rejected, because that is the same unsafe function pointer callbacks need. `winproc` (above)
is the one deliberately narrow escape hatch for it.

### Debug info: the `.wzdbg` sidecar

`--debug` writes the executable byte-identical to a normal build, plus a text sidecar,
`<output>.wzdbg`, that a debugger reads to map addresses to source and memory to variables.
Own format, not DWARF: the only reader is a debugger for this compiler, and DWARF needs a
library on both ends that this project does not carry.

| record | fields | holds |
|---|---|---|
| `wzdbg` | version | format version (this page describes `1`) |
| `target` / `base` / `text` / `data` / `bss` / `entry` | address(+length) | where each image section lives — addresses in the file are process addresses directly, no relocation |
| `file` | id, path | source file table; a path starting `<` has no source (generated runtime code) |
| `line` | address, file, line, kind | maps code to source; `kind` is `s` (statement start — the only safe breakpoint), `p` (prologue), or `e` (implicit return) |
| `func` / `main` | name, start, end, file, line, framesize, result type | one routine's code range and frame size, followed by its `param`/`local` records |
| `param` / `local` / `global` | name, location, type, array flag, bounds | where a variable lives and how to read it |
| `record` / `field` | name, size, fields | a record type's layout, for typed variables of that type |

Frames are found through the **rbp chain**: `[rbp]` is the caller's saved rbp, `[rbp+8]` the
return address. At a statement-start (`s`) line, `rsp = rbp - framesize` and every variable
is in memory — nothing is kept in a register across statements, so that is always a safe
stopping point.

### Calling convention

| what | Linux | Windows |
|---|---|---|
| up to 10 parameters | `rdi, rsi, rdx, rcx, r8, r9, r12, r13, r14, r15` | same registers (Wantzel's own convention; Windows API calls go through `winapi`/callback adapters instead) |
| array parameter | two registers: base pointer, then length | same |
| result | `rax` (a `real` result is its IEEE-754 bit pattern in `rax`) | same |
| frame set-up | `push rbp; mov rbp, rsp; sub rsp, framesize`, locals zeroed | same |

### Types, in memory

| type | size | layout |
|---|---|---|
| `int` | 8 | two's-complement, little-endian |
| `char` | 1 | one byte |
| `bool` | 1 | `0` or `1` |
| `real` | 8 | IEEE-754 double |
| `str` | 8 | address of the first character; length is the 8 bytes before it; NUL-terminated; `0` is the empty string |
| `record` | sum of fields | declaration order; `char`/`bool` fields 1-aligned, everything else 8-aligned, size rounded up to a multiple of 8 |

### What already works, beyond the standard library

`sysN` emits the raw syscall instruction and the compiler knows no call by name, so anything
the kernel offers is reachable without a compiler change — including things once assumed
impossible:

| capability | status |
|---|---|
| `fork`, copy-on-write, exit codes and signals, non-blocking reap | works, measured |
| shared memory and locking between processes | works, measured |
| several worker processes behind one listening socket | works (`http.serve`) |
| durable storage with crash recovery | works (`lib/store.wz`: append-only log + snapshot) |
| multiple writers to one store | not done — a deliberate choice, not a limit; the primitives (`MAP_SHARED`, `flock`) are already present |
| TLS | no — handled by a process in front; the one honest exception to "no dependencies" |
| threads | no, and stays no — separate processes do the same job without shared state |

### Measurements the design rests on

Same machine (Intel Core Ultra 7 258V, 6 cores, 16 GB), same job where stated: counting a
pattern in a 2 GB file, every implementation giving the identical answer.

| measure | value | what it means |
|---|---|---|
| compile speed | a 189-line program: 3 ms. The compiler itself, 6,772 lines: ~10 ms | one pass, no optimiser — compiling is not a step you wait for |
| binary size | 22,786 bytes, static, vs. 2,040,611 for the same program in Go | a factor of 89.6 with no runtime hidden on either side |
| run time | 0.72 s (`mmap` + scan) vs. 0.82 s for the same approach in Go | no optimiser does not cost speed for this class of program; the gap against Go's `read()`-based version (1.17 s) is larger but is an I/O-strategy difference, not code generation |
| generated-code mistakes | 30 of 100 recorded errors are library misuse, more than syntax and namespace combined | the strictness and the whole-program examples in [writing-wantzel.md](writing-wantzel.md) answer this category specifically |

These numbers are narrow by design: one machine, one class of program (a tight byte loop,
exactly where an optimiser has least to find), and the run-time lead is mostly `mmap`, not
code generation. They are not a claim against other languages in general — only evidence for
the specific trade made above.

### No pointers: what was tried before trusting it

Nine linked structures were built without pointers — list, tree, graph with cycles, a
heterogeneous AST, a free list, zero-copy views, arbitrary OS memory as an array — and all
nine work, with two actively better off: a cyclic graph needs no ownership tracking (nothing
to free), and an index-based structure written to disk and read back has every link still
valid with no fix-up pass. The one place this does not extend is a **function** address,
which callbacks (above) solve with a narrow, checked exception rather than general pointers.

---

## Influences

Two languages shaped this one. **Turbo Pascal**, for what a short compile-run loop feels
like, and for syntax that reads close to pseudocode. **Go**, for what a deployable artifact
should be: a static binary, fast builds, a capable standard library, a deliberately small
language. Wantzel pushes both further than either did: dependencies are not merely few but
structurally impossible, and an API contract is a language construct rather than a generator
run as a build step.

## What it comes down to

One binary you can copy instead of a stack you have to install. A compiler that answers in
milliseconds and says plainly what cannot work. One declaration where there were five
descriptions that could disagree. The language had to be new to get there; that was a
consequence, not the goal.
