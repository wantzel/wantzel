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
