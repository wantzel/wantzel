# Changelog

What changed, for someone who uses Wantzel. Three kinds of change, because they ask
different things of you:

| | what it affects | what it means for you |
|---|---|---|
| **Language** | anyone who **wrote** Wantzel code | a program that compiled yesterday may not today, or may mean something else |
| **Compiler** | anyone who **compiles** | the same program, the same meaning — but different messages, different code, different limits |
| **Library** | anyone who **includes** `lib/` | a routine, its behaviour or text it emits changed; your own code may need to follow |

The language has been **frozen since 10 September 2026**. A language entry is therefore
rare and always deliberate; see [`language.md`](language.md) §9, which is binding.

Newest first. Dates are the day the change landed.

---

## Unreleased

### Compiler

- **The standard library travels inside the compiler.** A binary that was downloaded
  rather than built had no `lib/` beside it, so `include "io.wz"` failed with
  `cannot open the included file` — which made the release useless for almost any real
  program, since nearly all of them start with an include. The sources are now carried in
  the binary and used when the file is not found on disk.

  **A file on disk still wins.** If you have the repository checked out, editing
  `lib/io.wz` has the effect you expect, with no rebuild needed; the embedded copy only
  answers when there is nothing to read. An include naming a path (`include "sub/x.wz"`)
  is unchanged and always comes from disk.

  The compiler is about 500 kB instead of 274 kB as a result. *13-09-2026, W-0000-0042.*

## 0.1.0 — 13 September 2026

The first public release. Everything below landed before it; the entries are kept
because they say what changed and why, and the reasoning outlives the version it
arrived in.

**What 0.1.0 is.** A self-hosting compiler that produces static Linux ELF and 64-bit
Windows PE32+ from the same source, with no assembler, no linker, no C library and no
external tool. You need a C compiler once, for `bootstrap/boot.c`. Anything may change
before 1.0 — the language, the library, the command-line interface.

### Compiler

- **An unresolved forward declaration now names the routine, and every one is reported.**
  Previously the compiler said only `forward declared routine is never defined`, once, so
  with several undefined routines you fixed them one compile at a time and had to work out
  which they were. Now each is named at the file and line of its own declaration:

  ```
  wantzel: lib/http.wz:51: forward declared routine app.request is never defined
  wantzel: lib/oauth.wz:92: forward declared routine app.authenticate is never defined
  ```

  The reported line also moved: it used to point one line past the declaration.
  *13-09-2026, W-0000-0011.*

### Library

- **The session cookie is now called `session`.** It used to carry a working name from
  before this compiler stood on its own, which meant nothing to anyone else. If you read
  the cookie by name in your own code, update it. *13-09-2026, W-0000-0003.*
- **The login, failure and logout pages are in English**, as is the description and the
  400/401/422 responses of the generated OpenAPI document. Anyone building a server with
  `lib/oauth.wz` shipped Dutch text to their users before this. If you asserted on the old
  wording, update it. *13-09-2026, W-0000-0004.*

---

## How to add an entry

In the same commit as the change, not afterwards. Say which of the three kinds it is, what
a user has to do about it, and give the date and the ticket. Write for someone who does
not know this repository: name the routine, show the message, say what breaks.

A change to `src/wantzel.wz` and `bootstrap/boot.c` that only moves comments is not a
change to the compiler and needs no entry. The test is whether anyone outside could
notice.
