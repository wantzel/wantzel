# Writing Wantzel

What goes wrong when writing Wantzel, and the idioms that avoid it. Nearly every mistake
comes from one of four places: Pascal or C habits the language does not have, the shared
case-insensitive namespace, a wrong assumption about a library routine, or a test
expectation that was never checked.

The specification is
[language.md](language.md); where the two differ, the specification wins and the difference
is a finding.

---

# Pitfalls

Every entry: **wrong** → **right**, with the compiler message that identifies it.
Found a new pitfall? Add it under the heading it belongs to.

## Namespace (one shared, case-insensitive namespace)

- A constant and a routine with the same letters: `const STORE.SET = 1;` next to `procedure store.set` → `name already used by a variable or constant` / `duplicate global declaration`. **Right:** give constants a name that is not a routine: `STORE.OPSET`, `CURVE.NDAYS`, `HTTP.GET`.
- A parameter `N` next to a global `n`, or a type `Out` next to a variable `out` → `name already used by a type` / `duplicate declaration`. **Right:** one name per concept; local names that do not collide with globals (`cnt`, `res`).
- A builtin as a name: `procedure f(len: int)` or `var len: int` → `that name is built in`. Builtins: `len addr view scan ord chr real trunc round sqrt pack32 unpack32 slen schar sadr band bor bxor bnot shl shr argc argch halt sys1..sys6 winapi`. **Right:** `n`, `count`, `nbytes`.
- `tools` as a namespace (`tools.list`) → `variable name expected`: `tools` is a keyword. **Right:** `tool.list`, `tool.run`.
- A type name (record, schema) is *also* an ordinary identifier: `schema Point` and `var point: ...` collide. **Right:** `var p: Point`.
- Dotted names are cosmetic: `mcp.buf` and `mcp.Buf` are the same thing; so are `a.b` and `A.B`. There is no module scope.
- **A prefix is claimed globally, so two files cannot both own one.** Two includes that each build a `run.*` namespace give `duplicate global declaration` on the first variable of the second one — and only in a program that happens to include both, so each file compiles on its own and the pair does not. **Right:** before choosing a prefix, grep for it across everything the program can include and take one that is free; rename the newer file rather than the one that already has callers. (18-09-2026)
- **A builtin with no arguments still needs its brackets**: `if argc < 2` → `missing ( after builtin`. **Right:** `argc()`. Same for anything in the builtin list used as a value. (18-09-2026)

## Types

- `x / 2` on ints → `/ divides reals; use div for integers`. **Right:** `x div 2`; `/` only on `real`.
- `r := i` with `r: real`, `i: int` → `type error in assignment: expected real, found int`. **Right:** `r := real(i)`; back again with `trunc(r)` (toward zero) or `round(r)`.
- `ord(b)` on a bool → `type error in ord: expected char`. **Right:** `if b then x := 1 else x := 0`.
- An `int` as a condition (`if n then`) does not exist. **Right:** `if n <> 0 then`.
- `s = "abc"` → `strings cannot be compared with = or <>`. **Right:** `json.eq(b, at, last, "abc")` (last = exclusive end index) or `hash.same` / your own loop.
- `str` is only the type of a literal (for `io.puts(fd, "..")`, `slen/schar/sadr`). Text as a value is an `array of char` plus an `int` holding how much of it is filled. A parameter `s: array of char` accepts a literal, an array, a slice and a view, so pick `array of char` in new code.
- There is no 32-bit real, no `byte`, no `boolean`, no `integer`. Only `int char bool real str` and `array`.
- There is **no `writeln`/`write`**. Output is `io.puts(fd, "..")` and `io.putn(fd, v)` (int); a real becomes text through `json.putreal` into a buffer. The error is `undeclared identifier` on the whole line, so with several nested calls check the **outermost** name first, not the arguments. Note: a smoke test that prints nothing compiles fine and therefore proves nothing about output.
- `1.` and `.5` are not literals; write `1.0` and `0.5`. A negative real literal in a `const` is allowed (`NEG = -2.5`).

## Arrays, slices, view, records

- A slice as a value: `x := a[1..3]` or `var s := ...` → `a slice can only be passed as an array argument`. **Right:** slices and `view(addr, n)` only where an `array of T` argument goes.
- `addr(s[0])` on an empty slice or view → runtime `array index out of range`. **Right:** guard with `if len(s) > 0` (or `n > 0`) first; for an empty range pass `addr(buf[at])` of the source buffer.
- Slices are **inclusive**: `a[lo..hi]` has `hi - lo + 1` elements; `a[3..2]` is empty. So a "from..to-exclusive" pair (`at`, `upto`) in library style becomes `b[at..upto - 1]`.
- A record as a parameter or result (`function f(p: Point)`) → `this parameter needs an array` / `type expected`. **Right:** `procedure f(p: array of Point)` and use `p[0]`; pass it the record variable itself, `items[i..i]`, or `view(address, 1)`.
- Copying a record field by field in a loop is unnecessary: `a := b` copies the whole record (same type required, otherwise `record types differ in assignment`).
- No `array of array`, no record in a `const`, no record in an expression.
- An empty `array of T` argument has no literal form: pass an empty slice `a[0..-1]` (or `a[i..i - 1]`).
- A builtin or keyword name *is* allowed as part of a dotted name: `addr.x`, `addr.f`, `co.for`, `x.end`, `app.type` are ordinary identifiers (the dot makes it one token; `addr.` tested 10-09).
- `len(a)` works on array names and on `array of T` parameters, not on a `str` (that is `slen`) and not on a constant (`a constant has no elements`).
- `array[lo..hi]`: `lo` may be ≠ 0; indexing starts at `lo`. All arrays are fixed; "growing" means keeping a counter (`docs/language.md` §10b).
- Large arrays belong **at global scope** (bss); a local array of megabytes sits on the stack (~8 MB) and crashes.

## Routines

- Throwing away a function result: `store.set(...)` as a statement → `the value of this function call is not used`. **Right:** `ok := store.set(...)`, or make the routine a `procedure`; avoid `if store.set(...) then ;` constructions and use an `ok` variable instead.
- A `function` with no `return` on some path → runtime `function without return`. **Right:** every path ends in `return`, including after a `while true`.
- A `procedure` with `return value` → error; `return;` without a value is fine.
- No `var` parameters: results written back go through an `array of T` argument (a view onto the caller's storage) or through a global.
- Ten arguments maximum, and an array counts as two → `wrong number of arguments` / `too many arguments in call`, or a refusal at the declaration. Three arrays plus five ints does not fit; pass a slice as the write target (see patterns). If you need more than three buffers (a query with four keys), make them state with setters: `q.clear`, `q.setX(...)`, then the call with no arguments. **Count the slots before you write the signature**; this is the second most common mistake.
- Callback pattern: the library declares `procedure app.request; forward;` and the application defines it. If it is missing → `forward declared routine is never defined`. The signature must match exactly (`parameter type differs from the forward declaration`).
- No nested routines, no function pointers, no default arguments, no overloading.
- `return` in the main program is not allowed; use `halt(code)`.

## Syntax

- A `;` before `else` → `unexpected else (no ';' may precede it)`. **Right:** `if c then a else b;`
- **An `else` binds to the nearest unclosed `if`.** So in an if-chain, an arm whose body is itself an `if` **without** its own `else` swallows everything after it — and the compiler says nothing, because the result is valid code that means something else:
  ```pascal
  if k = 1 then
    if v > 0 then out := 1        // still open...
  else if k = 2 then out := 2     // ...so this else belongs to the INNER if
  ```
  Here `k = 2` and `k = 3` never run at all, and `k = 1` with `v <= 0` runs the last arm. **Right:** put `begin ... end` around the inner `if`. This is the mistake to look for after rewriting a `case` into a chain; it cost a silent wrong answer (1e+22 instead of 6830) in an ONNX kernel, caught only by a parity test against recorded reference values. Every shape, with its output, is in `tests/lang/if_shapes.wz`.
- When a chain is written out by a **generator**, each arm closes bare and only the last one carries the `;` — otherwise the emitted code trips the rule above and the compiler refuses its own output.
- A routine body without `begin` (for example `var` after `begin`) → `missing begin in routine body`. The order is: header `;`, then the `const`/`var` blocks, then `begin ... end;`.
- `for i := a to b do` counts in steps of 1, `downto` counts back; `i` is an ordinary `int` variable (not a `real`, not a field).
- A program ends with `end.` (a period); a routine with `end;`. Anything after `end.` → `text after the end of the program`.
- `type` and `schema` may appear only at program level, before the routines that use them; `tools ... end;` once, after the schemas.
- Comments: `//` only. Neither `{ }` nor `(* *)` exists, and a `{` outside a string is refused. The block comment was removed on 15 September 2026 because it ended at the **first** `}`: a JSON example like `{"a":1}` inside one turned the rest of the sentence into code, and the error surfaced far away on a line that looked correct. Write a multi-line comment as several `//` lines.
- Character escapes: `'\n' '\t' '\r' '\0' '\\' '\''`, `"\""`, and **`'\xHH'` with exactly two hex digits** (since 15-09-2026) — so `'\x1b'` rather than `chr(0x1B)`, and a generator can embed UTF-8 or binary directly: `"caf\xc3\xa9"`. Two digits always, never more: `"\x41BC"` is three characters, unlike C. Anything else after a backslash → `unknown escape sequence`.
- Hex literals: `0xFF`. No `$FF` (Pascal), no `1_000`.

## Includes and standalone tests

- Using a routine from ANOTHER file that your own file does not include →
  `undeclared identifier`, but **only in the standalone test**, not in the main build. The
  main program includes everything, so it compiles there; a standalone test includes a
  handful of files and then falls over on a call that lives in a file it did not include.
  **Right:** use the routine from the file itself if it exists (there is often a local
  variant with the same signature), and when you add a helper, check the includes of the
  STANDALONE tests for that file —
  `grep -l 'src/<file>.wz' tests/**/*.wz`.

## Library (wrong assumptions)

- `sha256.hex(dst, src)` expects exactly 32 bytes of input; for 16 bytes use your own hex routine (`oauth.hex16`).
- `io.puts(fd, s: str)` takes only a literal; for a buffer use `io.out(fd, addr(b[0]), n)`.
- `io.out` is a **procedure**, not a function: `n := io.out(...)` → `a procedure has no value`. So it does not tell you how many bytes were written (the C habit from `write()`). **Right:** `io.out(fd, addr(b[0]), n);` as a statement; if you do want the count, call `sys3(SYS.write, fd, addr(b[0]), n)` directly. (12-09-2026)
- `io.push(b, at, "lit")` and `io.pushnum(b, at, v)` return the **new position** (not the number of bytes written).
- `json.eq(b, at, last, "lit")`: `last` is exclusive; on a whole `array of char` parameter: `json.eq(s, 0, len(s), "lit")`.
- Miscounting that same exclusive end on a **quoted key** fails **silently**: `json.eq(b, i, i + 16, "\"total_matched\"")` is always `false`, because the literal is 15 characters (the quotes count), so the end is `i + 15`. No compile error, no runtime error — the branch simply never runs and the code does something other than what you think. **Right:** check the length by an independent means (`printf '%s' '"total_matched"' | wc -c`) and use `i + <that length>`; then advance `i` by the same amount. The existing `json.eq(tool.out, 1, 9, "\"result\"")` is the good example: 8 characters, end 9. (12-09-2026)
- `json.unescape(src, from, upto, dst, at)` does not check `len(dst)`: guard the length yourself before the call.
- `json.escslice` / `putslice` escape `\n \t \r " \\` and control characters.
- `http.finish(status, ctype)` closes off the response; before it come `http.add/addn/addb`; headers go in with `http.hdradd("Name: value")` before `finish`.
- `store.table(...)` must come before `store.opendir(...)`; `oauth.tables` before `store.opendir`, `oauth.load` after it.
- `store.set(t, row, rec)` expects an `array of char` view of exactly `recsize` bytes: `view(store.rowaddr(t, row), SIZE)`.
- Working out a record size in bytes by hand (`ISIZE = 16 + 8 + ...`) is error-prone; measure it with `addr(items[1]) - addr(items[0])` or `addr(last_field) - addr(first_field) + size`.
- The `curve.*` constants are called `CURVE.NDAYS`, `CURVE.NHOURS`, `CURVE.DAYLEN` (not `CURVE.DAYS`, which collides with `curve.days`).
- A `text` view (`f_at`/`f_end`) in an output schema is placed between quotes **raw** by `Out.write`: the bytes must already be JSON-escaped. So fill `tool.vbuf` with `json.escslice` (text) or `json.putraw` (only for a `json` field that is already valid JSON).
- **Two different contracts for "it does not fit", and which one you get depends on what you are building.** The appenders in `lib/` — `io.push`, `io.pushnum`, `json.putraw`, `json.putstr`, `json.escslice`, `json.putreal` — **truncate** at `len(dst)` and hand back a position that is still usable, because a shortened message is still a message. A generated `<Schema>.write` and `json.putslice`/`json.putb` **refuse** with `-1`, because a shortened JSON object is not a shorter object but a syntax error. So: **always test the result of `Out.write`** (`if n < 0 then ...`); never assume a chain of `io.push` wrote everything (compare the position that comes back with the one you passed in). Neither one writes past the end any more, so getting it wrong no longer kills the process — it silently drops bytes or refuses, which is a great deal easier to find. (14-09-2026)
- **Forgetting the `include` is the first mistake, and the compiler now says so**: `io.puts` without `include "io.wz"` reports `undeclared identifier: io.puts is declared in io.wz; add: include "io.wz";` (since 15-09-2026). If you get the bare message instead, the name is in no library — check the spelling.
- **A constant and a routine share one namespace, and names are case-insensitive**, so `STORE.SET` is the same name as `store.set` and the dot does not separate them. That is where `STORE.OPSET` and `CURVE.NDAYS` come from — names bent to dodge a collision. Since 15-09-2026 the compiler says so (`duplicate declaration; names are case-insensitive, so STORE.SET is the same name as store.set`) instead of only `duplicate declaration`. Pick a prefix that is not already a routine's, rather than a spelling that happens to slip past.
- A **`str` variable is not an `array of char`** — only a string *literal* converts (`kv.find(b, 0, n, "key")` compiles, `kv.find(b, 0, n, key)` with `key: str` does not). Copy it first: `k := io.push(buf, 0, s);` then pass `buf[0..k - 1]`. Since 15-09-2026 the compiler says so in those words instead of `this parameter needs an array`, which gave no hint that a literal would have been accepted in the same position.
- A schema **refuses a key it does not declare** (since 15-09-2026): `parse` returns `-1` and `b[json.badkey0..json.badkey1)` is the offending key. So declare everything the input may carry, not only what you read. For an open protocol envelope — an MCP `initialize`, an OAuth registration — that means declaring the protocol's own members as `json?`; leaving them out makes every genuine message fail, and a caller that ignores the `-1` then runs on defaults. Print the key when you report the failure: `parse` answers `-1` for every kind of failure, and an unknown key is the one the caller can actually fix.
- `lib/tools.wz` includes `http.wz`, so even a stdio-only program with a `tools` block must define `procedure app.request` (otherwise `forward declared routine is never defined` on the last line). A `forward` error always points at `end.`; look for the missing `app.*` hook in the library headers.
- `http.serve(port, workers)`: `SO_REUSEPORT` only when `workers > 1`; in tests always use 1 worker.
- A `json?` argument that may be a list **or a single string**: after `arg.take(at, upto)` a lone JSON string already sits in `arg.buf` without its quotes, and `arg.strings(arg.buf, 0, arg.n)` then returns `-1`. **Right:** `arg.strings(arg.raw, 0, upto - at)` on the raw copy (which understands a list, a string containing a list, and a bare string). `arg.buf` is for a string that contains an object (`arg.object`).
- Copying a text value out of `kv.find`/`kv.first` raw (`dd.settext(dst, b[kv.vat..kv.vend - 1], ...)`) → the value keeps its **quotes** (`"dryer"` instead of `dryer`) and every comparison after that fails silently: no compile error, no runtime error, the code just does nothing. **Right:** `n := kv.text(b, dst, 0);` — it strips the quotes, decodes the escapes, and returns `-1` when the value is not a string at all. Doing the arithmetic yourself (`kv.vat + 1, kv.vend - 1`) is what went wrong here and once more on the KEY, which is already without quotes, losing a character at each end. (11-09-2026; `kv.text` added 15-09-2026)
- `http.header("Accept")` with capitals used to find **nothing, ever**: `http.hdreq` lowercased the bytes from the buffer but compared them against the literal exactly as written, so you got `false` and concluded the header was absent — no error, no warning. **Fixed 15-09-2026: the comparison is case-insensitive on both sides, so either spelling works.** On a compiler older than that, write the name in lower case. (11-09-2026)
- `kv.scanobj`, `kv.pair`, `kv.first`, `kv.next` and `kv.find` **position** the cursor `kv.kat`/`kv.kend`/`kv.vat`/`kv.vend`; save what you still need before calling one of them. `kv.isobject`, `kv.count` and `kv.match` only ask a question and **restore** the cursor since 15-09-2026 — before that they moved it too, which cost two application bugs, both silent (batch submit of configurable values, 10-09).
- `arg.take` unwraps a JSON string; `arg.strings(arg.buf, 0, arg.n)` afterwards sees a single string (`"key"`) as bare text and returns -1. For "a list, a string containing a list, or a single string", copy the raw view bytes (`arg.byte`) and run `arg.strings` on those; it unwraps a string-with-a-list itself.
- `time.parseiso` reports failure through `time.ok`, not through what it returns. A refused
  string gives `-1`, but so does a moment one second before the epoch, so read the flag.
  It accepts a bare date, a fractional part, `Z`, a `+HH:MM` offset and a space in place of
  the `T`; see [`lib/time.md`](lib/time.md) for the shapes.

## Working copies (one global record per entity)

- **Never pass a field of the working copy as an argument to a routine that reloads that working copy.** `uc.winner(dd.k.curve_ref)` scans every row and reloads `dd.k` while doing so: the slice then pointed at changed content, with no error message, and the result was partly correct (1 of 2 groups). Copy such a value into your own buffer first. This is the same trap as the one below, but through a parameter rather than a later read.
- With one working copy per entity (`dd.p`), a `profile.load(other)` halfway through an edit overwrites your changes. Indirectly too: `ctx.default`, `ctx.owns`, `ctx.selectall` scan profiles, which is why they have their own copy `ctx.p`. The rule for new scan and search helpers: never use `dd.*`, always your own record. And the other way round: a handler loads what it writes out itself (`profile.load(row)`) and does not trust whatever a helper happened to leave behind (went wrong three times on 10-09). The rule: handle all the *other* rows first, and only then load, change and save your own row. Or use a second working copy for the other row.

## Syscalls and memory

- `sys3(SYS.open, addr(path[0]), flags, mode)`: the path must be **null-terminated**: `path[n] := chr(0)`.
- Combine open flags with `bor(bor(O_WRONLY, O_CREAT), O_TRUNC)`, not with `+` or `or`.
- `peek8`/`peekreal` do not exist: `peek(a)` reads **one byte**. To read an `int` or a `real` at an address, use a typed view of one element (`f(view(a + off, 1))` with `f(a: array of int)` or `array of real` respectively); see patterns. (11-09-2026)
- `mmap` returns a negative value on failure (−errno); check `p < 0`.
- Addresses are ordinary `int`s; use `view(p + offset, n)` to read through them. A view on `char` is bytes; on `int` it is 8 bytes per element (alignment is not required, but it is faster).
- Everything is static: no `new`, no recursive data structure through pointers; use indices into arrays (`docs/language.md` §10b).

## Tests (wztest)

- A `.out` must match **exactly**, including line numbers in runtime errors and the final newline. Work the values out with Python; count lines with `wc -l`.
- Compile-error tests (`.err`) match on the message text; the line number must match the source.
- Network tests: derive the port from `$$`, wait in a loop until the server answers, and clean up the background process with a `trap` (see patterns). This suite deliberately has no port-lease helpers: that is application tooling.
- The Bash tool sometimes refuses heredocs containing control characters in a `.sh`: write such a file with the Write tool or with `printf`.
- A function you call with `$(...)` runs in a **subshell**: variables it sets (a list of leases, a counter) are gone the moment it returns. Pass such state through a file, or have the function print nothing and set the variable directly.
- `wztest` runs `.sh` tests with **dash**, not bash: no `10#`, no arrays, no `[[ ]]`, no `${var//x/y}` (two agents, 10-09-2026).
- Shell arithmetic on numbers from `date`/`cut`: a leading zero (`099`) is invalid octal → `arithmetic expression: expecting ')'`, at random. Put a digit in front (`1$(...)`) or use `10#` in bash. This was the unexplained flaky suite of 10-09.
- A test that measures time is a benchmark (`tests/bench/`, runs only with `--bench`), not a normal test. Put a `.min` or `.max` next to it to turn it into a hard limit.
- `progs/` directories hold helper programs, not tests.
- **No ticket number in the header of a test.** Which tests belong to a ticket is recorded in
  the TICKET (`tests:`), not in the test file: two places saying the same thing drift apart.
  Open instead with a line saying what the test guards. (This holds in the compiler repo;
  the application still has such headers -- see its own docs.)

## A wrong result that looks like a choice

Most pitfalls above announce themselves: a compile error, a crash, a wrong number. The
expensive ones do not. They produce output that is *plausible* — faded, slightly off,
oddly spaced — and a plausible result invites you to adjust taste instead of to debug.

**Rules that pay for themselves:**

- **If you change an input and the output does not change, you are tuning the wrong
  variable.** Two rounds of this is the signal to stop adjusting and start measuring. The
  constraint is somewhere you have not looked.
- **Measure the data, not the rendering.** Print the actual values your code produced —
  maxima, counts, ranges — rather than judging the picture. `max 31 of 255` settles in one
  line what an hour of staring cannot.
- **Know the healthy range before you look.** A number only reads as wrong next to what it
  should have been, so state the expected bound first, then measure.
- **Suspect off-by-a-factor before off-by-a-pixel.** A value that is 1/8th or 1/64th of what
  it should be points at a loop that exits early or a divisor that does not match what was
  counted — not at a formula that is slightly out.

**A loop that counts and a divisor that disagree** is the classic source. If you accumulate
over a nested loop, make sure nothing leaves it early:

```
// WRONG: the break leaves the inner loop, so hits can never exceed n --
// yet the divisor is still n * n. Everything comes out at 1/n of its true value.
for i := 0 to n - 1 do
  for j := 0 to n - 1 do
    if inside(i, j) then begin hits := hits + 1; break; end;
value := hits * 255 div (n * n);
```

The fix is to remove the early exit; the lesson is that the result was *usable*, just
uniformly wrong, so nothing ever flagged it.

## Spec versus compiler (findings)

- `and`/`or` are short-circuit (the spec said otherwise at first; corrected).
- Identifiers are case-insensitive (the spec first said case-sensitive; corrected).
- After every routine, `nloc` must be 0; a compiler bug here produced "stale locals" in constant expressions (fixed; regression test `tests/compiler/for_const.wz`).


---

# Patterns

Everything below compiles with the current `wantzel`. Take the nearest
pattern and adapt it; do not invent your own variant of something listed here.

## The argument order of the routines you use most

**This is the biggest source of errors there is**: 30 of the 100 recorded mistakes are
library use — a wrong routine name, or the arguments in the wrong order. The two groups
below cover almost all of it, and each group has ONE shape.

**Appenders — `(buffer, at, what)`, returning the new position.** The buffer first, where
to write second, what to write third. Chain them by feeding the result back in.

| | |
|---|---|
| `io.push(b, at, s)` | a string literal, returns the new `at` |
| `io.pushnum(b, at, v)` | a number |
| `json.putstr(dst, at, s)` | a literal, quoted and escaped |
| `json.putslice(dst, at, src, from, upto)` | bytes from another buffer, quoted and escaped |
| `json.putraw(dst, at, src, from, upto)` | bytes verbatim, no quotes |
| `json.putreal(dst, at, v)` | a real |
| `json.putb(dst, at, c)` | one byte |
| `kv.text(b, dst, at)` | the cursor's value, decoded — **note: source first, then dst** |

```pascal
n := io.push(buf, 0, "{\"name\":");
n := json.putstr(buf, n, "probe");
n := io.push(buf, n, "}");
```

**Readers — `(buffer, at, upto)`, `upto` exclusive.** The span to look in, never a length.

| | |
|---|---|
| `json.ws(b, at, last)` | skip whitespace, returns the first non-blank position |
| `json.skip(b, at, last)` | past one whole value |
| `json.string(b, at, last)` | past a string; the text is `b[json.sat..json.send)` |
| `json.eq(b, at, last, s)` | is that span exactly this literal? **count the literal including its quotes** |
| `kv.find(b, at, upto, key)` | key as `array of char`, not a `str` |
| `kv.first(b, at, upto)` / `kv.next(b, cur, upto)` | walk an object |

**Two traps inside that shape**, both of which have cost real time here:

- `json.eq(b, i, i + 16, "\"total_matched\"")` — the end is **exclusive**, and the literal
  with its quotes is 15 characters, so the end is `i + 15`. Count it, do not estimate.
- `kv.find` wants the key as bytes, but `json.eq` takes a `str` literal — which tempts you
  to pass a literal to both. For `kv.find`, copy it first: `n := io.push(b, 0, "name");`
  then `kv.find(..., b[0..n - 1])`.

## What each routine gives you when it fails

`-1`, `false` and `0` do not mean the same thing, and which one you get depends on what
kind of routine it is. The rule behind it:

| kind | on failure | why |
|---|---|---|
| **appenders in `lib/`** (`io.push`, `json.put*`) | truncate at `len(dst)` and return a usable position | a shortened message is still a message |
| **a generated `<Schema>.write`**, `json.putslice`, `json.putb` | `-1`, and nothing usable written | half a JSON object is not a shorter object but a syntax error |
| **parsers** (`json.skip`, `json.string`, `kv.pair`) | `-1` | there is no position to continue from |
| **questions** (`kv.find`, `json.eq`, `fs.stat`) | `false` | |
| **a generated `<Schema>.parse`** | `-1`, with the offending key in `json.badkey0..json.badkey1` | an unknown key is refused, not skipped |
| **`kv.text`** | `-1` | the value is not a string, or does not fit |

So: **always test the result of `write`** and of anything returning `-1`; never assume a
chain of `io.push` wrote everything — compare the position that came back with the one you
passed in.

## A buffer and its length, together

Every one of the six recorded memory errors comes from these two drifting apart. Declare
them side by side and treat them as one thing:

```pascal
var
  buf: array[0..1023] of char;
  buf_n: int;                      // how much of buf is filled

buf_n := io.push(buf, 0, "text");
if buf_n >= len(buf) then ...      // it truncated: the position hit the end
```

Pass the filled part as a **slice**, never the whole array: `use(buf[0..buf_n - 1])`.
Passing `buf` hands over 1024 bytes of which most are zero, and the receiver cannot tell
where the text stops.

## A whole command-line tool

Everything below is needed and nothing is spare: the usage line, the argument copied out
with its length guarded, the failing `open` reported, and a distinct exit code for "you
used it wrong" (2) versus "it did not work" (1).

```pascal
include "io.wz";

var
  path: array[0..1023] of char;
  buf: array[0..65535] of char;
  fd, n, i, lines, bytes: int;

begin
  if argc() < 2 then
  begin
    io.puts(STDERR, "usage: wc <file>\n");
    halt(2);
  end;
  i := 0;
  while argch(1, i) <> chr(0) do
  begin
    if i >= len(path) - 1 then begin io.puts(STDERR, "wc: the path is too long\n"); halt(2); end;
    path[i] := argch(1, i);
    i := i + 1;
  end;
  path[i] := chr(0);                    // a syscall wants it NUL-terminated

  fd := sys3(SYS.open, addr(path[0]), O_RDONLY, 0);
  if fd < 0 then begin io.puts(STDERR, "wc: cannot open that file\n"); halt(1); end;

  lines := 0; bytes := 0;
  while true do
  begin
    n := io.read(fd, addr(buf[0]), len(buf));
    if n <= 0 then break;
    bytes := bytes + n;
    for i := 0 to n - 1 do
      if buf[i] = chr(10) then lines := lines + 1;
  end;
  sys1(SYS.close, fd);

  io.putn(STDOUT, lines); io.puts(STDOUT, " lines, ");
  io.putn(STDOUT, bytes); io.puts(STDOUT, " bytes\n");
end.
```

## A whole MCP server

The `tools` block generates the tool table, the argument parsing, the dispatch and the
result writers; what is left to write is the handler. Two lines are easy to leave out and
neither is optional:

```pascal
include "json.wz";

type AddArgs = schema
  a: int "the left operand";
  b: int "the right operand";
end;

type AddResult = schema
  sum: int;
end;

tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
end;

include "tools.wz";                     // AFTER the tools block: it reads it

function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;

// lib/tools.wz includes http.wz, so even a stdio-only server must define this
procedure app.request;
begin
end;

begin
  mcp.stdio;                            // or http.serve(port, 1) for MCP over HTTP
end.
```

That answers `initialize` and `tools/call` on standard input, and `mcp.name` /
`mcp.version` are yours to set if you want your own name in the handshake.

## Program skeleton with an include

```pascal
include "../../../lib/io.wz";       // path relative to THIS file
const MAX = 10;
var
  i, n: int;
  buf: array[0..1023] of char;
procedure show(s: str; v: int);
begin
  io.puts(STDOUT, s); io.putn(STDOUT, v); io.puts(STDOUT, "\n");
end;
begin
  n := 0;
  for i := 1 to MAX do n := n + i;
  show("sum = ", n);
end.
```

## Command-line arguments

```pascal
var port, i: int; c: char; dir: array[0..255] of char; dirn: int;
...
  port := 0; i := 0;
  while true do
  begin
    c := argch(1, i);
    if c = chr(0) then break;
    port := port * 10 + (ord(c) - 48);
    i := i + 1;
  end;
  dirn := 0;
  while argch(2, dirn) <> chr(0) do begin dir[dirn] := argch(2, dirn); dirn := dirn + 1; end;
  store.opendir(dir[0..dirn - 1]) ...
```

## Building text and writing it out

```pascal
n := io.push(buf, 0, "item");         // returns the new position
n := io.pushnum(buf, n, 42);
buf[n] := chr(0);                     // only needed for syscalls (paths)
io.out(STDOUT, addr(buf[0]), n);      // buffer; io.puts is for literals only
```

Comparing text: `json.eq(buf, at, upto, "literal")` (upto exclusive). Passing text
along: `f(buf[0..n - 1])`; inside `f(s: array of char)`, `len(s)` is the length.

## Passing and storing records

```pascal
type Item = record id: int; value: real; name: array[0..31] of char; name_n: int; end;
var it: Item; items: array[0..99] of Item; nitems: int;
procedure fill(dst: array of Item; id: int);   // dst[0] is "the" record
begin dst[0].id := id; dst[0].value := 1.5; end;
...
  fill(it, 1);                 // a record variable = a view of one element
  fill(items[3..3], 4);        // one element of an array
  items[nitems] := it; nitems := nitems + 1;      // a whole copy
  fill(view(store.rowaddr(tab, row), 1), 7);      // a row in a store table
  if not store.set(tab, row, view(store.rowaddr(tab, row), addr(items[1]) - addr(items[0]))) then ...
```

## A list of unknown length (without a heap)

```pascal
var xs: array[0..9999] of int; nxs: int;      // capacity + counter
function push(v: int): bool;
begin
  if nxs >= len(xs) then return false;
  xs[nxs] := v; nxs := nxs + 1; return true;
end;
```

Declare large buffers globally; use a `view` on `mmap` memory if it has to grow
beyond that (see `docs/language.md` §10b).

## Linked structures without pointers: the index IS the pointer

There are no pointers, and for data you do not need them. Where C keeps an address, keep
the **index** of the element instead, and use `-1` for "none". An index cannot dangle, it
is bounds-checked at every use, and — unlike an address — it still means the same thing
after you write the array to disk and read it back.

**The shape is always the same:** one array holds every node, a counter says how many are
live, and every link is an `int` into that array.

```pascal
type Node = record val, next: int; end;       // `next` is an index, not an address
var nodes: array[0..1023] of Node; nn, head: int;

function alloc(v: int): int;                  // -1 when full: refuse, never truncate
begin
  if nn >= len(nodes) then return -1;
  nodes[nn].val := v; nodes[nn].next := -1;
  nn := nn + 1; return nn - 1;
end;
```

### A doubly-linked list, including removal from the middle

```pascal
type Node = record val, prev, next: int; end;
var nodes: array[0..1023] of Node; nn, head: int;

procedure unlink(x: int);
begin
  if nodes[x].prev >= 0 then nodes[nodes[x].prev].next := nodes[x].next
  else head := nodes[x].next;                          // x was the head
  if nodes[x].next >= 0 then nodes[nodes[x].next].prev := nodes[x].prev;
end;
```

### A tree, and a graph that contains cycles

A tree is the same record with `left` and `right`. A graph is the same record with an array
of edges. **Cycles need no special care** — an index cannot point at freed memory, so the
"use after free" that makes cyclic structures dangerous elsewhere cannot happen. Guard the
walk against revisiting, and that is all:

```pascal
procedure walk(x: int);
var i: int;
begin
  if seen[x] then return;                     // the only thing a cycle needs
  seen[x] := true;
  i := 0;
  while i < g[x].ne do begin walk(g[x].edge[i]); i := i + 1; end;
end;
```

### Reuse: a free list, not an allocator

Removing a node does not free memory — nothing was allocated. To reuse the slot, keep the
freed indexes in a list of their own; `lib/store.wz` does exactly this with a `store.free`
hint per table. One reservation up front, and inside it every reference is an index.

### It survives a restart, and that is the part people miss

Because a link is an index and not an address, the whole array is **its own file format**.
Write the raw bytes, read them back, and every link still points where it did — no
serialisation, no fix-up pass, no version field:

```pascal
fd := sys3(SYS.open, addr(path[0]), 577, 420);        // O_WRONLY|O_CREAT|O_TRUNC
n  := sys3(SYS.write, fd, addr(nodes[0]), nn * 24);   // 24 = the record's size
sys1(SYS.close, fd);
```

With real pointers this cannot work: every address would be wrong after loading.

### The one thing an index does not protect you from

It cannot dangle, but it **can point at the wrong row**. A zeroed link field means index 0,
not "none" — so initialise links to `-1` explicitly, or a node ends up as its own child and
a walk recurses until the stack runs out. That is the mistake to look for, because the
compiler cannot see it.

## Reaching memory the program never declared

`view(addr, n)` turns any address plus a length into an ordinary, bounds-checked array.
That is the escape hatch for everything the shapes above do not cover — memory from the
operating system, a shared segment, a mapped file:

```pascal
base := sys6(SYS.mmap, 0, 4096, bor(PROT_READ, PROT_WRITE),
             bor(MAP_PRIVATE, MAP_ANONYMOUS), -1, 0);
fill(view(base, 4096));                       // an ordinary array of char
fill(view(base + 10, 100));                   // a window at an offset
sys2(SYS.munmap, base, 4096);
```

That second `view` is pointer arithmetic in every respect that matters — except that the
window carries its own length, so indexing inside it is still checked. `view` and `sys*`
are the unsafe primitives: nothing verifies that the address and the length are right.
Everything *inside* the view is as safe as any other array.

## List arguments (a small `arg.*` layer on top of json)

```pascal
if not arg.take(a[0].keys_at, a[0].keys_end) then return tool.fail("keys: malformed");
n := arg.strings(arg.raw, 0, a[0].keys_end - a[0].keys_at);   // on the RAW view, not arg.buf
```

`arg.take` strips the quotes off a bare string; `arg.strings` still needs to see them to
recognise `"abc"` as a single item. Inside an object that has already been copied (say
`ctx.pbuf`) the value is still raw, and you can use `arg.strings(ctx.pbuf, kv.vat, kv.vend)`
directly.

## info filters (lib/kv.wz): which side decides

`kv.match(obj, .., filter, ..)`: every filter key must exist in `obj`, and per key the
**stored** side decides which of two rules applies.

| stored value | filter value | rule |
|---|---|---|
| not a list | a list | membership: the stored value equals one of the elements |
| a list | anything | containment: the stored list holds the filter value, or all of a filter list's elements |
| not a list | not a list | equality (`kv.same`), which is what containment means there |

So `{"tags":"a"}` matches a stored `["a","b"]`, and a stored list **contains itself**:
`{"tags":["a","b"]}` matches `["a","b"]`. The two empty-list cases pull apart, and that is
deliberate: an empty **filter** list on a non-list stored value matches nothing (there is
nothing to be a member of), while an empty filter list against a stored list matches
everything (containment of nothing is vacuously true).

`kv.contains` and `kv.haselem` are the containment half on their own, if you need it
without the surrounding object walk.

## Ten argument slots: an array counts double

Three arrays (6 slots) leave room for four scalars. A routine with three buffers plus
(from, upto) × 2 plus a write position does not fit: drop the write position and pass
a slice instead: `n := kv.merge(b, 0, bn, p, 0, pn, out[at..len(out) - 1])`.

## Returning a scalar result without a var parameter

```pascal
procedure co.schedule(...; n: array of int);   // n[0] becomes the count
var cnt: array[0..0] of int;
...
  co.schedule(..., cnt); k := cnt[0];
```

Several results: one record through `array of R`, or one `array of int` with fixed positions.

## Writing a file and mapping it

```pascal
n := io.push(path, 0, "data.bin"); path[n] := chr(0);
fd := sys3(SYS.open, addr(path[0]), bor(bor(O_WRONLY, O_CREAT), O_TRUNC), 420);
if fd < 0 then io.fatal("open");
if sys3(SYS.write, fd, addr(buf[0]), n) <> n then halt(2);
sys1(SYS.close, fd);
fd := sys3(SYS.open, addr(path[0]), O_RDONLY, 0);
p := sys6(SYS.mmap, 0, bytes, PROT_READ, MAP_SHARED, fd, 0);
if p < 0 then halt(3);
total := curve.sum(view(p, bytes), 0, 525600);
sys2(SYS.munmap, p, bytes);
```

## HTTP handler (lib/http.wz + router)

```pascal
procedure app.request;
var uid: int;
begin
  if oauth.route then return;                       // OAuth endpoints first
  if http.pathis("/protected") then
  begin
    uid := oauth.verify;
    if uid < 0 then begin oauth.challenge; return; end;
    http.add("{\"user\":"); http.addn(uid); http.add("}");
    http.finish(200, "application/json");
    return;
  end;
  if router.get("/health") then begin router.text(200, "ok"); return; end;
  router.notfound;
end;
...
  http.serve(port, 1);
```

## Schema + tools (MCP/REST without the handwork)

```pascal
type AddArgs = schema a: int "left"; b: int "right"; end;
type AddResult = schema sum: int; end;
tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
end;
include "lib/tools.wz";
function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin r[0].sum := a[0].a + a[0].b; return 0; end;
```

## Test program (wztest, `.wz` + `.out`)

```pascal
// What the test demonstrates, in one sentence.
include "../../../lib/x.wz";
procedure show(s: str; v: int); begin io.puts(STDOUT, s); io.putn(STDOUT, v); io.puts(STDOUT, "\n"); end;
begin
  show("a = ", f(1));
end.
```

Work the expected output out with Python and record it with `./wztest --update tests/path/t.wz`
**only** after you have verified the values independently.

## Shell test (`.sh`)

`tests/helpers.sh` is deliberately small in this repo: `compile`, `assert_eq` and
`assert_contains`, and nothing more. The suite tests the language and the compiler, not an
application, so there is no server to start and no port to lease. A program that needs a
port derives it from `$$` itself and cleans up its own background process.

```sh
# What this test guards, in one line.
. "$ROOT/tests/helpers.sh"
compile "$ROOT/tests/lib/progs/server.wz" "$T/srv"

PORT=$(( 9000 + $$ % 1000 )); U="http://127.0.0.1:$PORT"
"$T/srv" $PORT >"$T/log" 2>&1 & BG=$!
trap 'kill $BG 2>/dev/null; wait $BG 2>/dev/null' EXIT

n=0; until curl -sS -o /dev/null "$U/health" 2>/dev/null; do
  n=$((n+1)); [ $n -gt 50 ] && { cat "$T/log"; exit 1; }
  sleep 0.1
done

assert_eq "health" "$(curl -sS $U/health)" "ok"
```

**Always clean up the background process with a `trap`.** A test that leaves its server
running keeps a port occupied and makes the NEXT test fail on something entirely unrelated
to it -- and that costs hours to track down. A `wait` after the `kill` is not overkill:
without it you are left with a zombie.

## A list argument (json?) in a tool: arg.strings on the raw view

`arg.take(at, upto)` already unwraps a JSON string: `"child"` becomes `child` in `arg.buf`, and
`arg.strings(arg.buf, 0, arg.n)` then sees no `"` or `[` any more and returns -1. So parse lists
on `arg.raw` (the untouched copy): `arg.take(at, upto); n := arg.strings(arg.raw, 0, upto - at)`
That covers a list, a JSON string containing a list, and a single string.

## Reading an int or a real at a raw address

`peek(a)` is the only read builtin and yields **one byte**; `peek8`/`peekreal` do not exist.
You read eight bytes with a typed view of one element -- the same idea as
`view(store.rowaddr(t, row), 1)` for a whole record, but at field level:

```pascal
function db.geti(a: array of int): int; begin return a[0]; end;
function db.getr(a: array of real): real; begin return a[0]; end;
...
  v := db.geti(view(address + offset, 1));      // an int
  x := db.getr(view(address + offset, 1));      // a real
```

The type of the **parameter** decides what the view reads, not the call site. Measure byte
offsets within a record with `addr(rec.field) - addr(rec.first)`, never by hand.


---

# From an error message to its cause

The compiler's messages are terse and sometimes point at generated code instead of at your
own line. This table is the fastest route from symptom to cause. Add to it whenever you
lose an hour to something that could have been listed here.

## The message points at a file you did not write

For example `wantzel: <unitref>:45: undeclared identifier`, or a line number deep inside
`refdata.wz`. That is **generated** code: the schema, the `tools` block, or the Windows
runtime. Your own mistake is then almost always one of these three:

| symptom | cause | fix |
|---|---|---|
| `undeclared identifier` in `<schemaname>` | the library the generator uses is not included | put `include "lib/json.wz";` **before** the schemas; a schema parser calls `json.*` |
| `name already used by a type` in generated code | one of your globals has the same name as a **field** of the schema | rename your global; fields share the namespace inside the generated routines |
| `forward declared routine is never defined` on the last line | an `app.*` hook that a library leaves open is missing | search the library headers for `forward` (`app.request`, `app.tools`, `app.authenticate`) |

**How to find it fast:** do not look at the line number, look at the **name in angle
brackets**; that is the schema or the tool. Then work out which library that generator
needs (the file's header usually says so outright) and whether one of your globals shares
a name with a field in it. Two minutes, instead of half an hour of bisecting.

## `undeclared identifier` on your own line

Almost always one of these two, and both cost you a cycle if you start guessing:

| symptom | cause | fix |
|---|---|---|
| the name does exist, further down the same file | **a routine must appear before its caller** | move the helper up, or declare it `forward` |
| the name is in another `src/` file | the include order | move that file's include earlier; the main program sets the order |

Quickest check: `grep -n "function <name>\|procedure <name>" src/*.wz lib/*.wz`. If it is
there, the problem is order, not spelling.

## Runtime, not compile time

| symptom | cause | fix |
|---|---|---|
| `array index out of range` in generated data | a buffer was made too small for what goes into it | the generator computes the size: if you added something, count it in (for example the minutes text sharing the same `ref.buf`) |
| an answer is half right (one group instead of two) | **aliasing**: a field of the working copy passed to a routine that reloads that working copy | copy the value into your own buffer first |
| a test passes alone but fails in the suite | a port clash or shared state | give every test its own port and working directory (from the process id, or your suite's port lease) and clean up the background process; if that is already the case, look for a shared global or a file that two tests both write |
| empty slice, `addr(s[0])` blows up | `n = 0` | guard with `if n > 0` before `addr` |

## Before you compile

1. **Count the argument slots.** Ten is the maximum and an array counts as two. Four text
   buffers plus a scalar is already twelve. This is the second most common mistake;
   make search keys state with setters (see `ref.q.*`) instead of parameters.
2. Check whether a name you are introducing already exists: `grep -rn "\bname\b" lib/ src/`.
   The namespace is shared and case-insensitive, including the **fields of schemas**.

## Why this works

Today's costliest mistakes were not language errors but **namespace and ordering errors**,
and they cost time because the message pointed at generated code. The question "what name
is in the angle brackets?" gets you to the answer in one step.
