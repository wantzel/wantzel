# Changelog

What changed, for someone who uses Wantzel. Three kinds of change, because they ask
different things of you:

| | what it affects | what it means for you |
|---|---|---|
| **Language** | anyone who **wrote** Wantzel code | a program that compiled yesterday may not today, or may mean something else |
| **Compiler** | anyone who **compiles** | the same program, the same meaning — but different messages, different code, different limits |
| **Library** | anyone who **includes** `lib/` | a routine, its behaviour or text it emits changed; your own code may need to follow |

**Before 1.0, a Language entry can appear in any release.** This is a young language and a
construct that costs more than it gives is removed rather than kept; see
[`language.md`](language.md) §9. Read that row first on every upgrade.

Newest first. Dates are the day the change landed.

---

## 0.2.1 — 15 September 2026

**Read this row first: three keywords are gone, and sources that use them no longer
compile.** `program`, `repeat ... until` and `case` were each removed after counting how
often a generator actually chose them — the numbers are in the entries below. Every one is
refused with a message that names the replacement, so a source that still uses them fails at
the first line that does, not somewhere later.

What to change, in order of how likely you are to hit it:

| if your source has | write instead |
|---|---|
| `program name;` at the top | delete that line |
| `case x of ...` | an if-chain; an `else` binds to the nearest unclosed `if`, so an arm whose body is an `if` needs `begin ... end` |
| `repeat ... until done` | `while true do begin ... if done then break; end` |
| an output name ending in `.exe` | add `--target=windows`; the name alone no longer selects the target |

Beyond those: `\xHH` byte escapes in `char` and `str` literals, `winproc(name)` so Windows
can call a Wantzel routine back, and a dotted name part may now start with a digit. Forty-three
keywords became thirty-nine.


### Language

- **The `program` header is gone.** `program name;` at the top of a file was read and thrown
  away: the name was stored nowhere and an included file was never treated differently, so
  requiring it bought nothing — while refusing a file without one made a library impossible
  to compile on its own. A file now starts with its first declaration. A source that still
  carries the header is refused with a message saying to delete that line, and `program` is
  an ordinary name again. Forty-two keywords, from forty-three.
- **`repeat ... until` is gone.** In 73,000 lines of generated code the construct was chosen
  once, in a hand-written library routine; everywhere else the generator wrote `while`. One
  way to loop with the test at the end: `while true do begin ... if done then break; end`. A
  source that still uses `repeat` is refused with a message that says so. Forty keywords.
- **`case` is gone.** Measured over 73,270 lines written almost entirely by a generator:
  251 times a chain of `else if` compared a value against constants and could have been a
  `case`, against 68 times one was actually written — four to one against, in files that
  used `case` elsewhere. A language meant to be written by a generator should not carry a
  form the generator avoids. Write an if-chain; an `else` binds to the nearest unclosed
  `if`, so an arm whose body is an `if` needs `begin ... end`. A source that still uses
  `case` is refused with a message saying what to write instead. Thirty-nine keywords.
- **`\xHH` is a byte escape in a `char` or `str` literal**, with **exactly two** hex
  digits. A generator embedding UTF-8 or binary had to write a `chr(n)` statement per
  non-ASCII byte: 558 kB of data became 2.5 MB of source. Two digits and never a variable
  number, unlike C — so `"\x41BC"` is three characters and a generator can write a byte
  followed by a literal hex character. Nothing that compiled before changes meaning.
- **The target comes from `--target=` only; the output name no longer decides.** A name
  ending in `.exe` used to select Windows on its own, so `wantzel x.wz backup.exe` handed
  back a Windows binary nobody asked for — a second way to choose the target, and an
  invisible one. A `.exe` name with no `--target` is now refused rather than quietly built
  for Linux. **Add `--target=windows` wherever you build an `.exe`.**
- **A dotted name part may start with a digit** (`Reading.level.1`). Only the first
  character of a whole identifier still has to be a letter or `_`. A schema enum whose
  value is `"1"` generates exactly that constant, and the compiler could not read its own
  generated source back: it failed with `<reading>:9: missing = in constant declaration`,
  naming a file the writer never wrote. Nothing that compiled before changes meaning;
  `3.5` still reads as one number.

### Compiler

- **Naming a DLL function the compiler already imports now documented as reuse.** Writing
  `winapi("kernel32.dll", "WriteFile", ...)` reuses the compiler's own import rather than
  adding a second one; a function it does not have gets its own entry, which is why an
  executable can carry two directory entries for the same DLL. `language.md` says why.

- **The fixed part of a runtime message is stored once instead of once per check.** Every
  bounds check, `chr()` range, division and missing return carries a message, and the whole
  sentence used to be stored per check — six distinct texts in 345 copies, differing only in
  the file name and the line number. In a GUI program that came to a quarter of the binary.
  The heading is now shared and the trap routine writes it before the place, so the message
  you see is unchanged. Measured: the compiler itself went from 554,041 to 534,169 bytes, and
  the calculator demos lost 9-10% each. It costs about 20 bytes of runtime, so a program with
  only a handful of checks comes out marginally larger.
- **Imports from two DLLs, interleaved, now get the right IAT slot.** The import address
  table is written grouped by DLL, while `winapi()` calls are read in source order — so the
  slot of an import depends on later calls that have not been parsed yet. Naming a user32
  function, then a gdi32 one, then user32 again gave the gdi32 import the slot of the null
  terminator between the two groups, and calling it jumped to address zero, far from the
  call responsible. The slot is now filled in once every import is known.

- **`undeclared identifier` now says which name.** When the name belongs to a library the
  message already named it and the include to add; when it belonged to none — a typo, or a
  routine defined further down the same file — it fell back to four bare words. Finding the
  offending identifier then meant rereading the routine. It is one line of output and it
  was measured costing three build rounds apiece.
- **A GUI needs the compiler on Windows and nothing at all on X11**, and that asymmetry is
  worth stating. X11 is a binary protocol over a Unix socket: `sysN` already reaches it, so
  drawing a window there needed no change to the language, the compiler or `lib/`. Windows
  needed two — reaching an API by name, and handing out a callback — because the operating
  system calls you rather than the other way round. Both sides are demonstrated by the same
  calculator in the demos repository.
- **`winproc(name)` gives a Windows API a callback it can call**, which is the one thing
  the language could not express: a window procedure, an enumerator, a hook or a comparator
  is invoked by Windows from its own code, so a compile-time link cannot serve.

  What it yields is not the routine's own address but a small adapter the compiler emits
  beside it. Windows passes arguments in `rcx, rdx, r8, r9` and this language expects them
  in `rdi, rsi, rdx, rcx`; the adapter moves them across, provides the 32 bytes of shadow
  space the platform requires of a caller, and preserves `rdi`, `rsi` and `rbx` — which are
  nonvolatile here and volatile on Linux, the one point where the two conventions disagree
  about who owns a register. Four arguments is not a limit that was chosen: it is what the
  convention passes in registers, and every callback in the Win32 surface fits it.

  Deliberately not `addr()` on any routine — that would be a function pointer in a language
  that does not have one. Windows targets only. It is the one thing the language could not express: a window
  procedure is called by Windows from its own code, so a compile-time link cannot serve.
  Deliberately not `addr()` on any routine — that would be a function pointer in a language
  that does not have one, and this opens the door exactly as wide as the need. Windows
  targets only; on Linux it does not compile.
- **`winapi()` takes a DLL and a function by name**, so reaching a Windows API is no longer
  a compiler change: `winapi("user32.dll", "MessageBoxA", 0, text, title, 0)` compiles and
  the name lands in the import table, whether or not the compiler has ever heard of it.
  Before this, every new function meant a line in the compiler, both counterparts updated
  and the bootstrap fixed point rebuilt. The numbered form stays and is unchanged — the
  generated runtime uses it throughout. An empty name, or a DLL name without its `.dll`,
  is refused while compiling; whether the DLL and the function actually exist is the
  target machine's answer, and [language.md](language.md) says at which moment each is
  found out.
- **`winapi()` refuses an import slot that does not exist.** A literal outside the import
  table used to compile, and the generated code then called whatever happened to sit at
  that offset — no message, no crash at a recognisable place, just wrong behaviour. It is
  now a compile error. (A non-literal slot still cannot be checked; every call in `lib/`
  writes a literal.)
- **`schar()` on a `str` that was never assigned now refuses instead of crashing.** It
  gives `runtime error: string index out of range` with the file and line, exit 1; before
  it died with a segmentation fault and no message at all. The bound lives in the eight
  bytes before the text, so comparing the index against it was itself a dereference — on a
  null address the comparison read address -8, and the process was gone before its own
  trap could fire. The guard was there and was correct; it was unreachable. Note the
  difference with `slen()`, which answers `0`: an empty string has length 0, but it has no
  character at position 0.
- **A generated `<Schema>.parse` refuses an unknown key instead of skipping it.**
  `parse` returns `-1` and `json.badkey0`/`json.badkey1` span the key it rejected. A
  caller that sent a renamed or removed field used to get a normal answer computed with
  the default in place of what it asked for — nothing refused, nothing warned. **This
  breaks a schema that does not declare everything it may receive**; for an open protocol
  envelope, declare those members as `json?`.

- **A missing `include` names the library.** `io.puts` without `include "io.wz"` reported
  only `undeclared identifier`, while the compiler was carrying the library that declares
  it; it now says which file declares the name and gives the line to add. A name no
  library declares still gets the plain message.
- **A name that collides only by capitalisation says so.** `STORE.SET` against an
  existing `store.set` reported `duplicate declaration`, which reads as though the name
  itself were taken; it now adds that names are case-insensitive and shows both spellings.
  A collision between two identical spellings is reported as before, without the
  explanation.
- **A `str` variable where an `array of char` is expected gets its own message.** It now
  says that only a string *literal* converts and gives the way out (`io.push` into a
  buffer, then the slice), instead of the generic `this parameter needs an array` — which
  gave no hint that a literal would have been accepted in the same position.
- **An undefined tool handler is reported at the writer's own `tools` entry.** The
  forward declarations come out of the generated `<tools>` text, so the message named a
  line of a file nobody can open (`<tools>:19`) — and gave a writer no way to tell which
  tool it meant.
- **The VS Code extension works from the Run menu**, and finds the compiler from a folder
  that contains a checkout rather than being one. Run Without Debugging compiles and runs
  the open file; there is still no debugger. The compiler is now looked for by walking up
  from the file, not only at the workspace root.

### Library

- **`lib/proc.wz` can start another program**: `proc.arg0`, `proc.arg` and `proc.exec`
  wrap `execve`, which was the missing half of `proc.fork`. The environment is empty on
  purpose, so a measurement or a test that uses it is repeatable.

### Documentation

- **`docs/syntax.md` is the whole syntax on one page**: the forty-three keywords, the shape
  of a program, the types, every statement form, the operators and the literals — with what is
  deliberately absent at the end. A script checks it against the compiler, because a reference
  page goes stale silently.
- **`docs/flags.md` covers the command line**, which is two arguments and one option, plus
  what there is deliberately no flag for: no optimisation level because there is no optimiser,
  no warnings because something is an error or it is fine, and no way to leave out the file
  and line of a runtime check because that is what an agent needs to fix its own mistake.
- **`docs/internals/` says how the compiler works inside**, and carries the measurements the
  design rests on: how one `io.write` becomes a raw `syscall` on Linux and a `WriteFile` call
  on Windows, what it takes to let Windows call a Wantzel routine, arrays and `view` and
  `mmap` without a heap, nine linked structures built without pointers, why a language
  written by a generator is stricter, compile time against binary size against run time, and
  what the system can already do with evidence per line.
- **`docs/howto/` is task-shaped**: building a window on Win32 or on X11 — the structure
  layouts you cannot guess, the wire protocol, and the failures that are silent on both —
  plus signing an executable so Windows trusts it, and doing work in a second process with
  `fork`.
- **`docs/design.md` links per claim to the document that carries the numbers**, so the
  argument stays readable and the evidence is one click away rather than paraphrased. Its
  own section on the optimiser, on pointers and on strictness now point at
  `internals/three-measures.md`, `internals/no-pointers.md` and `internals/why-strict.md`.
- **`docs/language.md` documents `winproc`** — the shape of the routine it takes, what it
  actually returns and why that is not your routine's address, and why an interactive
  Windows program cannot avoid a callback.
- **`docs/language.md` explains the import model**: what happens when you name a function
  the compiler already imports, why an executable can carry two directory entries for the
  same DLL, and why 48 imports are built in rather than data like everything else.
- **`docs/writing-wantzel.md` gains the argument order of the routines used most**, what
  each kind of routine returns when it fails, the buffer-and-its-length pattern, and two
  complete programs to copy: a command-line tool and an MCP server. Library use is the
  largest error category there is — 30 of the 100 recorded mistakes — and those four
  things are what it consists of. A test compiles and runs both programs.

### Tests

- **`no_python.sh` also refuses a file that IS Python**, not only one that mentions it.
  `tools/probe_http.py` never contained the word, so the one Python file in the
  repository was invisible to the test meant to prevent exactly that.

- **The Windows checks that need no emulator run in every `--toolchain` run.** Reading the
  PE header and comparing the `.exe` bytes of the two compilers cost milliseconds and sat
  behind Wine for no reason; that byte comparison is the check that caught `boot.c` and
  `wantzel.wz` drifting apart on the Windows side.
- **The VS Code extension does more than colour.** Compile errors reach the Problems
  panel through a contributed problem matcher, there is a build task to copy into
  `tasks.json`, and nine snippets for the shapes written most. Every snippet is compiled
  on each `--toolchain` run, and the matcher is checked against output the compiler
  really produced.
- **`tests/bench/startup.sh` measures how long a binary takes to start**, with the
  measuring loop in a Wantzel program rather than a shell — a shell loop times its own
  forking and drowns everything else.
- **`lib/openapi.wz` compiles on its own.** It used `oauth.issuer` without including
  `lib/oauth.wz`, and its three `app.*` callbacks were not named in the header, so a
  caller found out through messages pointing deep into the library. The header now says
  what it needs.
- **`lib/openapi.wz` has a test.** Nothing in this repository included it, so its only
  coverage lived in another project; it compares the generated document against a
  recorded one and checks its structure against the tool declarations.
- **`english_only.sh` also checks string literals that ship**, at one Dutch word rather
  than two. The tags above sat in `lib/` for weeks and the two-word threshold never saw
  them.
- **`--windows` is no longer walked around.** The release gate called the Windows script
  unconditionally, so Wine ran on every `--toolchain` run whatever the flag said, leaving
  orphan processes behind. Running a `.exe` now happens only when you ask for it, and that
  test fails if a wine process of its own survives its cleanup.

### Compiler

- **`slen()` on a `str` that was never assigned returns 0 instead of crashing.** Variables
  are zeroed, so such a string is (address 0, length 0) — but `slen` read the eight bytes
  *before* the address and dereferenced address -8. The process died with a segmentation
  fault and no message, which in a language that checks every array index was the one
  hole.

### Library

- **A minimal MCP server answers instead of dying.** `mcp.name` and `mcp.version` are
  globals the application may set; one that did not crashed on its first request. They
  now default to `wantzel-mcp` and `0`, and an application that sets them still wins.
- **`store` refuses a log record that does not fit the declared record size instead of
  skipping it.** Replay stops there, `store.opendir` returns `false`, and `store.err`
  plus `store.det[0..store.detn - 1]` name the table and both sizes. Before this, such a
  record was dropped without a word and the log was reported as fully applied, so every
  change to a record layout lost data silently.
- **`store.apply` is a function returning `bool`** (it was a procedure): `false` means
  nothing was applied.
- **`store.close` is valid after a failed `store.opendir`.** It releases the mapped
  tables and clears the declarations, so a caller can react to a refusal and open again.
- **`kv.isobject`, `kv.count` and `kv.match` no longer move the cursor `kv.vat`/`kv.vend`.**
  They answer a question and restore it, the early returns included. A `kv.find` followed
  by one of them used to leave the caller reading a different value, with no error.
- **New `kv.text(b, dst, at)`: the decoded text of the value the cursor stands on.**
  It returns `-1` when the value is not a JSON string or does not fit, and never falls
  back to the raw bytes. Reading `kv.vat`/`kv.vend` directly hands you the value as
  written — quotes and escapes included — which compared unequal to the same word
  without them, silently.
- **`mcp` and `oauth` declare the protocol members they receive.** `Init` now declares
  `capabilities` and `clientInfo`, `Call` declares `_meta`, and `ORegister` declares the
  RFC 7591 metadata fields. Without them the stricter parse above refused every genuine
  MCP handshake, after which the client's protocol version was ignored and the server
  answered with the oldest one it supports.
- **The OpenAPI tags are English.** Every operation in the generated document was tagged
  `lezen` or `schrijven` — Dutch, on a page an API user opens. They are `read` and
  `write` now.
- **A request header name is now case-insensitive on both sides.** `http.header("Accept")`
  matched nothing and answered `false`, so a caller concluded the header was absent;
  only an all-lower-case name worked. Both spellings now give the same answer.

---

## 0.2.0 — 15 September 2026

One language change, and it breaks existing sources: `{ }` is no longer a comment.

### Language

- **The `{ }` block comment is gone; `//` is the only comment form.** It ended at the
  *first* `}`, so a brace in the comment text turned the rest of the sentence into code —
  six of seven recorded syntax errors. A `{` outside a string is now refused, with a
  message naming the replacement; write a multi-line comment as several `//` lines.

### Compiler

- **Compile time no longer grows faster than the source does.** Name lookup walked the whole
  list; it now goes through a hash index. 16,384 globals: 1,296 ms → 16 ms. Growth is linear.
- **Recognising a keyword no longer compares against all 43 of them.** Dispatch on the first
  character first. The compiler compiling itself: 12.8 ms → 10.3 ms, about 590,000 lines/s.
- The compile-speed floor in `tests/bench/` is raised to 400,000 lines/s, and a new bench
  guards the *shape* of the growth rather than only the speed.

---

## 0.1.2 — 14 September 2026

One theme: **a failure that could still pass quietly no longer can.**

### Language

- `net.watch` and `net.nonblock` are now functions, not procedures — a call that ignored the
  result no longer compiles.
- `kv.match` answers differently for a stored list: a filter list now means containment.

### Compiler

- A generated `<Schema>.write` refuses a buffer it does not fit in, instead of writing past
  the end of it.
- A required schema field given as JSON `null` is rejected.
- A source that fills the data segment gets a compile error, not a crash.
- The capacity limits are four times larger.

### Library

- `io.now` and `io.realtime` stop the program when the clock cannot be read.
- `net.watch` and `net.nonblock` return a `bool` instead of the raw syscall result.
- `kv.match` does containment when the stored value is a list.
- `json.putraw`, `json.putstr`, `json.escslice`, `io.push`, `io.pushnum` and `json.putreal`
  no longer write past the end of their buffer.
- A negative position travels through the appenders unchanged instead of being treated as 0.
- New: `json.putb(dst, at, c)` — writes one byte of JSON structure.
- The standard library travels inside the compiler, so a downloaded binary resolves
  `include "io.wz"` without `lib/` beside it.

### Tooling

- The Windows tests sit behind `./wztest --windows`, which halves an ordinary run.
- `test-win.sh` no longer fails on its own cleanup.
- `./build.sh` installs every file by renaming it into place.
- A `.wz` test runs in its own temporary directory.

---

## 0.1.0 — 13 September 2026

First public release.

### Compiler

- An unresolved forward declaration names the routine, and every one is reported.

### Library

- The session cookie is called `session`.
- The login, failure and logout pages are in English.

---

## How to add an entry

One bullet, one or two lines: what changed, and what it means for someone using it. The
reasoning belongs in the ticket, not here — a changelog is scanned by someone deciding
whether to act, not read as justification. Put it under Language, Compiler or Library, in
the same commit as the change.
