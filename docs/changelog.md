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

## 0.1.2 — 14 September 2026

One theme runs through this release: **a failure that could still pass quietly no longer
can.** Nothing here adds a feature. Every change takes a case where the compiler or the
library carried on with a wrong assumption and turns it into either a refusal or a stop.

Several of them were the same shape -- a write that ran past the end of a buffer, a
syscall whose result was thrown away, a required field satisfied by JSON null -- and in
each case the old behaviour produced a result that *looked* complete. That is the failure
mode this language is least able to afford, because the first reader of a result is
usually a machine, and a machine cannot tell a short answer from a whole one.

Two changes affect code that compiles today:

- **`net.watch` and `net.nonblock` are now functions, not procedures.** A call that
  ignores the result no longer compiles, deliberately. Where the discard is intended,
  write it down (`http.ignored := net.watch(...)`).
- **`kv.match` answers differently for a stored list.** A filter list against a stored
  list was false and is now true; the wrapped form that used to compensate for that
  (`{"c":[[1,2]]}` against stored `[1,2]`) is now false. Both directions are in the entry.

The capacity limits also went up fourfold, and a source that exceeds them now gets a
compile error naming the source rather than a crash naming the compiler.

This release carries the changes tagged as 0.1.1, which was published without a section of
its own; the entries below are dated individually.


### Compiler

- **A generated `<Schema>.write` refuses a buffer it does not fit in, instead of writing
  past the end of it.** The writer stored the structural bytes of the object (`{`, `}`,
  `[`, `]`, `,`, `"`) with a bare `dst[at] := c` and never consulted `len(dst)`, so a
  destination one byte too small was not a rejected call but a runtime
  `array index out of range` — the process stopped. That lands on the path that builds a
  protocol reply, so what died was a whole server rather than the one call that
  overflowed.

  It now returns `-1` when the object does not fit, when the starting position is
  negative, or when it is already at or past the end of `dst`:

  ```pascal
  n := Reply.write(out, 0, r, src);
  if n < 0 then ...                    // the result did not fit; out holds nothing usable
  ```

  **A short buffer is a refusal here and not a truncation, unlike `io.push`**, and the difference is the point rather than an inconsistency: a
  truncated message is still a message, but a truncated JSON object is not a shorter
  object — it is a syntax error. This text goes out as the `structuredContent` of an MCP
  or REST reply, so truncating would hand the peer an envelope it cannot parse at all,
  turning one failed call into a broken session. The appenders still truncate; the
  writer now tests for it and turns it into a refusal.

  `tool.run` therefore has a third negative result, **`-3`, for "the result does not fit
  in `dst`"**, kept apart from `-1` because `-1` means the caller's arguments were wrong
  and this limit is on our side. `lib/tools.wz` reports it as an MCP error and as HTTP
  500. Both transports already tested the result, so no call site had to change.

  A `real` field is guarded before the call rather than after: `json.putreal` needs 32
  bytes of headroom and without it writes *nothing*, leaving a key with no value —
  invalid JSON that a check on the position afterwards cannot detect, because the
  position never moved.

  **A companion `<Schema>.writelen` was considered and not added.** It would let a caller
  size a buffer beforehand, but every destination here is a fixed compile-time array —
  there is no allocation in the language — so it could only inform a decision that
  cannot be acted upon, at the cost of a second full traversal generated per schema.
  *14-09-2026, W-0000-0078.*

- **The capacity limits are four times larger.** A program that fills the data segment
  stops compiling entirely, and getting back under the ceiling means splitting or
  shrinking whatever happens to be largest -- so the ceiling is worth raising before it
  is reached, not after.

  | limit | was | now |
  |---|---|---|
  | source in total (`SRCMAX`) | 16 MB | 64 MB |
  | machine code (`CODEMAX`) | 16 MB | 64 MB |
  | data: literals, JSON schemas, tool list (`DATMAX`) | 8 MB | 32 MB |
  | name pool (`NAMEMAX`) | 2 MB | 8 MB |
  | source file names together (`FNPMAX`) | 131000 | 524000 |
  | JSON Schema text per schema, and the tool list (`JSMAX`) | 1 MB | 4 MB |

  They are raised together and by the same factor: a source large enough to fill one of
  these is usually close to the next, and raising one at a time only moves the stop.

  **This costs nothing to compile with.** These buffers are static (bss), so they are
  paid for as they are touched, not as they are declared: the compiler binary is
  498738 bytes before and after, and compiling the compiler's own source peaks at
  1920 KB of resident memory before and after. Only a program that actually uses the
  extra room pays for it.

  **`TBMAX` is deliberately unchanged**, so an identifier and a string literal are still
  bounded at 4095 bytes. That one is visible in the language rather than a matter of
  capacity, and a longer identifier is not an improvement.

  Going over a limit is still a compile error naming the source file and line, not a
  crash.

- **A required schema field given as JSON null is now rejected.** `Name.parse` accepted
  `{"jsonrpc":null}` for a field declared without `?`, because the generated
  required-field check tested only `f_ok` — which means "the key was present", not "a
  value was given". A document that omits the key was refused while the same document
  writing `null` was accepted, and for an enum field the result was `-1`, indistinguishable
  from an unknown enum value.

  ```pascal
  schema Msg = record
    jsonrpc: text;                 // required
    id:      int?;                 // optional
  end;
  ```

  `{"jsonrpc":null,...}` now makes `parse` return `-1`, as `language.md` §7 always said:
  a missing required field gives `-1`, and `null` is not a value.

  **Optional fields are unchanged.** `null` on a field with `?` still parses and still
  sets both `f_ok` and `f_null`, so the `f_ok and not f_null` idiom keeps working. If you
  relied on `null` passing for a required field, declare that field optional with `?` and
  test `f_null` yourself. *14-09-2026, W-0000-0046.*

- **A source that fills the data segment now gets a compile error, not a crash.** Every
  capacity check inside the compiler tested the bound *after* storing the byte, so the
  byte that did not fit had already been written and the compiler stopped on its own
  array bounds check: `runtime error: array index out of range at src/wantzel.wz:495`.
  That names the compiler where it should name the input, and it sends you looking for a
  mistake in your own code that is not there.

  The room is now checked before the write, everywhere a length counter is raised: the
  data segment (string literals, JSON schemas, the tool list, the Windows import tables),
  the name pool, the generated source of a `schema` or `tools` block, the source buffer
  while a file is read, and the pool of source file names. The messages say what is full
  and that the source is too large — `data segment overflow: the source is too large`,
  `name pool overflow: the source is too large`. The limits themselves are unchanged;
  `tests/limits/limits.sh` now proves this one with a source that just fits and one that
  just does not. *14-09-2026, W-0000-0045.*

### Library

- **`io.now` and `io.realtime` stop the program when the clock cannot be read, instead of
  returning a wrong time.** *Behaviour change.* Both routines asked the kernel for a
  timespec with `sys2(SYS.clock, id, addr(io.ts[0]))` and then decoded `io.ts` without
  looking at the result. A failed `clock_gettime` does two things at once, and together
  they are worse than either alone: it returns a negative `-errno` (an invalid clock id
  gives `-22`, `-EINVAL`) **and it leaves the timespec untouched**. Because the buffer is
  never written, the decode still succeeds — it just decodes whatever `io.ts` held before:
  the previous reading, or a zero timestamp on the first call, which as a date is
  1 January 1970. Nothing in the returned value says it is not a time.

  Both now check the result and call `io.fatal`:

  ```
  io.now: the monotonic clock is unavailable (clock_gettime failed)
  io.realtime: the system clock is unavailable (clock_gettime failed)
  ```

  **Stopping is the right answer here, and the reason is `io.realtime` specifically.** It
  is what `time.nowsec` returns seconds from, and it is the timestamp in the JSON line of
  both `lib/log.wz` and the request log of `lib/http.wz` — so its result becomes a date,
  and a date gets stored. A wrong time that is *acted on* is bad but bounded; a wrong date
  that is *written down* is afterwards indistinguishable from a real one, and no later
  check can recover which records are wrong. Carrying on is therefore worse than
  stopping, which is the opposite of the usual rule for a failed syscall (a missing file
  is an expected outcome and `fs.open` still returns `-2` for the caller to test).

  **What this means for you:** a program that reads the clock can now halt with exit
  status 1 where it previously returned a nonsense timestamp. In practice the guard is
  unreachable on Linux — `CLOCK_MONOTONIC` and `CLOCK_REALTIME` are always available —
  so this changes the behaviour of no working program; it removes a silent failure mode.

  **The two platforms genuinely differ, and the check is written for both.** On Windows
  there is no `clock_gettime`: the compiler serves syscall 228 from
  `GetSystemTimeAsFileTime`, which returns `void` and has no failure mode, so `__wsys`
  reports `0` for every clock id and the guard is correct but never taken. The check tests
  the return value rather than inspecting the buffer, which is why one line is right on
  both targets.

  The trap is now also written into both docstrings — that a failed clock returns `-22`
  and leaves the buffer untouched — so the next reader of these routines does not have to
  rediscover it. *14-09-2026, W-0000-0027.*

- **`net.watch` and `net.nonblock` return a `bool` instead of throwing the syscall result
  away.** *Behaviour change: both were `procedure`, they are now `function`.* An
  `epoll_ctl` or `fcntl` that fails does not stop the program — it returns a negative
  errno and execution carries on with a wrong assumption, which is the one failure shape
  that still passed quietly. Measured: `epoll_ctl` gives `-9` (EBADF) on an unopened fd
  and `-2` (ENOENT) on an fd that is not in the set; `fcntl(F_SETFL)` gives `-9` on a
  closed fd. Neither produced a diagnostic.

  What a failure *means* depends on the operation, so the call sites differ rather than
  all trapping:

  | | what a failure costs | what happens now |
  |---|---|---|
  | `EPOLL_ADD` on the listening socket | the server accepts nothing, ever, and sits silently in `epoll_wait` | `io.fatal`, as for `net.listen` and `net.epoll` |
  | `EPOLL_ADD` on an accepted connection | that client is never served and the fd leaks | the connection is dropped |
  | `EPOLL_MOD` | the fd keeps its **old** event mask, so the loop waits for the wrong readiness — a stall, not an error | the connection is dropped |
  | `EPOLL_DEL` in `http.drop` | nothing: ENOENT only says the fd is already out of the set, which is what the caller wanted | deliberately ignored, and written down as such |

  `net.listen` reports a failed `O_NONBLOCK` as a negative errno with the socket closed,
  following the contract it already had for `bind` and `listen` — no fourth failure form.
  A blocking socket in an epoll loop lets one slow client stop the whole server.

  Because the language refuses a discarded function result, the one intentional discard
  has to be spelled out (`http.ignored := net.watch(...)`) instead of left to the reader.

  **The two clock sites in `lib/io.wz` were treated separately**, because a failure there
  means something else: the entry below covers them. Origin: W-0000-0027.

- **`kv.match` now does containment when the stored value is a list, so a stored list
  contains itself.** *Behaviour change.* Previously the routine decided on the filter side
  only: every array-valued filter entry went to `kv.anyof`, which asks whether the stored
  value equals one of the elements. A stored list could therefore never contain anything —
  not even itself. `{"tags":["a","b"]}` did not match a stored `["a","b"]`, and
  `{"tags":"a"}` did not match it either. The docstring called it a subset match, which
  made the wrong answer easy to believe.

  There are now two branches per filter key, chosen by the **stored** side:

  | stored value | filter value | rule |
  |---|---|---|
  | not a list | a list | membership, as before: the stored value equals one of the elements |
  | a list | anything | containment: the stored list holds the filter value, or all of a filter list's elements |
  | not a list | not a list | equality (`kv.same`), unchanged |

  **What you have to do:** if you were relying on a stored list being compared as a whole,
  that shape has changed meaning. `{"c":[1,2]}` against a stored `[1,2]` was `false` and is
  now `true`; the workaround of wrapping the list one level deeper, `{"c":[[1,2]]}`, was
  `true` and is now `false` — a stored `[1,2]` does not hold `[1,2]` as an *element*.
  Filters whose values are scalars, objects, or lists matched against a stored scalar are
  unaffected.

  The two empty-list cases now pull apart, deliberately: an empty filter list against a
  non-list stored value still matches nothing (there is nothing to be a member of), while
  an empty filter list against a stored list matches everything, because containment of
  nothing is vacuously true.

  Two routines came out of it and are public in their own right: `kv.contains(stored, ..,
  filter, ..)` for the containment test on a stored array, and `kv.haselem(array, ..,
  value, ..)` for plain element membership — `kv.anyof` with the two sides swapped.
  `kv.isarray` tells the branches apart. Neither moves the `kv.k*`/`kv.v*` cursor.
  (W-0000-0047, 14 September 2026)
- **`json.putraw`, `json.putstr` and `json.escslice` no longer write past the end of
  their buffer either.** The three that the previous pass missed. All take an `array of char`
  and so have `len(dst)` available; none consulted it, so one byte too far was a runtime
  `array index out of range` and the program stopped. `json.putraw` is the worst of the
  three because it is reached from a generated writer and from
  `lib/oauth.wz`, which builds a `WWW-Authenticate` header out of an incoming request
  path — so the length came from outside.

  **They truncate at `len(dst)`**, the same contract as `io.push` and for the same
  reason: every caller here chains the result straight back in as the next position
  (`lib/log.wz`, `lib/mcp.wz`, `lib/router.wz`, `lib/oauth.wz`) without testing it, so a
  `-1` would become the next write index. A caller that must know whether everything fit
  compares the position that comes back with the one it passed in, or checks the room up
  front as `kv.put` does. Note that truncated `json.putstr` output loses its closing
  quote, so a caller building JSON must do one of those two things.

- **A negative position now travels through the appenders unchanged.** `io.push`,
  `io.pushnum`, `json.putraw`, `json.putstr`, `json.escslice`, `json.putreal` and
  `json.putslice` return a negative `at` as they received it rather than indexing
  `b[-1]`. That is what lets a `-1` from a refusing routine cross a chain of appends and
  be tested once at the end, instead of every step having to test it.

- **New: `json.putb(dst, at, c)`** writes one byte of JSON structure and returns
  `at + 1`, or `-1` when there is no room (and `-1` straight through when `at` is already
  negative). It is the refusing counterpart of the truncating appenders, and it is what
  a generated `<Schema>.write` uses for the bytes that must not be dropped.
  *14-09-2026, W-0000-0078.*

- **`io.push`, `io.pushnum` and `json.putreal` no longer write past the end of their
  buffer.** All three take an `array of char` and so have `len(b)` available, but none of
  them consulted it: `io.push` copied until the literal ran out. One byte too far is a
  runtime `array index out of range at lib/io.wz:157` and the program stops.

  This reached further than the three routines, because `tool.fail` is generated by the
  compiler: a `tools` block emits `tool.errn := io.push(tool.err, 0, s)` into a fixed
  `array[0..255]`. Every program with such a block inherited the limit whether or not its
  author knew of it, and the failure landed on an error path — so a server started,
  served traffic, and died only on the call that built the long message.

  **They truncate; they do not return -1.** The position that comes back never exceeds
  `len(b)`, so the usual chain keeps working:

  ```pascal
  n := io.push(buf, 0, "a long literal");
  n := io.push(buf, n, " and another");     // n is still a usable position
  ```

  Truncation was chosen over signalling because every call site feeds the result straight
  back in as the next position without testing it; a `-1` would become the next write
  index. `json.putslice` does return `-1`, and it is called in the places that check for
  it. If you need to know that something was dropped, compare the returned position with
  the one you passed in.

  `json.putreal` needs room for its longest form (22 characters measured across the whole
  representable range; the bound is 32). Without that room it writes nothing and returns
  `at` unchanged. *14-09-2026, W-0000-0048.*
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

### Tooling

- **The Windows tests now sit behind `./wztest --windows`, which halves an ordinary run.**
  They needed Wine and ran on every `--toolchain` invocation, where they were 19 of the 40
  seconds measured -- Wine even starts a server of its own. Everything the language does
  is checked natively; Wine answers two narrower questions, whether the compiler still
  cross-compiles to a working `.exe` and whether both backends reach the same fixed point,
  and neither can regress from an ordinary change to `lib/` or to a test.

  So `--toolchain` alone is now 16 seconds instead of 32, and says which tests it left
  out. Use `--windows` when you touch the Windows side of the runtime, a syscall shim or
  the code generator. A release always runs them: `release.py` passes the flag, because a
  release publishes an `.exe`. *14-09-2026.*

- **`test-win.sh` no longer fails on its own cleanup.** The `WINEPREFIX` lives in the
  test's temporary directory, and `wineserver` keeps files open there for seconds after
  the last call -- the httpd check even starts a server under Wine. The closing `rm -rf`
  then reported `cannot remove '.../wp': Directory not empty`, and because the script runs
  under `set -e` that one failed `rm` turned the whole run red, directly after
  `18 passed, 0 failed`. A test that reports its own success and then trips over its
  cleanup is close to unreadable as a failure -- and it took `freeze.sh` with it, which
  calls this script.

  Cleanup now shuts `wineserver` down first and waits for it to go, and the `rm` can no
  longer decide the outcome: that is already fixed in the count. The shutdown touches only
  its own prefix, because `wineserver -k` acts on the prefix in the environment -- a broad
  kill would hit the Wine of a parallel suite. Measured: five consecutive runs of
  `18 passed, 0 failed` with no `rm` error. *14-09-2026.*

- **`./build.sh` installs every file by renaming it into place, so a build no longer
  breaks a suite that is running.** `cc -o bin/wantzel0` truncates its target before it
  writes, and the generator wrote `src/embedded.wz` in place, so anything reading those
  during a build could see a partial file. Measured on the old script: running
  `./bin/wantzel0` in a loop while one build ran gave 2 failures in 176 attempts, with
  `Permission denied` rather than anything naming a cause. Both are now written under a
  `.new` name and renamed, which is atomic within a filesystem: a reader sees the old
  file or the new one.

  This is reachable from an ordinary run, not just from two terminals: the suite's own
  `tests/toolchain/freeze.sh` calls `./build.sh`, while `test.sh`, `test-win.sh` and
  `embedded_lib_current.sh` read `bin/wantzel0` and `src/embedded.wz`. A half-written
  `src/embedded.wz` also fails `tests/compiler/schema.wz`, and neither failure names
  `lib/` or `embedded.wz`.

- **A `.wz` test now runs in its own temporary directory.** It is still *compiled* in its
  source directory, because a compile error has to name the bare file (`rt_div_zero.wz:3`,
  not the path the suite was started from), but the compiled program is run somewhere
  private. A test that creates a scratch file used to put it in `tests/<dir>/` under a
  fixed name, where a second run of the suite wrote exactly the same name.

  That was not hypothetical. `tests/lang/memory_patterns.wz` shares `mp_items.tmp`, and
  two runs mapped the same file and each applied the other's increment
  (`key of item 3 in file = 204` instead of `104`); `tests/compiler/syscalls_storage.wz`
  shares `sc_test1.tmp`, and one run renamed the file away between another's open and
  reopen, so every following call returned `-EBADF` (`append -9`). Both passed alone and
  failed in a full run, which is the hardest kind of failure to read — and the reason
  `tests/lib/store.wz` already carried the process id in its directory name by hand.

  Measured with four suites running at once, 24 runs each time: 18 failures before, 0
  after. *14-09-2026, W-0000-0044.*

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
