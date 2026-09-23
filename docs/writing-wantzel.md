# Writing Wantzel

**Common mistakes when writing Wantzel, and the idioms that avoid them.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

For anyone writing Wantzel source, especially an AI agent generating it — most mistakes
below produce a compiler message, and this page maps each one back to its fix. Nearly every
mistake comes from one of four places: Pascal or C habits the language does not have, the
shared case-insensitive namespace, a wrong assumption about a library routine, or a test
expectation that was never checked. The specification is [language.md](language.md); where
the two differ, the specification wins and the difference is a finding.

## Pitfalls

Each row: what's wrong, what's right, the message that identifies it. Found a new one? Add
it under the heading it belongs to.

### Namespace (one shared, case-insensitive namespace)

| Wrong | Right | Message |
|---|---|---|
| `const STORE.SET = 1;` next to `procedure store.set` | Give constants a name no routine has: `STORE.OPSET`, `CURVE.NDAYS`, `HTTP.GET` | `name already used by a variable or constant` / `duplicate global declaration` |
| Parameter `N` next to global `n`; type `Out` next to variable `out` | One name per concept; local names that don't collide with globals (`cnt`, `res`) | `name already used by a type` / `duplicate declaration` |
| A builtin as a name: `procedure f(len: int)`, `var len: int` | Use `n`, `count`, `nbytes` instead. Builtins: `len addr view scan ord chr real trunc round sqrt pack32 unpack32 slen schar sadr band bor bxor bnot shl shr argc argch halt sys1..sys6 winapi` | `that name is built in` |
| `tools` as a namespace (`tools.list`) | `tool.list`, `tool.run` — `tools` is a keyword | `variable name expected` |
| A type name is also an ordinary identifier: `schema Point` and `var point: ...` collide | `var p: Point` | — |
| Assuming `mcp.buf` and `mcp.Buf` differ, or that `a.b` scopes to a module | Dotted names are cosmetic; there is no module scope | — |
| Two files each claiming a `run.*` prefix | Grep for a prefix across everything the program can include before claiming it; rename the newer file | `duplicate global declaration`, only where both files are included together |
| `if argc < 2` (builtin without brackets) | `argc()` — every builtin used as a value needs its `()`  | `missing ( after builtin` |

**A prefix is claimed globally**, so two files that each build a `run.*` namespace collide
on the first variable of the second one — and only in a program that includes both, so each
file compiles alone and the pair does not.

### Types

| Wrong | Right | Message |
|---|---|---|
| `x / 2` on ints | `x div 2` — `/` is for `real` only | `/ divides reals; use div for integers` |
| `r := i` with `r: real`, `i: int` | `r := real(i)`; back with `trunc(r)` (toward zero) or `round(r)` | `type error in assignment: expected real, found int` |
| `ord(b)` on a bool | `if b then x := 1 else x := 0` | `type error in ord: expected char` |
| `if n then` (int as condition) | `if n <> 0 then` — does not exist otherwise | — |
| `s = "abc"` | `json.eq(b, at, last, "abc")` (`last` exclusive), `hash.same`, or your own loop | `strings cannot be compared with = or <>` |
| Treating `str` as a general text type | `str` is only a literal's type. Text as a value is `array of char` plus a length; use `array of char` in new code — it accepts a literal, an array, a slice and a view | — |
| Expecting a 32-bit real, `byte`, `boolean`, `integer` | Only `int char bool real str` and `array` exist | — |
| `writeln`/`write` | `io.puts(fd, "..")`, `io.putn(fd, v)` for an int; a real via `json.putreal` into a buffer | `undeclared identifier` on the whole line — check the **outermost** call first |
| `1.` or `.5` as literals | `1.0`, `0.5`. A negative real literal in a `const` is fine (`NEG = -2.5`) | — |

A smoke test that prints nothing compiles fine and proves nothing about output.

### Arrays, slices, view, records

| Wrong | Right | Message |
|---|---|---|
| A slice as a value: `x := a[1..3]` | Slices and `view(addr, n)` only where an `array of T` argument goes | `a slice can only be passed as an array argument` |
| `addr(s[0])` on an empty slice or view | Guard with `if len(s) > 0` first; for an empty range pass `addr(buf[at])` of the source buffer | runtime `array index out of range` |
| Treating slices as exclusive | Slices are **inclusive**: `a[lo..hi]` has `hi - lo + 1` elements, `a[3..2]` is empty. A `(at, upto)` exclusive pair becomes `b[at..upto - 1]` | — |
| A record as a parameter: `function f(p: Point)` | `procedure f(p: array of Point)`, use `p[0]`; pass the record variable, `items[i..i]`, or `view(address, 1)` | `this parameter needs an array` / `type expected` |
| Copying a record field by field in a loop | `a := b` copies the whole record (same type required) | `record types differ in assignment` otherwise |
| Wanting `array of array`, a record in a `const`, or in an expression | None of these exist | — |
| An empty `array of T` literal | Pass an empty slice: `a[0..-1]` (or `a[i..i-1]`) | — |

Other facts worth knowing: a builtin or keyword name is allowed inside a dotted name
(`addr.x`, `co.for`, `app.type` are ordinary identifiers). `len(a)` works on array names and
`array of T` parameters, not on `str` (that's `slen`) or a constant. `array[lo..hi]` indexing
starts at `lo`, which may be nonzero; all arrays are fixed — "growing" means keeping a
counter ([language.md](language.md) §10b). Large arrays belong at **global** scope; a local
array of megabytes sits on the ~8 MB stack and crashes.

### Routines

| Wrong | Right | Message |
|---|---|---|
| `store.set(...)` as a statement, throwing away the result | `ok := store.set(...)`; or make it a `procedure` | `the value of this function call is not used` |
| A `function` missing `return` on some path (including after `while true`) | Every path ends in `return` | runtime `function without return` |
| A `procedure` with `return value` | `return;` with no value only | error |
| Wanting a `var` parameter | Results write back through an `array of T` argument (a view onto caller storage) or a global — there is no `var` parameter | — |
| More than ten argument slots (an array counts as two) | Count slots before writing the signature; pass a slice as the write target, or make repeated arguments state (`q.clear`, `q.setX(...)`, then a no-arg call) | `wrong number of arguments` / `too many arguments in call` |
| A missing callback: library declares `procedure app.request; forward;`, application never defines it | Define it; signature must match exactly | `forward declared routine is never defined` / `parameter type differs from the forward declaration` |
| Nested routines, function pointers, default arguments, overloading | None exist | — |
| `return` in the main program | `halt(code)` instead | — |

Counting argument slots is the second most common mistake overall.

### Syntax

| Wrong | Right | Message |
|---|---|---|
| `;` before `else` | `if c then a else b;` | `unexpected else (no ';' may precede it)` |
| `var` after `begin`, or any block out of order | Header `;`, then `const`/`var` blocks, then `begin ... end;` | `missing begin in routine body` |
| Anything after `end.` | A program ends `end.` (period); a routine ends `end;` | `text after the end of the program` |
| `{ }` or `(* *)` comments | `//` only, to end of line. A `{` outside a string is refused | — |
| A block comment spanning a JSON literal like `{"a":1}` | Write multi-line comments as several `//` lines (block comments were removed 15-09-2026: they ended at the *first* `}`) | — |
| `'\xHH'` with the wrong digit count | Exactly two hex digits: `'\x1b'`, `"caf\xc3\xa9"`. `"\x41BC"` is three characters, unlike C | `unknown escape sequence` |
| `$FF`, `1_000` | `0xFF` only — no Pascal `$`, no digit separators | — |

Valid escapes: `'\n' '\t' '\r' '\0' '\\' '\''`, `"\""`, `'\xHH'`.

**An `else` binds to the nearest unclosed `if`.** In an if-chain, an arm whose body is
itself an `if` *without* its own `else` swallows everything after it, silently — the result
is valid code that means something else:

```pascal
if k = 1 then
  if v > 0 then out := 1        // still open...
else if k = 2 then out := 2     // ...so this else belongs to the INNER if
```

Here `k = 2` and `k = 3` never run, and `k = 1` with `v <= 0` runs the last arm. **Right:**
wrap the inner `if` in `begin ... end`. Check for this after rewriting a `case` into a
chain — every shape, with its output, is in `tests/lang/if_shapes.wz`. When a chain is
written by a generator, each arm must close bare with only the last carrying `;`, or the
emitted code trips this same rule.

### Includes and standalone tests

Calling a routine from another file your own file doesn't include gives `undeclared
identifier`, but **only in the standalone test** — the main program includes everything, so
it compiles there; a standalone test includes a handful of files and falls over on a call
that lives elsewhere.

**Right:** prefer a local variant with the same signature if one exists; when adding a
helper, check the includes of standalone tests for that file first:
`grep -l 'src/<file>.wz' tests/**/*.wz`.

### Library (wrong assumptions)

| Wrong | Right |
|---|---|
| `sha256.hex(dst, src)` on 16 bytes | It expects exactly 32; use your own hex routine (`oauth.hex16`) for 16 |
| `io.puts(fd, s: str)` on a buffer | `io.puts` takes only a literal; use `io.out(fd, addr(b[0]), n)` for a buffer |
| `n := io.out(...)` | `io.out` is a procedure, not a function (`a procedure has no value`); call `io.out(fd, addr(b[0]), n);` as a statement, or `sys3(SYS.write, ...)` directly if you need the count |
| Assuming `io.push`/`io.pushnum` return a byte count | They return the **new position** |
| `json.eq(b, i, i+16, "\"total_matched\"")` | The literal's length *including its quotes* is 15, so the end is `i + 15` — count it (`printf '%s' '"..."' \| wc -c`), don't estimate. Fails silently: no error, the branch just never runs |
| `json.unescape(...)` without checking `len(dst)` | It does not check for you — guard the length yourself |
| Hand-computing a record size (`ISIZE = 16 + 8 + ...`) | Measure it: `addr(items[1]) - addr(items[0])`, or `addr(last_field) - addr(first_field) + size` |
| `CURVE.DAYS` | The constants are `CURVE.NDAYS`, `CURVE.NHOURS`, `CURVE.DAYLEN` — `CURVE.DAYS` collides with `curve.days` |
| Putting unescaped bytes into a `text` field of an output schema | `Out.write` places a `text` view between quotes **raw** — fill it via `json.escslice` (escaped text) or `json.putraw` (only for already-valid JSON) |
| Forgetting `include "io.wz";` | Since 15-09-2026 the compiler names the file: `undeclared identifier: io.puts is declared in io.wz; add: include "io.wz";`. A bare message means the name is in no library — check spelling |
| Assuming a `str` variable behaves like `array of char` | Only a literal converts implicitly; copy first: `k := io.push(buf, 0, s); ... buf[0..k-1]` |
| Calling `parse` on a schema and ignoring what it dropped | An undeclared key is skipped and counted in `json.ignoredn`, `b[json.ignored0..json.ignored1)` gives the first one. Report it — `lib/tools.wz` does (`_meta.ignoredFields`, `X-Ignored-Field`/`X-Ignored-Count`). A key the schema *does* declare is still strict: a bad value gives `-1`, `json.badkey0..json.badkey1` names it |
| Copying a value out of `kv.find`/`kv.first` raw | The value keeps its quotes (`"dryer"` not `dryer`) and every comparison after fails silently. Use `kv.text(b, dst, 0)` — strips quotes, decodes escapes, returns `-1` if not a string |
| `http.header("Accept")` expecting case sensitivity | Fixed 15-09-2026: comparison is case-insensitive both sides. On an older compiler, use lower case |
| Calling `kv.isobject`/`kv.count`/`kv.match` and assuming the cursor moves | Since 15-09-2026 those three only ask a question and restore the cursor; `kv.scanobj`/`pair`/`first`/`next`/`find` still **position** it — save what you need first |
| `arg.strings(arg.buf, 0, arg.n)` after `arg.take` on a list-or-string argument | `arg.take` unwraps a bare string, so `arg.buf` then looks like plain text. Run `arg.strings` on `arg.raw` instead — it handles a list, a string containing a list, and a bare string |
| `time.parseiso` — checking the return value for failure | Failure is reported through `time.ok`, not the return: `-1` is ambiguous with one second before the epoch. See [`library.md`](library.md) for accepted shapes |

**Two contracts for "it does not fit."** The `lib/` appenders (`io.push`, `io.pushnum`,
`json.putraw`, `json.putstr`, `json.escslice`, `json.putreal`) **truncate** at `len(dst)` and
hand back a usable position — a shortened message is still a message. A generated
`<Schema>.write`, `json.putslice` and `json.putb` **refuse** with `-1` — a shortened JSON
object is a syntax error, not a smaller object. Always test `Out.write`'s result; never
assume a chain of `io.push` wrote everything without comparing positions.

**Names collide across the constant/routine namespace, case-insensitively**: `STORE.SET`
and `store.set` are the same name. Since 15-09-2026 the compiler says so
(`duplicate declaration; names are case-insensitive, so STORE.SET is the same name as
store.set`) — pick a prefix that isn't already a routine's rather than a spelling that
happens to slip past.

`lib/tools.wz` includes `http.wz` (for `tool.rest`), so a program including it must define
`procedure app.request`, or get `forward declared routine is never defined` on the last
line. A stdio-only MCP server includes `lib/toolsmcp.wz` instead — the MCP half without
HTTP, needing no `app.request`.

### Working copies (one global record per entity)

- **Never pass a field of the working copy into a routine that reloads that working copy.**
  `uc.winner(dd.k.curve_ref)` reloads `dd.k` while scanning: the slice ends up pointing at
  changed content, with no error and a partly-correct result. Copy the value into your own
  buffer first.
- A `profile.load(other)` mid-edit overwrites your changes — directly, or indirectly through
  a scan helper (`ctx.default`, `ctx.owns`, `ctx.selectall`) that touches `dd.*`. **Rule:**
  new scan/search helpers use their own copy, never `dd.*`; a handler loads what it writes
  out itself rather than trusting what a helper left behind; handle other rows first, then
  load/change/save your own.

### Syscalls and memory

| Wrong | Right |
|---|---|
| `sys3(SYS.open, addr(path[0]), flags, mode)` without a terminator | The path must be null-terminated: `path[n] := chr(0)` |
| Combining open flags with `+` or `or` | `bor(bor(O_WRONLY, O_CREAT), O_TRUNC)` |
| Expecting `peek8`/`peekreal` | They don't exist — `peek(a)` reads one byte. Read an int or real via a typed one-element view: `f(view(a + off, 1))` |
| Ignoring `mmap`'s return | Negative means failure (`-errno`); check `p < 0` |
| Treating addresses as needing alignment | Ordinary `int`s; `view(p + offset, n)` reads through them — a `char` view is bytes, an `int` view is 8 bytes/element |

Everything is static: no `new`, no recursive structures through pointers — use array
indices instead ([language.md](language.md) §10b).

### Tests (wztest)

- A `.out` must match **exactly**, including runtime error line numbers and the final
  newline. Work out values with Python; count lines with `wc -l`.
- `.err` tests match on message text; the line number must match the source.
- Network tests derive the port from `$$`, poll until the server answers, and clean up the
  background process with a `trap` — this suite has no port-lease helper, that's application
  tooling.
- The Bash tool sometimes refuses heredocs with control characters in a `.sh`; use Write or
  `printf` instead.
- A function called with `$(...)` runs in a subshell: variables it sets are gone when it
  returns. Pass state through a file, or have it print nothing and set the variable directly.
- `wztest` runs `.sh` tests with **dash**, not bash: no `10#`, no arrays, no `[[ ]]`, no
  `${var//x/y}`.
- A leading zero from `date`/`cut` in shell arithmetic (`099`) is invalid octal, at random.
  Put a digit in front (`1$(...)`) or use `10#` in bash.
- A test that measures time is a benchmark (`tests/bench/`, `--bench` only); pair it with a
  `.min`/`.max` to turn it into a hard limit.
- `progs/` directories hold helper programs, not tests.
- No ticket number in a test header — which tests belong to a ticket lives in the ticket's
  `tests:` field. Open with a line saying what the test guards instead.

### A wrong result that looks like a choice

Most pitfalls above announce themselves: a compile error, a crash, a wrong number. The
expensive ones don't — they produce output that's *plausible*, and a plausible result
invites tuning instead of debugging.

- **If you change an input and the output doesn't change, you're tuning the wrong
  variable.** Two rounds of this means stop adjusting and start measuring.
- **Measure the data, not the rendering.** Print the actual values — maxima, counts,
  ranges — rather than judging the picture.
- **Know the healthy range before you look.** State the expected bound first, then measure.
- **Suspect off-by-a-factor before off-by-a-pixel.** A value at 1/8th or 1/64th of what it
  should be points at an early exit or a mismatched divisor, not a slightly-off formula.

A loop that counts and a divisor that disagree is the classic source:

```
// WRONG: break leaves the inner loop, so hits can never exceed n --
// yet the divisor is still n * n. Everything comes out at 1/n of its true value.
for i := 0 to n - 1 do
  for j := 0 to n - 1 do
    if inside(i, j) then begin hits := hits + 1; break; end;
value := hits * 255 div (n * n);
```

The result was *usable*, just uniformly wrong — nothing ever flagged it. Remove the early
exit.

### Spec versus compiler (findings)

- `and`/`or` are short-circuit (the spec said otherwise at first; corrected).
- Identifiers are case-insensitive (the spec first said case-sensitive; corrected).
- After every routine, `nloc` must be 0; a compiler bug here produced stale locals in
  constant expressions (fixed; regression test `tests/compiler/for_const.wz`).

---

## Patterns

Everything below compiles with the current `wantzel`. Take the nearest pattern and adapt
it; don't invent a variant of something listed here.

### The argument order of the routines you use most

30 of 100 recorded mistakes are library use — a wrong name, or arguments in the wrong
order. Two shapes cover almost all of it.

**Appenders — `(buffer, at, what)`, returning the new position:**

| | |
|---|---|
| `io.push(b, at, s)` | a string literal, returns the new `at` |
| `io.pushnum(b, at, v)` | a number |
| `json.putstr(dst, at, s)` | a literal, quoted and escaped |
| `json.putslice(dst, at, src, from, upto)` | bytes from another buffer, quoted and escaped |
| `json.putraw(dst, at, src, from, upto)` | bytes verbatim, no quotes |
| `json.putreal(dst, at, v)` | a real |
| `json.putb(dst, at, c)` | one byte |
| `kv.text(b, dst, at)` | the cursor's value, decoded — source first, then dst |

```pascal
n := io.push(buf, 0, "{\"name\":");
n := json.putstr(buf, n, "probe");
n := io.push(buf, n, "}");
```

**Readers — `(buffer, at, upto)`, `upto` exclusive:**

| | |
|---|---|
| `json.ws(b, at, last)` | skip whitespace, first non-blank position |
| `json.skip(b, at, last)` | past one whole value |
| `json.string(b, at, last)` | past a string; text is `b[json.sat..json.send)` |
| `json.eq(b, at, last, s)` | exact match — count the literal including its quotes |
| `kv.find(b, at, upto, key)` | key as `array of char`, not `str` |
| `kv.first(b, at, upto)` / `kv.next(b, cur, upto)` | walk an object |

### What each routine gives you on failure

| kind | on failure | why |
|---|---|---|
| appenders in `lib/` (`io.push`, `json.put*`) | truncate at `len(dst)`, return a usable position | a shortened message is still a message |
| generated `<Schema>.write`, `json.putslice`, `json.putb` | `-1`, nothing usable written | half a JSON object is a syntax error |
| parsers (`json.skip`, `json.string`, `kv.pair`) | `-1` | no position to continue from |
| questions (`kv.find`, `json.eq`, `fs.stat`) | `false` | |
| generated `<Schema>.parse` | `-1`, offending key in `json.badkey0..json.badkey1` | a missing/bad field; an *unknown* key is not a failure — see `json.ignoredn` |
| `kv.text` | `-1` | not a string, or doesn't fit |

Always test the result of `write` and anything returning `-1`.

### A buffer and its length, together

```pascal
var
  buf: array[0..1023] of char;
  buf_n: int;                      // how much of buf is filled

buf_n := io.push(buf, 0, "text");
if buf_n >= len(buf) then ...      // it truncated: the position hit the end
```

Pass the filled part as a slice, `use(buf[0..buf_n-1])` — passing `buf` hands over 1024
bytes of mostly zero, and the receiver can't tell where the text stops.

### A whole command-line tool

The usage line, the argument copied out with its length guarded, the failing `open`
reported, and a distinct exit code for "you used it wrong" (2) versus "it did not work" (1)
— nothing here is spare.

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

### A whole MCP server

**Do not build `tools/list` or a call reply by hand with `mcp.add`.** The `tools` block
([language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration)) generates the tool
table, JSON Schemas, argument parsing, dispatch and result writers from one declared line
per tool; only the handler is left to write. Two lines are easy to leave out and neither is
optional:

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

include "toolsmcp.wz";                  // AFTER the tools block: it reads it

function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;
end;

begin
  mcp.stdio;
end.
```

That answers `initialize`, `tools/list` and `tools/call` on stdin; `mcp.name`/`mcp.version`
are yours to set. To also serve the same table over HTTP, include `lib/tools.wz` (adds
`tool.rest`, brings in `lib/http.wz`) and `lib/mcphttp.wz`, define `procedure app.request`,
and call `http.serve(port, 1)`; `examples/mcptools.wz` does both.

### Program skeleton with an include

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

### Command-line arguments

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

### Building text and writing it out

```pascal
n := io.push(buf, 0, "item");         // returns the new position
n := io.pushnum(buf, n, 42);
buf[n] := chr(0);                     // only needed for syscalls (paths)
io.out(STDOUT, addr(buf[0]), n);      // buffer; io.puts is for literals only
```

Comparing text: `json.eq(buf, at, upto, "literal")` (upto exclusive). Passing text along:
`f(buf[0..n-1])`; inside `f(s: array of char)`, `len(s)` is the length.

### Passing and storing records

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

### A list of unknown length (without a heap)

```pascal
var xs: array[0..9999] of int; nxs: int;      // capacity + counter
function push(v: int): bool;
begin
  if nxs >= len(xs) then return false;
  xs[nxs] := v; nxs := nxs + 1; return true;
end;
```

Declare large buffers globally; use a `view` on `mmap` memory to grow beyond that
([language.md](language.md) §10b).

### Linked structures without pointers: the index IS the pointer

There are no pointers, and for data you don't need them. Where C keeps an address, keep the
**index** of the element instead, with `-1` for "none". An index can't dangle, is
bounds-checked at every use, and still means the same thing after a write-to-disk and
read-back.

One array holds every node, a counter says how many are live, every link is an `int` index:

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

**Doubly-linked list, with removal from the middle:**

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

**A tree, and a graph with cycles** — same record with `left`/`right`, or an edge array. An
index can't point at freed memory, so the "use after free" that makes cycles dangerous
elsewhere can't happen; just guard the walk against revisiting:

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

**Reuse: a free list, not an allocator.** Removing a node doesn't free memory — nothing was
allocated. Keep freed indexes in a list of their own (`lib/store.wz` does this with
`store.free`).

**It survives a restart**: because a link is an index, the whole array is its own file
format — write the raw bytes, read them back, every link still points where it did:

```pascal
fd := sys3(SYS.open, addr(path[0]), 577, 420);        // O_WRONLY|O_CREAT|O_TRUNC
n  := sys3(SYS.write, fd, addr(nodes[0]), nn * 24);   // 24 = the record's size
sys1(SYS.close, fd);
```

**What an index doesn't protect against:** it can point at the *wrong* row. A zeroed link
field means index 0, not "none" — initialise links to `-1` explicitly, or a node becomes its
own child and a walk recurses until the stack runs out. The compiler can't see this.

### Reaching memory the program never declared

`view(addr, n)` turns any address plus a length into an ordinary, bounds-checked array —
the escape hatch for OS memory, a shared segment, a mapped file:

```pascal
base := sys6(SYS.mmap, 0, 4096, bor(PROT_READ, PROT_WRITE),
             bor(MAP_PRIVATE, MAP_ANONYMOUS), -1, 0);
fill(view(base, 4096));                       // an ordinary array of char
fill(view(base + 10, 100));                   // a window at an offset
sys2(SYS.munmap, base, 4096);
```

`view` and `sys*` are the unsafe primitives — nothing verifies the address and length are
right. Everything *inside* the view is as safe as any other array.

### List arguments (a small `arg.*` layer on top of json)

```pascal
if not arg.take(a[0].keys_at, a[0].keys_end) then return tool.fail("keys: malformed");
n := arg.strings(arg.raw, 0, a[0].keys_end - a[0].keys_at);   // on the RAW view, not arg.buf
```

`arg.take` strips quotes off a bare string; `arg.strings` still needs to see quotes to
recognise `"abc"` as one item. On an object already copied elsewhere (say `ctx.pbuf`), the
value is still raw: `arg.strings(ctx.pbuf, kv.vat, kv.vend)` directly.

### info filters (lib/kv.wz): which side decides

`kv.match(obj, .., filter, ..)`: every filter key must exist in `obj`; per key, the
**stored** side decides the rule.

| stored value | filter value | rule |
|---|---|---|
| not a list | a list | membership: stored value equals one element |
| a list | anything | containment: stored list holds the filter value, or all of a filter list |
| not a list | not a list | equality (`kv.same`) |

So `{"tags":"a"}` matches a stored `["a","b"]`, and a stored list contains itself. An empty
**filter** list against a non-list stored value matches nothing; against a stored list it
matches everything (containment of nothing is vacuous). `kv.contains`/`kv.haselem` are the
containment half standalone.

### Ten argument slots: an array counts double

Three arrays (6 slots) leave room for four scalars. A routine with three buffers plus
`(from, upto) × 2` plus a write position doesn't fit — drop the write position, pass a
slice: `n := kv.merge(b, 0, bn, p, 0, pn, out[at..len(out)-1])`.

### Returning a scalar result without a var parameter

```pascal
procedure co.schedule(...; n: array of int);   // n[0] becomes the count
var cnt: array[0..0] of int;
...
  co.schedule(..., cnt); k := cnt[0];
```

Several results: one record through `array of R`, or one `array of int` with fixed
positions.

### Writing a file and mapping it

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

### HTTP handler (lib/http.wz + router)

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

### Schema + tools (MCP/REST without the handwork)

The `tools` block is the way to expose tools — never build `tools/list` or a call reply by
hand with `mcp.add`. See [language.md §7b](language.md#7b-tools--a-tool-table-as-a-declaration)
for the full anatomy; "A whole MCP server" above has a complete, runnable program. Shortest
form, for reference:

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

### Test program (wztest, `.wz` + `.out`)

```pascal
// What the test demonstrates, in one sentence.
include "../../../lib/x.wz";
procedure show(s: str; v: int); begin io.puts(STDOUT, s); io.putn(STDOUT, v); io.puts(STDOUT, "\n"); end;
begin
  show("a = ", f(1));
end.
```

Work out expected output with Python and record it with
`./wztest --update tests/path/t.wz` **only** after verifying the values independently.

### Shell test (`.sh`)

`tests/helpers.sh` is deliberately small: `compile`, `assert_eq`, `assert_contains`, nothing
more. The suite tests the language and compiler, not an application — no server startup, no
port lease helper. A program that needs a port derives it from `$$` and cleans up its own
background process.

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

**Always clean up with a `trap`.** A test that leaves its server running occupies a port and
makes the *next* test fail for an unrelated reason. A `wait` after `kill` avoids a zombie.

### A list argument (json?) in a tool: arg.strings on the raw view

`arg.take(at, upto)` already unwraps a JSON string: `"child"` becomes `child` in `arg.buf`,
and `arg.strings(arg.buf, 0, arg.n)` then sees no `"` or `[` and returns -1. Parse lists on
`arg.raw` instead: `arg.take(at, upto); n := arg.strings(arg.raw, 0, upto - at)` — covers a
list, a JSON string containing a list, and a single string.

### Reading an int or a real at a raw address

`peek(a)` is the only read builtin and yields one byte; `peek8`/`peekreal` don't exist. Read
eight bytes with a typed view of one element:

```pascal
function db.geti(a: array of int): int; begin return a[0]; end;
function db.getr(a: array of real): real; begin return a[0]; end;
...
  v := db.geti(view(address + offset, 1));      // an int
  x := db.getr(view(address + offset, 1));      // a real
```

The parameter's type decides what the view reads, not the call site. Measure byte offsets
in a record with `addr(rec.field) - addr(rec.first)`, never by hand.

---

## From an error message to its cause

The compiler's messages are terse and sometimes point at generated code instead of your own
line. Fastest route from symptom to cause; add to it whenever you lose an hour to something
not listed here.

### The message points at a file you did not write

For example `wantzel: <unitref>:45: undeclared identifier`, or a line deep inside
`refdata.wz` — that's **generated** code (a schema, the `tools` block, the Windows runtime).

| Symptom | Cause | Fix |
|---|---|---|
| `undeclared identifier` in `<schemaname>` | the library the generator uses isn't included | `include "lib/json.wz";` **before** the schemas — a schema parser calls `json.*` |
| `name already used by a type` in generated code | a global shares a name with a schema **field** | rename your global; fields share the namespace inside generated routines |
| `forward declared routine is never defined` on the last line | a library-required `app.*` hook is missing | search library headers for `forward` (`app.request`, `app.tools`, `app.authenticate`) |

**Fast diagnosis:** don't look at the line number, look at the **name in angle brackets** —
that's the schema or tool. Work out which library the generator needs (usually stated in the
file's header) and whether a global shares a name with one of its fields.

### `undeclared identifier` on your own line

| Symptom | Cause | Fix |
|---|---|---|
| the name exists, further down the same file | a routine must appear before its caller | move it up, or declare it `forward` |
| the name is in another `src/` file | include order | move that file's include earlier |

Quickest check: `grep -n "function <name>\|procedure <name>" src/*.wz lib/*.wz`. If it's
there, the problem is order, not spelling.

### Runtime, not compile time

| Symptom | Cause | Fix |
|---|---|---|
| `array index out of range` in generated data | a buffer sized too small for what's written into it | the generator computes the size — count in anything you added |
| an answer is half right (one group instead of two) | aliasing: a working-copy field passed into a routine that reloads that same working copy | copy the value into your own buffer first |
| a test passes alone but fails in the suite | a port clash or shared state | give every test its own port/directory (from the process id) and clean up; otherwise look for a shared global or file two tests both write |
| empty slice, `addr(s[0])` blows up | `n = 0` | guard with `if n > 0` before `addr` |

### Before you compile

1. **Count the argument slots.** Ten is the maximum, an array counts as two — four text
   buffers plus a scalar is already twelve. Make search keys state with setters (see
   `ref.q.*`) instead of parameters.
2. Check whether a name already exists: `grep -rn "\bname\b" lib/ src/` — the namespace is
   shared, case-insensitive, and includes schema **fields**.

The costliest mistakes are namespace and ordering errors, and cost time because the message
points at generated code. "What name is in the angle brackets?" gets you there in one step.
