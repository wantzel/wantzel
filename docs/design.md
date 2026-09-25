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
| **One way per concept** | a second way is a second thing to learn, review, and get wrong; `bool` and no `boolean`, `import` for the library and `include` for a file and no module system, errors and no warnings |
| **No dependencies** | the standard library lives in this repository, moves in the same commit as the compiler, and travels inside the compiler file; there is no package manager, so there is no mechanism by which a dependency could be added |
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
in milliseconds; `tests/bench/compile_self.sh` measures the current number against a hard
floor.

### Bootstrapping: one small C compiler, once

`src/wantzel.wz` is the real compiler: self-hosted, the whole language, one file.
`bootstrap/boot.c` exists only to build the first binary from a fresh clone, so it needs to
do exactly one thing well — compile `src/wantzel.wz` — and nothing else. It does not
implement `schema`, `tools`, `import` or `--debug`, because the compiler's own source uses
none of them.
The bootstrap chain is `boot.c` → stage1 → stage2 → stage3, and the fixed point that
matters is stage2 = stage3: the self-hosted compiler reproducing itself. Stage1 only has
to be *correct*, not byte-identical to the others — see
[testing.md](testing.md#the-bootstrap-fixed-point) for the check and what it does and does
not catch.

### One file: the standard library travels in the compiler

`wantzel` is one file. The standard library is part of it: `import io;` compiles the `io` of
*this* compiler, read from the compiler's own file, and from nowhere else — no `lib/`
directory on disk, no environment variable, no flag, no search order. The same source and
the same compiler file give the same executable wherever either of them sits, and two
compilers whose `--version` lines agree compile every `import` to the same text.

**How it is stored.** After the fixed-point check, `build.sh` appends a *trailer* to the
compiler. The ELF loader never maps it — the program header stops before it — and the
compiler reads it from `/proc/self/exe`:

```
<the compiler, exactly as the fixed point produced it>
<part> <part> ...            each part's bytes, one after the other
<index>                      one line per part:  <name> <offset> <length> <size> <form>
<footer, 101 bytes>          WZPARTS1 <index offset:12> <index length:8> <parts:4> <sha256:64>\n
```

Every position counts from the start of the trailer, so the trailer does not depend on the
compiler in front of it. `offset` and `length` locate the stored bytes, `size` is the length
of the original text, and `form` is `lz` (packed as `lib/lz.wz` packs) or `raw` (stored as
it is). The sha256 covers the original texts — it is `sha256sum` over the parts, piped
through `sha256sum` once more — so it can be checked against the source tree with nothing
but coreutils; `wantzel --version` prints it.

**Named parts, so the one file can carry more.** The library is the set of parts called
`lib/<module>.wz`. Nothing else is in the trailer today, but the index is a list of names,
not a list of modules: other text — a licence, a reference page — can be appended as a part
of its own, raw or packed, and a later `wantzel --dump <name>` would print it by name the
way `--lib` prints a module. That is a new name in the index and a new mode on the command
line; the format, the footer and every existing reader stay as they are.

**Packed.** Each module is packed on its own with `lib/lz.wz` — the simplest LZ format there
is, literal runs and back-references, no entropy coding — so an `import` unpacks only the
module it names. The library packs to about half its size; unpacking `io` takes some tens
of microseconds. The compiler cannot import `lib/lz.wz` (its own source imports nothing), so
it carries a copy of `lz.unpack`; `tests/toolchain/lz_copy_is_identical.sh` keeps the two
texts identical, and the unpacker checks every count and offset before it uses it, so a
damaged trailer is refused with a message instead of read past a buffer.

**The build order**, and why it is this one:

1. `boot.c` → stage1 → stage2 → stage3, as always. The fixed point compares stage2 and
   stage3 *without* a trailer: it is a property of the compiler alone.
2. stage3 compiles `bootstrap/libpack.wz`. stage3 carries no library yet, so `libpack`
   imports nothing; it takes the packer from `lib/lz.wz` by path, as a file.
3. `libpack <sha256> lib/*.wz > trailer` — the modules in byte order of their names, no
   timestamps: the same `lib/` always gives the same trailer.
4. `cat stage3 trailer` becomes `bin/wantzel` — but only after every module read back
   through the new compiler (`wantzel --lib <module>`) equals its file in `lib/`, and
   `--version` carries the sum. One difference and nothing is installed.

`./wztest` rebuilds when a file in `lib/` is newer than `bin/wantzel`, so a test of the
library always runs against the library as it is on disk — packed, exactly as a user gets it.

**Why nothing overrides it.** A copy of a module on disk that wins over the built-in one is
a second place an `import` can be answered from, and then the question "which copy did
this build use?" has no answer in the output. Experimenting with a module is still one line:
copy it and include the copy as a file (`include "./tls.wz";`) — a file is always a file.

**Why it is not precompiled.** The library is kept as source, not as compiled tables: the
compiler is one pass with no intermediate form, so "precompiled" would mean a snapshot of
every symbol table, in a second format that has to change with every table. Measured, it
would save at most 7% of a large program's compile time; parsing the library is not where
the time goes.

### Unused routines never reach the executable

Every module a program imports compiles in full, but only the routines it actually calls
end up in the file: after parsing, the compiler builds the call graph from its own
relocations and drops everything unreachable from the main block, before writing the ELF
image.

**How.** A routine's code is one contiguous range, and every reference to it (a call, a jump
to data, a jump to bss) is a relocation recorded at the offset it sits at. A relocation's
*kind* already says whether it is a call to a routine (as opposed to a data or bss
reference), so the call graph does not need a separate pass over the source: a routine's own
relocations, read back, are exactly the routines it calls. The main block and the entry
code are the two roots; everything not reachable from them is dead. Live routines are then
copied down over the gaps the dead ones leave, and every surviving relocation is shifted by
however much its own bytes moved.

**Always on, no flag**, because the output has to stay deterministic and a flag would be a
second code path nothing exercises by default. **Skipped under `--debug`**: the debug
sidecar's addresses are written into it as the code is generated, line by line, long before
this pass knows what will move where. Rewriting the sidecar afterwards would be a second
serialisation of every address; instead a `--debug` build keeps every routine, so its
addresses are exactly the ones the sidecar recorded. It is therefore larger than a plain
build, and not byte-identical to it.

Measured: `hello.wz` with an unused `import tls;` — nothing from `tls` is called, so none of
it survives — drops from 348 KB to 56 KB. A program with most of its imported modules
genuinely in use shrinks by a smaller fraction: `examples/mcpfiles.wz` goes from 847 KB with
0.4.0 to 707 KB; `examples/serve.wz`, which uses less of what it imports, from 500 KB to
257 KB.

### One syscall layer

Library code names no operating-system function. `lib/io.wz` writes a file with one line:

```pascal
return sys3(SYS.write, fd, a, n);
```

and `sys3` emits the `SYSCALL` instruction, literally — the kernel, nothing in between. The
call number is an ordinary constant in `lib/io.wz`, so the compiler knows no syscall by
name and anything the kernel offers is reachable from source.

There is no import table: the ELF this compiler writes has no dynamic section, no
`PT_INTERP`, nothing for `ld.so` to do. A shared library that was not there at build time
cannot be called — calling it as a **process** (`lib/proc.wz`, `fork`+`execve`, ~300 µs)
is the answer that needs no compiler change. Events arrive on a descriptor and the program
reads them in its own loop; nothing ever calls into the program, so the language needs no
function pointer and has none.

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
rejected, because that is a function pointer, and nothing checks one.

### Debug info: the `.wzdbg` sidecar

`--debug` writes the executable -- with every routine kept, since unused routines are only
dropped from a plain build (see above) -- plus a text sidecar,
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

| what | how |
|---|---|
| up to 10 parameters | `rdi, rsi, rdx, rcx, r8, r9, r12, r13, r14, r15` — the first six are the System V order, so the syscall builtins share the code |
| array parameter | two registers: base pointer, then length |
| result | `rax` (a `real` result is its IEEE-754 bit pattern in `rax`) |
| frame set-up | `push rbp; mov rbp, rsp; sub rsp, framesize`, locals zeroed |

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
| compile speed | a 189-line program: 3 ms. The compiler itself, 6,495 lines: ~9 ms (median of ten, 721,666 lines/s) | one pass, no optimiser — compiling is not a step you wait for |
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
and the language has none.

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
