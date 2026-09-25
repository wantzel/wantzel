# Language specification

**The binding reference: what the compiler supports today.**

[README](../README.md) · [Language](language.md) · [Syntax](syntax.md) · [Library](library.md) · [Writing Wantzel](writing-wantzel.md) · [How-to](howto.md) · [Design](design.md) · [Changelog](changelog.md)

---

Everything here is tested in `test.sh` or `tests/`. Planned extensions live in §9 and are
only valid once they move here. Whoever implements something reads this file first;
whoever changes the language updates this file in the same commit. Where the tour below
and a numbered section seem to differ, the numbered section binds.

Last updated: 2026-09-17 (phase 1 complete: real, record, slices, view, for, local const,
schema v2, tools; a schema is `type X = schema ... end;`).

## A tour

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

**Types.** `int` (64-bit), `real` (64-bit IEEE), `char` (0..255), `bool`, `str`
(literals), `array[lo..hi] of T` and `record`. No implicit conversions: `ord()`/`chr()`
are required, an `int` is not a condition, `and`/`or`/`not` work only on `bool` (bits go
through `band`/`bor`/`bxor`/`bnot`). No pointers, no pointer arithmetic — indirection goes
through arrays whose bounds the compiler knows. Routines take up to ten arguments; an
`array of T` parameter counts as two (address and length) and keeps its bounds check.

**Safety.** The compiler enforces, while translating: mandatory declarations, every
`forward` fulfilled, signatures compared, a function result never discarded, a
`procedure` never returning a value. In the generated code, checked with file and line:

```
runtime error: array index out of range at examples/httpd.wz:42
```

- every array index against both bounds;
- division and `mod` by zero;
- `chr()` outside 0..255, `schar()` and `scan()` outside the string or array;
- a `function` that ends without `return`;
- locals and arrays zeroed on every call — no undefined initial values.

Not checked: integer overflow, and anything through `addr`/`sysN`. A guard only protects
you if it can reach its verdict without trusting the value it inspects: every bound above
compares against a compile-time constant or a length in the call frame, neither of which
the caller can corrupt. The one bound read *from* the value is a `str`'s length (the eight
bytes before its text), so an unassigned `str` is address 0, length 0, and `slen` answers
0 for it. Rule of thumb: **a zeroed variable is valid everywhere** — `int` 0, array all
zero, `str` empty. Anything reached through `addr`, `view` or `sys*` is checked by
nothing.

**Compiled JSON schemas.** A strictly typed compiled language can do this where a dynamic
stack cannot: describe a message shape, and the compiler makes a record type, a parser, a
writer and a JSON Schema from it — no DOM, no reflection, no allocation.

```pascal
type Rpc = schema
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

A field can carry the JSON key it corresponds to, as a string literal before the colon —
needed because identifiers are case-insensitive (`rdX`/`rdx` are one name in Wantzel, two
on the wire) and a key like `content-type` or `$schema` is not a valid identifier at all:

```pascal
type Reg = schema
  rdx:          int;
  rdxcap "rdX": int;                  // the same letters, a different key
  ctype "content-type": text;         // not a name any language would accept
end;
```

Field types: `int`, `real`, `bool`, `text` (view), `text[N]` (copy), `text of (...)`,
`json`, arrays of those and nested schemas, each with `?` for optional and a
`"description"` for `Rpc.jsonschema`. A `tools` block turns a declaration into a complete
MCP tool table — `tools/list`, argument parsing, dispatch, `structuredContent` — all from
one place (see `examples/mcptools.wz` and §7b).

## 0. What kind of language is this?

Small, strictly typed, procedural, reading almost like prose: `begin`, `end`,
`procedure`, `:=`. A Pascal reader needs no introduction, but this is not an ISO-7185 or
Free Pascal dialect — the deviations are deliberate (§8).

Design rule: **one clear choice per concept, nothing exotic.** Familiar spelling where it
costs nothing; where older languages offer several ways to say a thing, Wantzel picks
one. Predictable for people and for a model generating code.

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

Escapes in a `char`/`str` literal: `\n` `\t` `\r` `\0` `\\` `\'` `\"`, and `\xHH` —
**exactly two** hex digits, upper or lower case. Two and not a variable number,
deliberately: a hex escape that keeps eating digits (as in C) means a generator cannot
write a byte then a literal hex character without changing what it wrote, so `"\x41BC"`
is three characters. Anything else after a backslash is refused.

Comments: `// to end of line`, the only form. Identifiers and keywords are
**case-insensitive** (`Point` and `point` are the same name). Identifiers: letters,
digits, `_`, and a **dot** as a namespace separator (`io.puts`, `mcp.buf`) — cosmetic,
there are no modules. First character must be a letter or `_`; a part **after** a dot may
start with a digit (`Reading.level.1`, from a schema enum whose value is `"1"`). A real
literal still reads as one number: `3.5` is a value, never a name.

## 2. Types

Five scalar types, one composite type.

| type | meaning | literal |
|---|---|---|
| `int` | 64-bit two's complement | `42`, `-7`, `0xFF` |
| `char` | one byte, 0..255 | `'a'`, `'\n'`, `'\\'`, `'\''`, `'\x41'` |
| `bool` | `true` / `false` | |
| `real` | 64-bit IEEE-754 (C `double`, Python `float`); the only decimal type | `1.5`, `0.25`, `2e-3`, `6.02e23` (a dot or exponent makes a `real` literal; `1.` and `.5` are not literals) |
| `str` | an **immutable string literal** (address + length); not a value you build up | `"text\n"`, `"caf\xc3\xa9"` |
| `array[lo..hi] of T` | fixed array of `int`, `char`, `bool` or `real`; `lo`/`hi` constant ints; `lo` may be ≠ 0 | |

**No implicit conversions.** `int` ↔ `char` via `ord()`/`chr()`; `int` → `real` via
`real(i)`; `real` → `int` via `trunc(r)` (towards zero) or `round(r)` (nearest, halves to
even). An `int` is not a condition. `and`/`or`/`not` work only on `bool`; bits are done
with `band`/`bor`/`bxor`/`bnot`/`shl`/`shr`.

`real` computes with `+ - * /` and unary `-`; `/` exists only for reals (`int` uses
`div`), `div`/`mod`/`shl`/`shr` exist only for ints. Comparison with `= <> < <= > >=`; NaN
equals nothing and orders nowhere. Division by zero gives `inf`/NaN as IEEE prescribes,
not a runtime error. A literal with at most 18 significant digits and an exponent up to
±22 rounds correctly; beyond that the last bit may differ. Constants: `const PI =
3.14159; NEG = -2.5;`. No 32-bit type: `pack32(r): int` gives the IEEE single bits (for
compact storage), `unpack32(i): real` gets them back. Text ↔ real is library.

**Text as a value** is always an `array of char` (with `len()` as length, or a separate
`int` for the filled part). A routine that takes text declares `s: array of char` and
accepts a literal, an array, a slice or a view (§4). `str` is solely the type of a
literal itself, for `slen`/`schar`/`sadr` and existing library routines; new code does
not need it. Strings cannot be compared with `=`; compare per `char` or with `json.eq`.

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
- A record has no value of its own: not in an expression, not as a parameter, not as a
  function result. Pass records as `array of T` (a one-element slice suffices, §4) and
  let a routine fill a record through such an array.
- `addr(b.pos)` and `len(b.tags)` work; `addr(bodies[2]) - addr(bodies[1])` is the record
  size.
- Layout: fields in declaration order; `char`/`bool` fields and arrays lie on byte
  boundaries, everything else on 8 bytes; total size is a multiple of 8. A record may not
  contain itself.
- `type` appears only at program level, before the routines using it. A type name is an
  ordinary identifier (case-insensitive) and may not coincide with a variable or routine.

No pointers, sets, enumerations, strings with content, or nested arrays (`array of
array`). See §9.

## 3. Expressions and operators

Precedence, high to low, as in Pascal:

1. `not`, unary `-`
2. `*` `/` `div` `mod` `and` `shl` `shr`
3. `+` `-` `or`
4. `=` `<>` `<` `<=` `>` `>=`

`div`/`mod` are Pascal semantics (truncation towards zero: `-7 div 2 = -3`, `-7 mod 2 =
-1`), checked against division by zero. `and`/`or` on `bool` are **short-circuit**
(`false and f()` does not call `f`). Ordering (`<` etc.) only on `int`, `char`, `real`.
Overflow of `int` is not checked.

## 3b. Visibility: `local`

Every name is global and the namespace is shared, so two files cannot both declare
`hidden.n`. `local` in front of a top-level declaration makes the name visible **only in
the file that declares it**:

```pascal
local var   hidden.n: int;          // this file only
local const HIDDEN.MAX = 64;
local procedure hidden.bump;
local function hidden.count: int;

var   shared.seen: int;             // public, as before
```

- Applies to `var`, `const`, `procedure`, `function` at the top level; not to `type` or
  `schema`.
- **Public is the default** — a declaration without `local` behaves as before, so
  existing source needs no change.
- The unit is the **file**. No module system, no separate compilation, no nesting:
  `local` means "this file", nothing else.
- Naming a local from another file is `undeclared identifier`, same as a name that does
  not exist — because from there, it does not.

A `local` in front of a `const` block **inside** a routine is different and predates
this: that one scopes to the call. Where you write it decides which is meant.

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

- Arguments are passed **by value**; an `array of T` parameter is a *view* (address +
  length) and writing into it is visible to the caller. No `var` parameters: use an array
  or a global.
- A record variable may appear where `array of <that record>` is expected — it arrives as
  a view of one element (`Point.parse(buf, 0, n, p)`).
- Where `array of T` is expected, you may give: a whole array (`p(buf)`), a **slice**
  `p(buf[lo..hi])` (inclusive, like a declaration; `buf[3..2]` is empty; bounds checked),
  an array field of a record (`p(r.tags)`), an element slice of an array of records
  (`p(items[i..i])`, the way to pass one record), a **string literal** as `array of char`
  (`p("text")`), or `view(addr, n)`: `n` elements of type `T` at an arbitrary address (for
  `mmap`, kernel buffers, byte reinterpretation). `view` and slices exist only in that
  position; they are not values.
- At most ten arguments; an array counts for two.
- No nested routines; no recursion limit (recursion is allowed).
- `function` must execute `return` on every path (runtime error otherwise); `procedure`
  may not return a value; a function result may not be discarded.
- Local variables and arrays are **always zeroed** on entry.
- A routine may have `const` and `var` blocks after the header, in any order; local
  constants have the same forms as global ones.
- Callbacks: declare a routine `forward` in a library, define it in the application
  (`procedure app.request; forward;`). No function pointers.

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

`for` counts with step 1; after `break` the variable keeps the value it stopped on, after
a complete loop it is one past the end value. No `case`: write an if-chain, and note that
`else` binds to the nearest unclosed `if`. No `with`, no `goto`.

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
| `argc()`, `argch(k, i)` | number of arguments; i-th byte of argument `k` (`chr(0)` at the end, and for any `k`/`i` out of range — it answers rather than traps) |
| `halt(code)` | exit |
| `sys1(nr, a)` … `sys6(nr, a..f)` | raw Linux syscall |

Library routines (`lib/`) are ordinary Wantzel: `io.*`, `net.*`, `http.*`, `json.*`,
`mcp.*`, `fs.*` — see [`library.md`](library.md).

### The syscall number is the contract

`sys1`..`sys6` are builtins the compiler translates straight to machine code: no wrapper,
no error handling, no errno translation. Arguments go into the System V registers, and
the compiler emits the two bytes of the x86-64 `SYSCALL` instruction literally.

The syscall number is an ordinary constant (`SYS.fork = 57`, `SYS.wait4 = 61` in
`lib/io.wz`); the compiler knows no syscall by name. **Everything the operating system
offers is reachable without touching the language** — a new capability is a constant plus
a call, not a compiler change. `fork`, shared memory and `flock` were each called
impossible here before someone checked.

Nothing is checked on the other side: a wrong number or argument gives a negative return
(`-errno`) or, worse, something that appears to work. Like `addr` and `view`, this is
unsafe: no runtime check applies to it.

## 7. `schema` — compiled JSON

A `schema` describes the shape of a JSON object. The compiler turns it into, in one go: a
**record type** with the same name, `Name.clear`, `Name.parse`, `Name.write` and the
constant `Name.jsonschema`. No DOM, no reflection — the parser reads straight from the
input buffer.

```pascal
type Point = schema
  x: real;
  y: real;
  tag: text of ("start", "mid", "end")?;        // enum → int, with constants Point.tag.start ...
end;

type Path = schema
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

Per field `f`, in the record:

| field declaration | in the record |
|---|---|
| `int`, `real`, `bool`, enum | `f` |
| `text` (view), `json` | `f_at`, `f_end` |
| `text[N]` | `f: array[0..N-1] of char`, `f_n` |
| `array[0..N-1] of T` | `f: array[0..N-1] of T`, `f_n` (number read) |
| `array[0..N-1] of text[M]` | `f: array[0..N*M-1] of char`, `f_len[0..N-1]`, `f_n` |
| nested schema `S` | `f: S` |
| always | `f_ok` (key present), `f_null` (value was `null`) |

Rules:

- A missing required field (without `?`) makes `parse` return `-1`.
- An **unknown key is ignored but recorded** — `parse` steps over it and succeeds;
  `json.ignoredn` counts skipped keys, `b[json.ignored0..json.ignored1)` is the first.
  This lets a caller send a superset of a schema — what a client written against a
  schema-validating server does — and refusing it would turn a harmless extra field into
  a failed call. The recording matters because a renamed or misspelt **optional** field
  would otherwise silently take its default with nothing saying so; a renamed
  **required** field still fails, since the field it should fill is absent.
- A key the schema *does* declare is strict: a value it cannot hold gives `-1`, and
  `b[json.badkey0..json.badkey1)` names a key the parse rejected outright.
- `null` sets `f_null` and `f_ok`. A text that does not fit `text[N]`, or an array with
  more than `N` elements, gives `-1`. An enum value outside the list gives `-1` in the
  field but no error.
- `write` always writes required fields, optional ones only if `f_ok`; `f_null` writes
  `null`. `write` returns `-1` when the object does not fit in `dst` (or the start
  position is negative or past the end) and writes nothing usable — a short buffer is a
  **refusal**, not a truncation, because half a JSON object is a syntax error, not a
  shorter object. This differs deliberately from the appenders in `lib/` (`io.push`,
  `json.putraw`, `json.putstr`), which truncate at `len(dst)` and hand back a still-usable
  position — a shortened message is still a message. **Test the result of `write`**; a
  generated `tool.run` does, and reports the failure to the peer instead of dying on it.
- A nested schema must be declared earlier; a schema name is a type name (no variable
  with the same name).
- A `json` field in an output record can be filled by `Other.write` of another schema
  into the same view buffer: `r.base_at := tool.vn; tool.vn := Other.write(tool.vbuf,
  tool.vn, o, tool.vbuf); r.base_end := tool.vn;` (nesting one schema's output inside
  another's).
- Descriptions after the type (and after `?`) appear as `"description"` in the JSON
  Schema; `text[N]` gets `maxLength`, arrays `maxItems`.

## 7b. `tools` — a tool table as a declaration

A `tools ... end;` block declares an MCP tool table **once**. From each line the compiler
generates the JSON Schemas, argument parsing, dispatch to your handler and result
writing — the whole surface a hand-written MCP server otherwise builds one `mcp.add(...)`
JSON fragment at a time. **This is the way to expose tools in Wantzel; do not build
`tools/list` or a call reply by hand.** One declared line replaces tens of lines of
hand-assembled JSON, and it stays correct as the schema changes, because the JSON comes
from the same declaration the parser and dispatcher use.

### The smallest complete program

```pascal
include "json.wz";

type ConvertArgs = schema
  celsius: real "the temperature to convert";
end;

type ConvertResult = schema
  fahrenheit: real;
end;

tools
  convert(ConvertArgs): ConvertResult "Convert Celsius to Fahrenheit." readonly idempotent;
end;

include "toolsmcp.wz";                      // AFTER the tools block: it reads it

function tool.convert(a: array of ConvertArgs; r: array of ConvertResult): int;
begin
  r[0].fahrenheit := a[0].celsius * 9.0 / 5.0 + 32.0;
  return 0;                                  // 0 = success; otherwise: return tool.fail("message")
end;

begin
  mcp.stdio;
end.
```

That is a complete MCP server over stdio. `tools/list` from that program, generated, not
written:

```json
{"name":"convert","description":"Convert Celsius to Fahrenheit.","inputSchema":{"type":"object","properties":{"celsius":{"type":"number","description":"the temperature to convert"}},"required":["celsius"]},"outputSchema":{"type":"object","properties":{"fahrenheit":{"type":"number"}},"required":["fahrenheit"]},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true}}
```

### Line anatomy

```pascal
convert(ConvertArgs): ConvertResult "Convert Celsius to Fahrenheit." readonly idempotent;
// ^name  ^input schema ^output schema ^description (→ JSON Schema)  ^annotations
```

`name(ArgsSchema): ResultSchema "description" annotations;` — one line per tool, inside
one `tools ... end;` block per program, placed after the schemas it uses. `ArgsSchema`
and `ResultSchema` are ordinary `schema` types (§7); the same mechanism serves both
directions.

### What you write versus what the compiler generates

| you write | the compiler generates |
|---|---|
| the `tools ... end;` block | `tool.list` — the complete `tools/list` text: `inputSchema`, `outputSchema`, `description`, `annotations` |
| | `tool.count` and `tool.id_<name>` |
| | per tool, the records `tool.in_<name>` and `tool.out_<name>` (from the schemas) |
| | `tool.byname(b, at, upto)` — finds a tool by its `"name"` in a request buffer |
| | `tool.run(idx, b, at, upto, dst)` — parses the arguments, calls `tool.<name>`, writes the result JSON |
| | `tool.fail(s)` — call it from a handler to refuse with a message |
| `function tool.<name>(a, r): int; ... end;` per tool (`forward`-checked: a missing handler is a compile error) | the dispatch that calls it from `tool.run` |
| `include "lib/tools.wz";` or `include "lib/toolsmcp.wz";` | `app.tools`, `app.call` (MCP), and — `lib/tools.wz` only — `tool.rest(prefix)` (REST) |

`lib/tools.wz` is two files: `lib/toolsmcp.wz` (`app.tools`, `app.call`, MCP only, no
HTTP) and the REST half, which brings `lib/http.wz` and with it the forward
`app.request` the program must define. A server that speaks MCP over stdio only needs
`lib/toolsmcp.wz` and no `app.request`. `tools` is a keyword: do not use it as a
namespace in your own code.

**A tool name becomes a routine name in the `tool.` namespace**, so it cannot be one the
compiler or `lib/tools.wz` already uses there. `count`, `list`, `run`, `byname`, `fail`,
`err`, `rest`, `vbuf` and `vn` are taken, as are names starting with `id_`, `in_` or
`out_`; the compiler reports it at the tool's own line, e.g. `tool name "count" is
reserved: the tools block generates tool.count; choose another name`. Choose a more
specific name (`wordcount`, not `count`).

**Annotations**: `readonly`, `idempotent`, `destructive` — each `false` by default; write
the ones that apply, in any order, after the description.

**Errors and status codes.** A handler returns `0` for success or `tool.fail("message")`
to refuse. `tool.run` reports three distinct failures, kept apart because they have
different owners:

| `tool.run` returns | meaning | REST (`tool.rest`) |
|---|---|---|
| `-1` | the arguments did not satisfy the input schema | 422 |
| `-2` | the handler refused with `tool.fail("message")` | 400 |
| `-3` | the result JSON does not fit in `dst` | 500 |

**Only `-1` gives 422.** Every other handler-side rejection gives 400, the same as any
other rejection — a 422 means specifically "this JSON does not match the schema", never
"the handler looked at valid arguments and said no". A handler rejecting on the *content*
of an otherwise valid argument (an out-of-range number, an unknown id) still gets 400.
`-3` gives 500: the request was valid and the limit is ours, so it is kept apart from
`-1`, which would otherwise blame the caller for a limit on our side.

**View fields: buffer and escaping.** A `text`/`json` field (a view) in the INPUT schema
cannot be read by the handler. `tool.run` parses the call into `tool.in_<name>` from the
request buffer `b`, but the handler `tool.<name>(a, r)` only ever receives the parsed
record, never `b` itself — a view field is a pair of offsets into a buffer the handler
cannot reach. Declare every argument field `text[N]` (a copy) instead; `int`, `real`,
`bool`, an enum, a nested schema or an array of those are unaffected, since those never
point outside the record. Only the input side has this restriction, because only the
input side is parsed into a record a *different* routine then uses without the source
buffer.

For `text`/`json` fields (views) in the output schema, the compiler generates the buffer
`tool.vbuf` (1 MB) and fill position `tool.vn` (0 at every call): the handler writes text
into `tool.vbuf` from `tool.vn` and points `f_at`/`f_end` at it; `tool.run` writes the
result with `tool.vbuf` as the source of the views. A handler that fills `tool.vbuf` to
its limit is refused loudly: `tool.run` checks `tool.vn` right after the handler returns
and, at or past `len(tool.vbuf)`, fails with `tool <name>: reply exceeds 1048576 bytes`
instead of writing a reply built from silently truncated text (`io.push` and
`json.escslice`, the appenders a handler uses to fill it, stop at `len(tool.vbuf)` by
their own contract rather than refuse). **A view field is written LITERALLY**,
byte for byte, with no escaping (`Result.write` uses `json.putraw`). A `text[N]` field is
escaped automatically (`json.putslice`). So a handler building a `json`-view or
`text`-view field's content from anything not already valid JSON / JSON-string-safe must
escape it itself first, with `json.escslice(tool.vbuf, tool.vn, src, from, upto)` —
skipping that produces invalid JSON, not merely wrong characters, because an unescaped
quote or control character inside the slice ends the JSON string early.

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
costs more than it gives, it goes, and code using it needs editing. Plan for it, and
re-read this section on each release.

That is not licence to churn. **The bar is evidence, not taste** — a proposal resting on
symmetry or familiarity does not clear it, one that shows what a construct costs in
practice does. It is then weighed against the test in [`design.md`](design.md): a change
should remove a *choice* between things that meant the same, never a *distinction*.

After 1.0 this reverses: compatibility is the default, and a break needs the stronger
case. What an application still needs meanwhile is library (`lib/`), not language.

One thing was **removed**: the `{ }` block comment. It ended at the first `}`, so a brace
inside the comment text (a JSON example, the words "default {}") closed it early and the
rest of the sentence compiled as code, with the error appearing far from its cause. Most
recorded syntax errors of that era came from it, including several written after the
pitfall was documented. `//` has no such failure mode; a source that still uses `{ }` is
refused with a message naming the replacement.

**Not coming:** heap/`new`/`dispose`, pointers, strings with content as a language type,
sets, `with`, `goto`, variants, classes, generics, exceptions, threads, operator
overloading, implicit conversions.

## 10. Runtime errors

Always with file:line: array index out of bounds ·
division by zero · `chr()` outside 0..255 · `schar()`/`scan()` out of range · function
without `return`.

## 10b. Memory

No heap, no pointers, no garbage collector. The model, in three sentences:

1. **All memory is an array with an upper bound.** A global array lives in bss and costs
   nothing until touched: declaring `array[0..1073741823] of char` (1 GB) is free, every
   page you write to costs 4 KB. Local arrays live on the stack and are zeroed.
2. **An index is the pointer.** Where C would keep a pointer to an element, Wantzel keeps
   the index number. An index cannot dangle, is checked against the bounds at every use,
   and stays valid if you write the whole array to disk and read it back.
3. **Whatever is larger than the program wants to pin down comes from the operating
   system through `mmap`, and becomes an ordinary array with `view`.** The size is
   decided at startup or by the file; capacity is disk or virtual memory, not RAM.

Which form to use when:

| situation | form |
|---|---|
| number known and small (< a few MB) | static array + counter |
| number unknown, but a reasonable upper bound exists | static array with that bound; measure the bound with `tests/limits` |
| size only known at startup | anonymous `mmap` of that size + `view` |
| data that has to survive a restart | file + `mmap`, records as the format, indexes as references |
| larger than RAM | file + `mmap`; the kernel pages |
| temporary workspace per call | local array (stack, max 8 MB total) or a slice of a global arena |
| key → value | a hash table on two arrays |
| references between objects | indexes in one table, with a free list for reuse |

No allocator per object: every structure gets one reservation, at compile time or at
startup, and inside it every reference is an index.

## 11. Limits

Every hard limit (arguments, identifier and literal length, include depth, numbers of
globals/locals/routines/schemas/tools, source and code size, static memory, stack) is
listed with a measured value in `tests/limits/README.md`, guarded by
`tests/limits/limits.sh`.

## 12. Target

Linux x86-64 ELF: a static binary that reaches the kernel through raw syscalls. No
assembler, linker, C library or external tool. `src/wantzel.wz` (self-hosted) implements
the whole language; `bootstrap/boot.c` is a small C compiler that only has to build
`src/wantzel.wz`, so it implements neither `schema`/`tools` nor
`--debug` — see [design.md](design.md#how-the-compiler-works) and
[testing.md](testing.md#the-bootstrap-fixed-point). Every language change lands in
`src/wantzel.wz` and in `test.sh`; it only lands in `boot.c` as well when
the compiler's own source starts using it.

The library (`io`, `fs`, `net`, `http`, `json`, ...) and `sys1`..`sys6` are the whole
interface to the operating system: a `sys*` call is the syscall instruction, and the number
is an ordinary constant, so anything the kernel offers is reachable from source. The
compiler compiles itself and reproduces itself byte-identically (`./build.sh`).
