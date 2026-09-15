# Wantzel — language specification

This is the living reference of what the compiler (and `bootstrap/boot.c`) supports
**today**. Everything written here is tested in `test.sh` or `tests/`. Planned extensions
are kept separately in §9 and are only valid once they move here. Whoever implements
something reads this file first; whoever changes the language updates this file in the same
commit.

Last updated: 2026-09-15 (phase 1 complete: real, record, slices, view, for, local const, schema v2, tools).

## The language in brief

A tour before the specification: what Wantzel is and why. Everything here is stated precisely
in the numbered sections that follow; where the two seem to differ, the numbered section
is the one that binds.

```pascal
include "lib/json.wz";

const MAX = 100;

var
  table: array[1..MAX] of int;
  i, total: int;

function square(n: int): int;
begin
  return n * n;
end;

// works on any char array, with a bounds check against the length passed in
function fill(b: array of char; c: char): int;
var k: int;
begin
  k := 0;
  while k < len(b) do
  begin
    b[k] := c;
    k := k + 1;
  end;
  return len(b);
end;

begin
  i := 1;
  while i <= MAX do
  begin
    table[i] := square(i);
    total := total + table[i];
    i := i + 1;
  end;
end.
```

### Types, in brief

`int` (64-bit), `real` (64-bit IEEE), `char` (0..255), `bool`, `str` (literals),
`array[lo..hi] of T` and `record`. No implicit conversions: `ord()`/`chr()` are required,
an `int` is not a condition, and `and`/`or`/`not` work only on `bool` (bits go through
`band`/`bor`/`bxor`/`bnot`). No pointers and no pointer arithmetic — all indirection goes
through arrays whose bounds the compiler knows.

Routines take up to ten arguments; an `array of T` parameter counts as two (address and
length) and keeps its bounds check.

### Safety, in brief

What the compiler enforces while translating: declarations are mandatory, a `forward` has
to be fulfilled, signatures are compared, a function result may not be discarded, and a
`procedure` may not return a value.

What is in the generated code, with file name and line number:

```
runtime error: array index out of range at examples/httpd.wz:42
```

* every array index against both bounds (three instructions: `sub`/`cmp`/`ja`);
* division and `mod` by zero;
* `chr()` outside 0..255, `schar()` and `scan()` outside the string or array;
* a `function` that ends without a `return`;
* local variables and arrays are zeroed on every call — no undefined initial values.

Not checked: integer overflow, and anything that goes through `addr`/`sysN`.

**Where the boundary actually runs.** That last sentence is the one to read carefully,
because it is the whole of what is *not* guaranteed — and it is easier to get wrong than
it looks. A guard protects you only if it can reach its verdict without first trusting
the value it is inspecting. Every bound above is compared against either a constant known
at compile time or a length held in the call frame, neither of which the caller can
corrupt; that is why they cannot fail on a hostile input. The one case where a bound is
read *from the value itself* is a `str`, whose length sits in the eight bytes before its
text — so an unassigned `str` (address 0, length 0) is the edge worth knowing about, and
`slen` answers 0 for it rather than reading anything.

The practical rule, if you only remember one: **a zeroed variable is a valid value
everywhere** — an `int` is 0, an array is all zeroes, and a `str` is empty. Anything
reached through `addr`, `view` or `sys*` is outside all of this and is checked by nothing.

### Compiled JSON schemas, in brief

This is where a strictly typed compiled language beats a dynamic stack. You describe the
shape of a message, and the compiler makes a record type, a parser, a writer and a JSON
Schema out of it; there is no DOM, no reflection and no allocation:

```pascal
schema Rpc = record
  jsonrpc: text;
  id:      json?;                       // '?' makes the field optional
  method:  text of ("initialize", "tools/list", "tools/call", "ping");
  params:  json?;
end;

var msg: Rpc;
...
if Rpc.parse(buf, 0, n, msg) < 0 then ...      // invalid, or a field is missing
if msg.method = Rpc.method.tools_call then ... // the enum is an integer
if msg.id_ok then ...                          // was the field there?
```

Field types: `int`, `real`, `bool`, `text` (a view into the buffer), `text[N]` (a copy),
`text of (...)`, `json`, arrays of those and nested schemas, each with `?` for optional and
a `"description"` that ends up in `Rpc.jsonschema`. A `tools` block builds a complete MCP
tool table on top of that: `tools/list`, argument parsing, dispatch and `structuredContent`
all come from one declaration (see `examples/mcptools.wz`, and §7b below).

## 0. What kind of language is this?

Small, strictly typed and procedural, with a syntax that reads almost like prose:
`begin`, `end`, `procedure`, `:=`. If you have written Pascal you will read Wantzel
without explanation, but this is not an ISO-7185 or Free Pascal dialect and does not
try to be -- the deviations are deliberate, and §8 lists them.

The design rule is **one clear choice per concept, nothing exotic**. A familiar
spelling is kept where it costs nothing, and where the older languages offer several
ways to say a thing, Wantzel picks one. That is what makes the language predictable
for people *and* for a model that generates code.

## 1. Program

```pascal
include "lib/io.wz";        // textual inclusion, max 16 deep, paths relative to the file

const
  MAX = 100;                // int, char ('a'), bool, real (1.5, -2.5), str ("..."); also inside a routine

var
  i, total: int;            // only global or at the start of a routine
  buf: array[0..1023] of char;

procedure greet;            // routines: see §4
begin
end;

begin                       // main program
  greet;
end.                        // the dot is required
```

Escapes in a `char` or `str` literal: `\n` `\t` `\r` `\0` `\\` `\'` `\"`, and `\xHH`
— **exactly two** hex digits, one byte, upper or lower case. Two and not a variable
number, deliberately: a hex escape that keeps eating digits (as in C) means a generator
cannot write a byte and then a literal hex character without changing what it wrote, so
`"\x41BC"` is three characters here. Anything else after a backslash is refused.

Comments: `// to end of line`, and that is the only form. Identifiers are
**case-insensitive** (`Point` and `point` are the same name, as in
Pascal); keywords too. Identifiers: letters, digits, `_`, and a **dot**
as a namespace separator (`io.puts`, `mcp.buf`): the dot is cosmetic, there
are no modules. The first character must be a letter or `_`; a part **after**
a dot may also start with a digit (`Reading.level.1`), which is what a schema
enum whose value is `"1"` generates. A real literal still reads as one number:
`3.5` is a value, never a name.

## 2. Types

There are exactly five scalar types and one composite type.

| type | meaning | literal |
|---|---|---|
| `int` | 64-bit two's complement | `42`, `-7`, `0xFF` |
| `char` | one byte, 0..255 | `'a'`, `'\n'`, `'\\'`, `'\''`, `'\x41'` |
| `bool` | `true` / `false` | |
| `real` | 64-bit IEEE-754 (what C calls `double` and Python `float`); the only decimal type | `1.5`, `0.25`, `2e-3`, `6.02e23` (a dot or an exponent makes a literal `real`; `1.` and `.5` are not literals) |
| `str` | an **immutable string literal** (address + length); not a value you build up | `"text\n"`, `"caf\xc3\xa9"` |
| `array[lo..hi] of T` | fixed array of `int`, `char`, `bool` or `real`; `lo`/`hi` constant ints; `lo` may be ≠ 0 | |

**No implicit conversions.** `int` ↔ `char` via `ord()`/`chr()`;
`int` → `real` via `real(i)`; `real` → `int` via `trunc(r)` (towards zero) or
`round(r)` (to nearest, halves to even). An `int` is not a
condition. `and`/`or`/`not` work only on `bool`; bits are done with
`band`/`bor`/`bxor`/`bnot`/`shl`/`shr`.

**`real`** computes with `+ - * /` and unary `-`; `/` exists only for
reals (`int` uses `div`), `div`/`mod`/`shl`/`shr` exist only for
ints. Comparison with `= <> < <= > >=`; a NaN is equal to nothing and
orders nowhere. Division by zero gives `inf`/NaN as IEEE prescribes, not a
runtime error. A literal with at most 18 significant digits and an
exponent up to ±22 is rounded correctly; beyond that the last bit may
differ. Constants: `const PI = 3.14159; NEG = -2.5;`. There is no
32-bit type: `pack32(r): int` gives the IEEE single bits (for compact
storage), `unpack32(i): real` gets them back. Text ↔ real is library.

**Text as a value** is always an `array of char` (with `len()` as
length, or a separate `int` for the filled part). A routine that takes text
declares `s: array of char` and can then be given a literal, an array,
a slice or a view (§4). `str` is solely the type of a
literal itself, for the builtins `slen`/`schar`/`sadr` and for existing
library routines; new code does not need it. Strings cannot be
compared with `=`; compare per `char` or with `json.eq`.

### Records

```pascal
type
  Vec = record
    x, y: real;
  end;
  Body = record
    id: int;
    pos, vel: Vec;                     // nested records
    tags: array[0..3] of int;          // arrays in records
    label: array[0..7] of char;
  end;

var
  bodies: array[1..3] of Body;         // arrays of records
  b: Body;
```

- Fields via the dot: `b.pos.x`, `bodies[i].tags[0]`, `bodies[i].pos.y := 1.0`.
- Copying a record as a whole: `b := bodies[2]` (both of the same type).
- A record has no value of its own: it cannot appear in an expression,
  not as a parameter and not as a function result. Pass records as
  `array of T` (a slice of one element is enough, see §4) and let a
  routine fill a record through such an array.
- `addr(b.pos)` and `len(b.tags)` work; `addr(bodies[2]) - addr(bodies[1])`
  is the record size.
- Memory layout: fields are in declaration order; `char`/`bool` fields
  and arrays lie on byte boundaries, everything else on 8 bytes; the total
  size is a multiple of 8. A record may not contain itself.
- `type` appears only at program level, before the routines that use it.
  A type name is an ordinary identifier (case-insensitive) and may not
  coincide with a variable or routine.

There are **no** pointers, sets, enumerations, strings with content, or nested
arrays (`array of array`). See §9.

## 3. Expressions and operators

Precedence from high to low, as in Pascal:

1. `not`, unary `-`
2. `*` `/` `div` `mod` `and` `shl` `shr`
3. `+` `-` `or`
4. `=` `<>` `<` `<=` `>` `>=`

`div` and `mod` are Pascal semantics (truncation towards zero: `-7 div 2 = -3`,
`-7 mod 2 = -1`), with a runtime check on division by zero. `and`/`or` on
`bool` are **short-circuit**: the right-hand side is only evaluated if
the left-hand side does not already determine the result (`false and f()` does not call
`f`). Ordering (`<` etc.) only
on `int`, `char` and `real`. Overflow of `int` is not checked.

## 4. Routines

```pascal
function kwadraat(n: int): int;
begin
  return n * n;             // 'return' with a value; required on every path
end;

procedure vul(b: array of char; c: char; n: int);   // 'array of T' = address + length, with bounds check
var i: int;
begin
  i := 0;
  while i < n do
  begin
    b[i] := c;
    i := i + 1;
  end;
end;

function later(x: int): int; forward;               // declare, define later
```

- Arguments are passed **by value**; an `array of T` parameter is
  a *view* (address + length) and writing into it is visible to the caller.
  There are no `var` parameters: use an array or a global.
- A record variable may appear where `array of <that record>` is
  expected; it arrives as a view of one element (`Point.parse(buf, 0, n, p)`).
- Where an `array of T` is expected, you may give: a whole array
  (`p(buf)`), a **slice** `p(buf[lo..hi])` (inclusive, like a
  declaration; `buf[3..2]` is empty; the bounds are checked), an
  array field of a record (`p(r.tags)`), an element slice of an array
  of records (`p(items[i..i])`, the way to pass one record), a
  **string literal** as `array of char` (`p("text")`), or `view(addr, n)`:
  `n` elements of type `T` at an arbitrary address (for `mmap`, kernel
  buffers, byte reinterpretation). `view` and slices exist only in that
  position; they are not values.
- At most ten arguments; an array counts for two.
- No nested routines, no recursion limit (recursion is allowed).
- `function` must execute `return` on every path (runtime error otherwise);
  `procedure` may not return a value; a function result may not be
  discarded.
- Local variables and arrays are **always zeroed** on entry.
- A routine may have `const` and `var` blocks after the header, in any
  order; local constants have the same forms as global ones.
- Callbacks: declare a routine `forward` in a library and define
  it in the application (`procedure app.request; forward;`). There are no
  function pointers.

## 5. Statements

```pascal
x := e;                              // assignment
p(a, b);  y := f(a);                 // call
if c then s1 else s2;                // no ';' before 'else'
while c do s;
for i := a to b do s;                // i is an ordinary int variable; b is computed once
for i := b downto a do s;
begin s1; s2; end;                   // block
break;  continue;                    // in while/for
return;  return e;
halt(code);                          // terminate the program
```

`for` counts with step 1; after `break` the variable keeps the value it
stopped on, after a complete loop it is one past the end value. There is no
`case`: write an if-chain, and note that an `else` binds to the nearest
unclosed `if`. No `with`, no `goto`.

## 6. Built-in routines

| | meaning |
|---|---|
| `ord(c)`, `chr(i)` | char ↔ int; `chr` checks 0..255 |
| `real(i)`, `trunc(r)`, `round(r)` | int ↔ real |
| `sqrt(r)` | square root (`sqrtsd`) |
| `pack32(r)`, `unpack32(i)` | real ↔ IEEE single bits in an int |
| `len(a)` | number of elements of an array (also of an `array of T` parameter) |
| `addr(a[i])`, `addr(x)` | address as `int`, for syscalls |
| `slen(s)`, `schar(s, i)`, `sadr(s)` | length, i-th byte (checked), address of a `str` |
| `scan(a, from, upto, c)` | index of the first `c` in `a[from..upto)`, or `upto`; SIMD |
| `view(addr, n)` | only as an array argument: `n` elements at address `addr` (§4); the only unsafe primitive besides `sys*` |
| `band bor bxor bnot`, `shl shr` | bits |
| `argc()`, `argch(k, i)` | number of arguments; i-th byte of argument k (`chr(0)` at the end, and `chr(0)` for any `k` or `i` out of range — it answers rather than traps) |
| `halt(code)` | exit |
| `sys1(nr, a)` … `sys6(nr, a..f)` | raw Linux syscall (on Windows translated by the runtime) |

Library routines (`lib/`) are ordinary Wantzel: `io.*`, `net.*`, `http.*`,
`json.*`, `mcp.*`, `fs.*`. See `README.md`.

### The syscall number is the contract

`sys1`..`sys6` are builtins the compiler translates straight to machine code. There is
nothing in between: no wrapper, no error handling, no errno translation. The arguments go
into the registers of the System V convention, and the compiler then emits the two bytes
of the x86-64 `SYSCALL` instruction literally. On Windows a call to a shim stands there
instead; that is the only place the two platforms differ.

The number itself is an ordinary constant — `SYS.fork = 57` and `SYS.wait4 = 61` live in
`lib/io.wz`, and the compiler knows no syscall by name. **Everything the operating system
offers is therefore reachable without touching the language**, which is why a new
capability is a constant plus a call rather than a compiler change, and needs no language
change at all. `fork`, shared memory and `flock` were each called impossible here before someone
looked.

The other side of that: nothing is checked. A wrong number or a wrong argument gives a
negative return value (`-errno`) or, worse, something that appears to work. Like `addr`
and `view`, this is an unsafe primitive: none of the runtime checks apply to it.

## 7. `schema` — compiled JSON

A `schema` describes the shape of a JSON object. The compiler turns it
into, in one go: a **record type** with the same name, `Name.clear`,
`Name.parse`, `Name.write` and the constant `Name.jsonschema`. There is no
DOM and no reflection; the parser reads straight from the input buffer.

```pascal
schema Point = record
  x: real;
  y: real;
  tag: text of ("start", "mid", "end")?;        // enum → int, with constants Point.tag.start ...
end;

schema Path = record
  id:     int              "unique id";         // a description goes along into the JSON Schema
  name:   text[64];                             // text as a copy (unescaped), at most 64 bytes
  note:   text?;                                // text as a view (_at/_end) in the input buffer
  origin: Point;                                // nested schema
  pts:    array[0..99] of Point;                // arrays of int, real, bool, text[N] or schema
  keys:   array[0..15] of text[32];
  meta:   json?;                                // arbitrary value as a view
  kind:   text of ("open", "closed");
end;

var p: Path;                                    // a schema is an ordinary record type
...
r := Path.parse(buf, 0, n, p);                  // position after the object, or -1
if r < 0 then ...
if p.kind = Path.kind.closed then ...
p.pts[i].x                                      // ordinary field access
p.name[0..p.name_n - 1]                         // the text copy as a slice
p.keys[i * 32..i * 32 + p.keys_len[i] - 1]      // element i of a text array
n := Path.write(out, 0, p, buf);                // JSON back from out[0]; the position after the object, or -1 when it does not fit; buf supplies the views
io.puts(STDOUT, Path.jsonschema);               // {"type":"object","properties":{...},"required":[...]}
```

Per field `f` the record contains:

| field declaration | in the record |
|---|---|
| `int`, `real`, `bool`, enum | `f` |
| `text` (view), `json` | `f_at`, `f_end` |
| `text[N]` | `f: array[0..N-1] of char`, `f_n` |
| `array[0..N-1] of T` | `f: array[0..N-1] of T`, `f_n` (number read) |
| `array[0..N-1] of text[M]` | `f: array[0..N*M-1] of char`, `f_len[0..N-1]`, `f_n` |
| nested schema `S` | `f: S` |
| always | `f_ok` (key present), `f_null` (value was `null`) |

Rules: a missing required field (without `?`) makes `parse` return `-1`;
an **unknown key is refused** — `parse` returns `-1` and
`b[json.badkey0..json.badkey1)` is the key it rejected, because `parse` answers `-1` for
every kind of failure and this is the one the caller can fix. A renamed or removed field
used to be skipped in silence, so the call succeeded with the default in place of what
the caller asked for. The consequence is that a schema **must declare everything it may
receive**: for an open protocol envelope (MCP `initialize`, OAuth registration) that means
declaring the members the protocol carries, as `json?` where the value is not read.
`null` sets `f_null` and `f_ok`;
a text that does not fit in `text[N]` or an array with more than `N`
elements gives `-1`; an enum value outside the list gives `-1` in the
field but no error. `write` always writes required fields and optional ones
only if `f_ok` is true; `f_null` writes `null`. `write` returns `-1` when the object
does not fit in `dst` (or when the starting position is negative or past the end) and
writes nothing usable in that case: a short buffer is a **refusal**, not a truncation,
because half a JSON object is not a shorter object but a syntax error. This differs
deliberately from the appenders in `lib/` (`io.push`, `json.putraw`, `json.putstr`),
which truncate at `len(dst)` and hand back a position that is still usable — a
shortened message is still a message. **Test the result of `write`**; a generated
`tool.run` does, and reports the failure to the peer instead of dying on it. A nested schema
must have been declared earlier; a schema name is a type name (so no
variable with the same name). A `json` field in an output record can also
be filled by `Other.write` of another schema in the view buffer:
`r.base_at := tool.vn; tool.vn := Other.write(tool.vbuf, tool.vn, o, tool.vbuf); r.base_end := tool.vn;`
(this is how a tool nests another schema's output inside its own). Descriptions after the type (and after `?`)
appear as `"description"` in the JSON Schema; `text[N]` gets
`maxLength`, arrays `maxItems`.

## 7b. `tools` — a tool table as a declaration

```pascal
tools
  add(AddArgs): AddResult "Add two whole numbers." readonly idempotent;
  greet(GreetArgs): GreetResult "Greet someone.";
end;

include "lib/tools.wz";                      // MCP and REST transport for the table

function tool.add(a: array of AddArgs; r: array of AddResult): int;
begin
  r[0].sum := a[0].a + a[0].b;
  return 0;                                  // 0 = success; otherwise: return tool.fail("message")
end;
```

One `tools ... end;` block per program, after the schemas it uses.
The compiler generates: the constant `tool.list` (the complete
`tools/list` text with `inputSchema`, `outputSchema` and annotations),
`tool.count` and `tool.id_<name>`, per tool the records `tool.in_<name>` and
`tool.out_<name>`, `tool.fail(s)`, `tool.byname(b, at, upto)` and
`tool.run(idx, b, at, upto, dst)` (parses the arguments, calls
`tool.<name>` and writes the result JSON; `-1` on arguments that
do not satisfy the schema, `-2` if the handler failed with `tool.err`,
`-3` when the result JSON does not fit in `dst` — the writer refuses instead of
truncating, and `-3` keeps that apart from `-1`, which would blame the caller's
arguments for a limit on our side).
For `text` and `json` fields (views) in the output schema the compiler
generates the buffer `tool.vbuf` (1 MB) and the fill position `tool.vn`, which is
0 at every call: the handler writes the text into `tool.vbuf` from
`tool.vn` and points `f_at`/`f_end` at it; `tool.run` writes the result with
`tool.vbuf` as the source of the views.
The handlers are declared `forward`, so a missing handler is
a compile error. Annotations: `readonly`, `idempotent`, `destructive`
(all three false by default). `lib/tools.wz` turns that into `app.tools`,
`app.call` (MCP: `content` + `structuredContent` + `isError`) and
`tool.rest(prefix)` (REST: `POST <prefix><name>`, 200/400/405/422).
`tools` is a keyword: do not use it as a namespace in your own code.

## 8. Deliberate deviations from Pascal

| Pascal | Wantzel | why |
|---|---|---|
| `f := value` as the result | `return value` | one way, no implicit result variable |
| `integer`, `longint`, `byte`, `word`, ... | only `int` (64) and `char` (8) | no choice = no mistake |
| `boolean` | `bool` | short |
| `string`, `shortstring`, `ansistring`, `pchar` | `str` (literal) + `array of char` | no hidden allocation |
| `real`, `single`, `double`, `extended` | only `real` (64) | idem |
| `var` parameters | array view or global | no aliasing of scalars |
| `(* *)`, `{ }` | only `//` | a brace inside the comment text ended it early, and the error landed far from its cause |
| `shl`/`shr`/`and`/`or` on ints | `shl`/`shr`, `band`/`bor`/`bxor`/`bnot`; `and`/`or` only on bool | logical and bitwise never confused |
| `exit`, `halt` | `return`, `halt(code)` | |
| units, `uses` | `include` | one mechanism |
| `set`, `with`, `goto`, pointers | absent and not coming | |
| `case` | absent; write an if-chain | a generator chose it once in five where it could |
| variant records, `packed` | absent | one layout, see Records |
| syscalls unreachable | `sys1..sys6`, `addr` | the whole runtime is Wantzel |

## 9. Planned (not yet valid)

**Before 1.0, anything here can still change.** This is a young language: if a construct
turns out to cost more than it gives, it goes, and code that used it will need editing. The
`{ }` block comment was removed on 15 September 2026 for exactly that reason. Plan for it,
and read this section on each release.

That is not licence to churn. **The bar is evidence, not taste** — a proposal resting on
symmetry or familiarity does not clear it, one that can show what a construct costs in
practice does. It is then weighed against the test in [`design.md`](design.md): a change
should remove a *choice* between things that meant the same, never a *distinction*.

After 1.0 this reverses: compatibility is the default and a break needs the stronger case.
What an application still needs meanwhile is library (`lib/`), not language.

One thing has been **removed** since: the `{ }` block comment, on 15 September 2026. It
ended at the first `}`, so a brace inside the comment text — a JSON example, the words
"default {}" — closed it early and the rest of the sentence was compiled as code, with the
error appearing far from its cause on a line that looked correct. Six of seven recorded
syntax errors came from it, including several written after the pitfall was documented.
`//` has no such failure mode. A source that still uses `{ }` is refused with a message
naming the replacement.

What is **not** coming: heap/`new`/`dispose`, pointers, strings with content as a
language type, sets, `with`, `goto`, variants, classes, generics, exceptions,
threads, operator overloading, implicit conversions.

## 10. Runtime errors (always with file:line)

array index out of bounds · division by zero · `chr()` outside 0..255 ·
`schar()`/`scan()` out of range · function without `return` · (Windows and
Linux identical).

## 10b. Memory

There is no heap, no pointers and no garbage collector. The model, in three sentences:

1. **All memory is an array with an upper bound.** A global array
   lives in bss and costs nothing until you touch it: declaring
   `array[0..1073741823] of char` (1 GB) is free, every page you write to
   costs 4 KB. Local arrays live on the stack and are zeroed.
2. **An index is the pointer.** Where C would keep a pointer to an element,
   Wantzel keeps the index number. An index cannot dangle, is checked
   against the bounds at every use, and stays valid if you write the whole
   array to disk and read it back.
3. **Whatever is larger than the program wants to pin down comes from the
   operating system through `mmap`, and becomes an ordinary array with
   `view`.** You determine the size at startup or the file determines it;
   the capacity is disk or virtual memory, not RAM.

Which form to use when:

| situation | form |
|---|---|
| number known and small (< a few MB) | static array + counter |
| number unknown, but a reasonable upper bound exists | static array with that bound; measure the bound with `tests/limits` |
| size only known at startup | anonymous `mmap` of that size + `view` |
| data that has to survive a restart | file + `mmap`, records as the format, indexes as references |
| larger than RAM | file + `mmap`; the kernel pages |
| temporary workspace per call | local array (stack, max 8 MB in total) or a slice of a global arena |
| key → value | a hash table on two arrays |
| references between objects | indexes in one table, with a free list for reuse |

What you never need: an allocator per object. Every structure gets one
reservation, at compile time or at startup, and inside it all references
are indexes.

## 11. Limits

Every hard limit (arguments, identifier and literal length, include depth,
numbers of globals/locals/routines/schemas/tools, source and code size,
static memory, stack) is listed with a measured value in
`tests/limits/README.md` and is guarded by `tests/limits/limits.sh`.

## 12. Targets

Linux x86-64 ELF (raw syscalls) and Windows x86-64 PE32+: static binaries that talk to
`kernel32.dll`, `ws2_32.dll` and `advapi32.dll` directly. On both targets there is no
assembler, no linker, no C library and no external tool. `bootstrap/boot.c` and
`src/wantzel.wz` produce byte-identical output, ELF and `.exe` alike; every language change
lands in both and in `test.sh`.

### What is portable, and what is not

Almost everything. The library (`io`, `fs`, `net`, `http`, `json`, ...) and `sys1`..`sys6`
mean the same on both targets: on Linux a `sys*` call is the syscall instruction, on Windows
the runtime translates it to the matching `kernel32`/`ws2_32` function. **A program written
against those calls compiles and runs on both, unchanged** — `examples/winfacts.wz` does a
file round trip, an existence check, a delete and a directory listing, and the ELF and the
`.exe` print the same thing, which is what `tests/toolchain/win_same_output.sh` checks.

The one exception is `winapi(slot, ...)`, which calls an imported DLL function directly.
There is no Linux equivalent, so **it does not compile for a Linux target at all**:

```
winfacts.wz:2: winapi() is only available in a Windows executable
```

That is deliberate and it is the compile-time half of the rule: a program that reaches for
a Windows-only facility cannot be built for Linux by accident and fail later. The other half
is the slot itself — a literal outside the import table is refused the same way:

```
x.wz:3: winapi(): that import slot does not exist
```

So if a program builds for both targets, it uses nothing Windows-specific; and if it uses
`winapi`, the compiler says so at the point where you asked for the wrong target.

**`winapi` can also name the DLL and the function**, which is how a program reaches an API
the compiler has never heard of:

```pascal
winapi("user32.dll", "MessageBoxA", 0, text, title, 0);
```

The name is recorded while translating and written into the import table. That is the point
— a new Windows API is data, not a change to this compiler — but it means the checking
happens at **three different moments**, and it is worth knowing which is which:

| what is wrong | when you find out | what you see |
|---|---|---|
| built for the wrong target | **compile time** | `winapi() is only available in a Windows executable` |
| the DLL does not exist | **load time**, before your program runs | the loader refuses to start the process |
| the function does not exist in it | **run time**, at the call | the process starts, then aborts on that line |

Measured, not assumed. The last row is the one to keep in mind: a missing DLL is fatal
before `main`, but a *misspelled function* in a DLL that does exist gets filled in with a
stub that only complains when something calls it. A typo in a rarely-taken path can
therefore sit unnoticed. The compiler cannot help here — it has no way to know what a DLL on
the target machine exports — so **exercise every `winapi` call at least once in a test**. Where a
platform difference genuinely cannot be hidden it is named in this document, rather than
left for a reader to discover.

**Naming a function the compiler already imports costs nothing extra.** The compiler carries
48 imports of its own — the ones the runtime needs before your first line runs, such as
`GetStdHandle`, `WriteFile` and `ExitProcess`. Write `winapi("kernel32.dll", "WriteFile", ...)`
and the call reuses that existing entry rather than adding a second one; the match ignores
case, because a source writes `user32.dll` where the table holds `USER32.dll`.

The reuse is per **function**, not per DLL — naming `user32.dll` does not hand you the whole
built-in user32 block. Three cases, and they are all the compiler does:

| what you name | what happens |
|---|---|
| a DLL it has, a function it has | the existing slot; nothing is added |
| a DLL it has, a function it does not | a new entry, and a second directory entry for that DLL |
| a DLL it does not have | a new directory entry and new slots |

A function the compiler does *not* have gets an entry of its own, and that puts a **second
directory entry for the same DLL** in the executable when you name a new `user32` function.
That is legal and deliberate: the built-in names and the source-named ones are two separate
runs in the name table, and interleaving them would put the address table out of step with
the names. Two entries naming one library cost a few bytes; one ordering instead of two
costs nothing at all.

Why the 48 exist rather than being data like everything else: the loader fills the import
table **before the first instruction runs**, so a program cannot look up the functions it
needs in order to start. Those names have to be in the file the compiler wrote. The rest of
what a program touches is data, which is the whole point of naming imports in the source.

This works the same in both compilers, which matters more than it sounds: `lib/` is compiled
**into** the compiler, so a library routine that names an import has to be understood by the
C bootstrap as well — otherwise a fresh clone could not build. It is, and the two produce
identical bytes. Nothing circular arises from that: the imports a library routine
names land in **your** executable, not in the compiler's own table.

The one place that boundary is real is the startup path. Code that runs *before* your
program does cannot reach itself through an import table the loader has not filled yet — so
the handful of names needed to start a process stay built in, and everything a program calls
afterwards can be ordinary source.

### `winproc(name)`: letting Windows call your routine

On Windows the operating system calls *you*. A window procedure, a window enumerator, a
hook, a timer: you hand the system an address and it jumps into your program. This language
has no function pointers on purpose, so there is exactly one way to produce that address, and
it is as narrow as the need:

```pascal
poke64(wc, 8, winproc(wndproc));                  // WNDCLASSEXA.lpfnWndProc
winapi("user32.dll", "EnumWindows", winproc(onwindow), 0);
```

`winproc` takes the **name of a routine you declared** — not an expression, not a variable —
and gives back an address to pass on. It is only valid when building for Windows; on Linux it
does not compile, because a callback is a Windows notion and pretending otherwise would hide
the difference rather than handle it.

**What it returns is not your routine's address.** Windows passes arguments in one set of
registers and this language reads them from another, so the compiler writes a small adapter
beside your routine and hands back the address of *that*. The adapter moves the arguments
across, reserves the 32 bytes of shadow space the platform requires, and preserves the
registers Windows expects to find untouched — `rdi`, `rsi` and `rbx`, which are yours to
destroy on Linux and yours to preserve on Windows.

The routine itself is ordinary: up to four `int` parameters, returning `int`. That is the
shape of every callback in the Windows API, so one adapter carries all of them and a routine
that takes fewer simply ignores the rest.

```pascal
function wndproc(hw: int; m: int; wp: int; lp: int): int;
begin
  if m = WM_DESTROY then begin ... end;
  return winapi("user32.dll", "DefWindowProcA", hw, m, wp, lp);
end;
```

Why this exists at all: a button click is **sent** straight to a window procedure and never
appears in the message queue a loop reads, so no message loop — however written — can see
one. There is no way to write an interactive Windows program without a callback.

**The target comes from `--target=` and from nowhere else.** The default is Linux; the
output name decides nothing:

```bash
./bin/wantzel examples/hello.wz bin/hello                     # Linux ELF
./bin/wantzel examples/hello.wz bin/hello.exe --target=windows # Windows PE32+
./bin/wantzel examples/hello.wz bin/hello --target=windows    # PE, whatever the name
./bin/wantzel examples/hello.wz bin/app.exe --target=linux    # ELF under a .exe name
./bin/wantzel examples/hello.wz bin/hello.exe                 # refused: which target?
```

A name ending in `.exe` used to select Windows on its own, which made the output name a
second and invisible way to choose the target — `wantzel x.wz backup.exe` handed back a
Windows binary nobody asked for. A `.exe` name with no `--target` is now **refused**
rather than quietly built for Linux: the two contradict each other, and saying so costs
nothing.

`--target=linux` and `--target=windows` (short: `-tlinux`, `-twindows`) are the only
values. The ELF output is unchanged: the same source gives the same ELF as before.

**The language is identical on both platforms.** Everything in this document holds for a
`.exe`. What differs is underneath: where Linux gets the `SYSCALL` instruction, Windows
gets a call into a runtime shim that translates to the Win32 equivalent. Reads and writes,
files, directory listing and `stat`, sockets, `epoll` (emulated over `WSAPoll`), time,
`mmap`/`msync`, `fsync`, `rename`, `flock`, `getrandom` and the command line are all
translated. The compiler compiles itself into a working `wantzel.exe`, which in turn
compiles Wantzel source and reproduces itself byte-identically: self-hosting on Windows.

Two things are not equivalent, and both are properties of Windows rather than of the
language:

- **No `fork`.** Windows does not have it, so `fork` returns `0` and the caller becomes
  the only worker. A multi-worker HTTP server therefore runs single-process there: it
  works, but it does not use every core the way it does on Linux.
- **No PE checksum and no signature.** Not needed to run, but a fresh unsigned `.exe` is
  blocked by SmartScreen and by some Defender ASR policies on managed machines. That is
  not specific to Wantzel — an unsigned hello-world from any compiler is treated the same
  — and the fix is an Authenticode signature the machine trusts, a folder exclusion from
  your administrator, or testing in Windows Sandbox.

`bootstrap/tools/runexe.sh` runs an `.exe` under Wine, and `./wztest --toolchain` exercises
the Windows side that way, so the two targets are tested together rather than one being
assumed to still work.
