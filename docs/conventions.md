# Conventions

**Agreements that give direction without being compiler rules.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

Nothing here is enforced by the compiler; a program that ignores all of it is still a
correct Wantzel program. For what the language *means*, see [language.md](language.md),
which is binding. For how it's *written*, see [syntax.md](syntax.md). For how to write it
*well*, see [writing-wantzel.md](writing-wantzel.md). This file is the softest of the four,
on purpose.

## How a convention arrives, and how it leaves

```
an idea  ->  a convention  ->  used in practice  ->  measured  ->  maybe the language
```

A convention is a proposal that has been written down and is being tried. It earns its
place by being followed, and keeps its place by staying useful.

**Promotion.** A convention followed long enough that departing from it is surprising, with
a count behind it, is a candidate for [language.md](language.md) or the compiler — the
same evidence bar any language change needs; popularity alone isn't it.

**Removal.** A convention nobody follows gets deleted, not left standing. If it has drifted
from what the code does, the code wins: describe reality or change it, but don't let the two
disagree in silence.

## 1. The entry point of an application is `main.wz`

**A program made of several files names its entry point `main.wz`.**

Nothing else marks which file is the program: a `.wz` file is a program when it has a
top-level `begin ... end.`, and that difference appears nowhere in the name. An editor that
compiles the file you have open guesses wrong constantly — in one measured application, 21
of 22 source files were not the entry point, so `F9` on the wrong one answers:

```
wantzel: src/theme.wz:1: missing begin of the main program
```

**The rule, in three parts:**

1. An application of several files names its entry point `main.wz`.
2. A single-file program is named after itself: `hello.wz`, `cat.wz`, `httpd.wz` — a
   directory of eleven examples all called `main.wz` would be unusable, which is why this is
   a convention and not a compiler rule.
3. Several programs in one project each get their own directory with a `main.wz` in it.

Every multi-file application measured already follows it, with one exception:
**`wantzel/src/wantzel.wz`**, the compiler's own source. It has a counterpart in
`bootstrap/boot.c` that must stay in step with it line for line, and is named throughout
scripts and docs — renaming it is risk with no return, so it stays. New applications follow
the rule; existing ones are left alone.

**Not a compiler requirement**: `wantzel anything.wz out` works regardless, and the compiler
never searches for a `main.wz` on your behalf — that would guess wrong the moment a
directory holds two programs.

## 2. A module prefixes its names

**Names that belong to one file share a prefix: `tree.paint`, `doc.save`, `run.go`.**

The language has no namespaces and `include` is textual — everything lands in one flat
scope. The prefix *is* the namespace: it says where a name comes from, keeps two modules
from colliding, and makes a name greppable to exactly one file. Already universal in `lib/`
(`json.parse`, `io.puts`, `http.get`) and in every application of size.

The prefix matches the file: `tree.wz` defines `tree.*`. Where a file is one obvious noun,
the short form is fine — `doc.wz` defines `doc.*`, not `document.*`.

## 3. Constants are `SCREAMING_CASE`

**A compile-time constant is written in capitals with underscores: `DOCMAX`,
`FILE_SHARE_READ`, `TH_KEYWORD`.**

Case doesn't distinguish names in Wantzel, so this carries no meaning to the compiler — it's
for the reader, reliable enough that a tool can act on it: an editor can colour an
all-capitals name without a symbol table and be right essentially always. That's the test
for a convention worth keeping.

## 4. `agent-permissions:` says what a file is for

**A comment in the first lines of a file says how it's meant to be treated:**

```wantzel
// agent-permissions: read
```

```sh
# agent-permissions: none
```

```html
<!-- agent-permissions: read -->
```

Three values, and no others:

| value | meaning |
|---|---|
| `read` | read it, do not change it |
| `none` | do not open it at all |
| *(absent)* | ordinary: read and write |

**There is no `write` and no `delete`.** Writing is the default, so a marker for it would say
nothing; whoever may write may in practice also replace a file with an empty one, so
`delete` would promise a distinction that doesn't exist.

**It's a hint, not a guard** — nothing enforces it, exactly as nothing enforces `.gitignore`
or an SPDX line. Those are followed because they're unambiguous and cost nothing to read; an
*enforced* permission would need a mechanism, storage and an override path.

**Why a comment and not a filename rule.** The one thing that can't be inferred from a file
is intent — reference material, a scratch file, or generated output never to hand-edit. A
comment says it where a reader is already looking, at no runtime cost.

**Where it's binding: the first 512 bytes, and nowhere else.** A marker halfway down a file
is one you can hide, and it would allow two contradictory markers in one file. Reading only
the head is also cheap enough to do for every file in a directory listing.

**What precedes the marker doesn't matter** — `// `, `# ` and `<!-- ` all lead to the same
three words, which is what makes it work across languages without a comment parser per
language.

**An unknown value reads as ordinary.** A misspelling restricts nothing rather than
restricting everything — it should never be possible to lock a file by typing it wrong.

**Where it earns its place:** generated files first (a file a tool rewrites should say so,
since a hand edit is lost on the next run), then reference material meant to be read rather
than adapted. Not yet settled: whether the same vocabulary belongs on tickets, and whether a
generator should emit the marker itself.

## 5. An error names the fact first and the repair after a dash

**The shape is fixed, so the reader always knows which half is which:**

```
wantzel: t.wz:6: undeclared identifier: prnit -- did you mean print?
wantzel: t.wz:9: winapi(): a DLL name ends in .dll, for example "user32.dll"
wantzel: t.wz:3: { } is not a comment; use // to the end of the line
```

**Before the dash: what's wrong, as a fact. After it: what to do, when the compiler can work
that out.** The reader needs to know `prnit` doesn't exist first; the nearest name is help,
not the finding.

**A repair is offered only when it can be derived, never guessed.** `"user32"` plus `.dll` is
derived; "check your spelling" is not — a wrong suggestion costs more than none, because the
reader stops trusting the next one.

| level | what it adds | when |
|---|---|---|
| the fact | file, line, what is wrong | always |
| the parameter | *which* argument, when a call has several | when the message alone is ambiguous |
| the repair | `-- did you mean X?`, `; use Y`, `, for example "Z"` | only when derivable |

Most messages need only the fact — `identifier too long` is complete as it stands, padding
it is noise. The parameter earns its place where a call has several arguments: `winapi()`
takes six, so "the DLL name is empty" beats "an argument is empty".

This is a convention and not a rule because the compiler can't check it; the rest is
judgement.

## 6. Keep the levels apart: a helper file carries the vocabulary

**Code that reads like pseudocode is a consequence of putting the words in one file and the
decisions in another**, not a style choice. Before, a routine that opens a file for reading:

```wantzel
fd := sys3(SYS.open, addr(path[0]), O_RDONLY, 0);
if fd < 0 then begin io.puts(STDERR, "cannot open that file\n"); return false; end;
base := sys6(SYS.mmap, 0, size, PROT_READ, MAP_SHARED, fd, 0);
sys1(SYS.close, fd);
if base < 0 then begin io.puts(STDERR, "cannot map that file\n"); return false; end;
```

This *says* "syscall 2, syscall 9, syscall 3"; it *means* "map this file". After:

```wantzel
base := fs.map(addr(path[0]));
if base < 0 then begin io.puts(STDERR, "cannot map that file\n"); return false; end;
```

Not shorter for its own sake: the `close` now lives in one place, including the part every
caller gets wrong (a mapping keeps its own reference, so the descriptor is done the moment
`mmap` returns — a caller who doesn't know that leaks one per file).

**The test for a mixed level:** read one routine and ask what it's about. If the answer
needs two sentences — "it maps a file, and also mmap takes six arguments in this order" —
the levels are mixed. A routine that mentions a syscall number is at the bottom level, and
almost nothing else should be.

**Where the vocabulary goes:** a file of its own, named after what it's about. `fs.wz` is
about files; `fs.map`, `fs.open`, `fs.stat` are the words it contributes. The caller includes
it and never reaches past it to a syscall. Same technique as §1, from the other side: that
section says where files go, this one says why the result reads better.

**Not a wrapper for everything.** A routine that only renames a syscall (`fs.read` calling
`sys3(SYS.read, ...)` with the same arguments) adds a name and no meaning. The ones worth
having combine steps (`fs.map` is a stat, an open, an mmap and a close) or remove a decision
the caller shouldn't have to make — and don't hide what they cost: `fs.map` maps a whole
file, and a caller mapping a gigabyte should see that from the name.

## Candidates, not yet conventions

Written down so they aren't lost, marked clearly so nobody mistakes them for settled.

- **Where tests live and what they're called.** Each repository decides for itself; worth an
  agreement once there are more repositories than the ones here.
- **How an application lays out its directories.** `src/`, `docs/`, `bin/` is what
  everything does — not the same as having been agreed.

Add to this list freely: the cost of a bad candidate is one paragraph, a bad language rule
is everything downstream of it.
