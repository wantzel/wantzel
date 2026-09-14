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
- A builtin or keyword name *is* allowed as part of a dotted name: `addr.x`, `addr.f`, `co.repeat`, `x.end`, `app.type` are ordinary identifiers (the dot makes it one token; `addr.` tested 10-09).
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
- A routine body without `begin` (for example `var` after `begin`) → `missing begin in routine body`. The order is: header `;`, then the `const`/`var` blocks, then `begin ... end;`.
- `case` labels are individual constants (`1, 2:`), not ranges `1..5`; `else` is allowed; `end;` closes it.
- `for i := a to b do` counts in steps of 1, `downto` counts back; `i` is an ordinary `int` variable (not a `real`, not a field).
- A program ends with `end.` (a period); a routine with `end;`. Anything after `end.` → `text after the end of the program`.
- `type` and `schema` may appear only at program level, before the routines that use them; `tools ... end;` once, after the schemas.
- Comments: `//` and `{ }`; `(* *)` does not exist. A `{ ... }` comment ends at the **first** `}`: a JSON example like `{"a":1}` inside one breaks the code that follows (`undeclared identifier` on some later line). Use `//` for comments containing braces. (Hit by two different agents; `wantzellog.py check` catches it now.)
- Character escapes: `'\n' '\t' '\r' '\\' '\''` and `"\""`; any other `\x` → `unknown escape sequence`. No `\xNN`; use `chr(0x1B)`.
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
- `lib/tools.wz` includes `http.wz`, so even a stdio-only program with a `tools` block must define `procedure app.request` (otherwise `forward declared routine is never defined` on the last line). A `forward` error always points at `end.`; look for the missing `app.*` hook in the library headers.
- `http.serve(port, workers)`: `SO_REUSEPORT` only when `workers > 1`; in tests always use 1 worker.
- A `json?` argument that may be a list **or a single string**: after `arg.take(at, upto)` a lone JSON string already sits in `arg.buf` without its quotes, and `arg.strings(arg.buf, 0, arg.n)` then returns `-1`. **Right:** `arg.strings(arg.raw, 0, upto - at)` on the raw copy (which understands a list, a string containing a list, and a bare string). `arg.buf` is for a string that contains an object (`arg.object`).
- Copying a text value out of `kv.find`/`kv.first` raw (`dd.settext(dst, b[kv.vat..kv.vend - 1], ...)`) → the value keeps its **quotes** (`"dryer"` instead of `dryer`) and every comparison after that fails silently: no compile error, no runtime error, the code just does nothing. **Right:** the body is `[kv.vat + 1, kv.vend - 1)` and the escapes have to go: `n := json.unescape(b, kv.vat + 1, kv.vend - 1, dst, 0);` (as in `ctx.wz:136`, `residents.wz:74`). `wantzellog.py check` catches this now. (11-09-2026)
- `http.header("Accept")` with capitals → finds **nothing, ever**. `http.hdreq` lowercases the bytes from the buffer but compares against the literal exactly as written. No error, no warning: you get `false` and the code concludes the header is absent. **Right:** `http.header("accept")`, `"cookie"`, `"x-forwarded-proto"` — always lowercase. (11-09-2026)
- `kv.isobject`, `kv.match` and `kv.scanobj` move the cursor `kv.vat`/`kv.vend` (to the last pair of the object they walk). So after `kv.find`, save `iat := kv.vat; iend := kv.vend` before doing such a check and before calling `kv.merge`/`kv.put` (batch submit of configurable values, 10-09).
- `arg.take` unwraps a JSON string; `arg.strings(arg.buf, 0, arg.n)` afterwards sees a single string (`"key"`) as bare text and returns -1. For "a list, a string containing a list, or a single string", copy the raw view bytes (`arg.byte`) and run `arg.strings` on those; it unwraps a string-with-a-list itself.
- `time.parseiso` accepts only `YYYY-MM-DDTHH:MM:SS[.frac][Z]`: no date without a time and no `+HH:MM` offset (Python's `isoformat()` produces `+00:00`). Pad the date with `T00:00:00`, and strip the offset and apply it yourself.

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

## Spec versus compiler (findings)

- `and`/`or` are short-circuit (the spec said otherwise at first; corrected).
- Identifiers are case-insensitive (the spec first said case-sensitive; corrected).
- After every routine, `nloc` must be 0; a compiler bug here produced "stale locals" in constant expressions (fixed; regression test `tests/compiler/for_const.wz`).


---

# Patterns

Everything below compiles with the current `wantzel`. Take the nearest
pattern and adapt it; do not invent your own variant of something listed here.

## Program skeleton with an include

```pascal
program prog;
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
schema AddArgs = record a: int "left"; b: int "right"; end;
schema AddResult = record sum: int; end;
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
program t;
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
