# `json` — JSON scanning and writing primitives

`include "json.wz";` (pulls in `io.wz`)

Nothing here builds a tree. A JSON value stays where it is, in the input buffer, and is
described by an `(offset, length)` pair rather than copied out. The parsers the compiler
generates from a `schema` declaration are built on top of these routines; most application
code never calls them directly and uses a `schema` instead. Reach for this module directly
when the shape of the input is not known up front (a generic proxy, a log line, a
protocol envelope with open-ended fields).

## Reading: skipping and recognising values

Every reader takes `(b, at, last)` with `last` **exclusive** — the span to look in, never a
length — and returns the position just past what it scanned, or `-1` if it could not.

| | |
|---|---|
| `json.ws(b, at, last): int` | skip whitespace; returns the first non-blank position |
| `json.skip(b, at, last): int` | step over one whole value, however nested (`{...}`, `[...]`, a string, a number, `true`/`false`/`null`) |
| `json.string(b, at, last): int` | scan a string value; fills `json.sat`/`json.send` with the text span (without the quotes); returns the position after the closing quote |
| `json.number(b, at, last): int` | scan a number; the integer part lands in `json.ival` (a fractional part is scanned over but not decoded — use `json.real` for that) |
| `json.boolean(b, at, last): int` | scan `true`/`false` into `json.bval` |
| `json.isnull(b, at, last): bool` | is the value at `at` the literal `null`? (does not consume it) |
| `json.literal(b, at, last, s: str): int` | does `b` at `at` spell out the literal `s`? Returns the position after it, or `-1` |
| `json.strend(b, at, last): int` | given `at` **just past** an opening quote, find the closing quote (honouring `\"`); returns its index, or `-1` if the string never ends. Used inside `json.string`; rarely called directly |
| `json.eq(b, at, last, s: str): bool` | does the exact span `b[at..last)` equal the literal `s`? |
| `json.escaped(b, from, upto): bool` | does the string body `b[from..upto)` contain a backslash escape? |

All of these return `-1` (or `false` for the boolean-style questions) on malformed or
truncated input — **there is no position to continue from** on failure, unlike the
appenders below.

```pascal
include "json.wz";

var
  src: array[0..63] of char;
  n, at: int;

begin
  n := io.push(src, 0, "{\"count\":42}");

  at := 1;                                            // past '{'
  at := json.string(src[0..n - 1], at, n);             // scans "count" into json.sat/json.send
  if json.eq(src[0..n - 1], json.sat, json.send, "count") then
  begin
    at := at + 1;                                      // past ':'
    at := json.number(src[0..n - 1], at, n);            // json.ival now holds 42
    io.puts(STDOUT, "count = ");
    io.putn(STDOUT, json.ival);
    io.puts(STDOUT, "\n");
  end;
end.
```

**The most common mistake with `json.eq`:** the literal you compare against is matched
**exactly**, quotes and all, if you include them — `json.eq(b, at, last, "\"name\"")`
only matches a span that itself contains the quote characters. Comparing the *decoded*
text of a key (as in the example above, `json.sat..json.send`) means writing the literal
**without** quotes. Whichever form you use, count the literal's length by an independent
means before trusting an off-by-one; a miscounted end is not a compile error or a runtime
error, it is a comparison that is silently always `false`.

## Decoding a string body

| | |
|---|---|
| `json.unescape(src, from, upto, dst, at): int` | decode the string body `src[from..upto)` (as found by `json.string`) into `dst` starting at `at`; returns the number of bytes written, or `-1` on a malformed escape or if it does not fit. **Does not check `len(dst)` against `at` on its own beyond the room it needs per character** — the routine bounds every write against `len(dst)`, but the caller must still choose an `at` that leaves room |
| `json.copystr(src, from, upto, dst): int` | the same decoding, always writing from position `0` of `dst`; returns the length, or `-1` |

Both understand the standard JSON escapes (`\n \t \r \b \f \" \\`) and `\uXXXX`, encoding
non-ASCII code points as UTF-8 (1–3 bytes per escape).

## Writing: appenders that truncate

Every appender in this group takes `(dst, at, ...)`, writes at position `at`, and returns
the new position — chain them by feeding the result back in as the next `at`.

| | |
|---|---|
| `json.putstr(dst, at, s: str): int` | append `s` as a quoted, escaped JSON string |
| `json.putslice(dst, at, src, from, upto): int` | append `src[from..upto)` as a quoted, escaped JSON string — **but see below, this one refuses instead of truncating** |
| `json.escslice(dst, at, src, from, upto): int` | append `src[from..upto)` escaped but **without** surrounding quotes, for assembling a larger string piece by piece |
| `json.putb(dst, at, c: char): int` | append one raw byte — **also refuses**, see below |
| `json.putraw(dst, at, src, from, upto): int` | append `src[from..upto)` verbatim, no escaping and no quotes (for embedding text that is already valid JSON) |
| `json.putreal(dst, at, v: real): int` | append `v` as a JSON number, up to 15 significant digits, trailing zeros trimmed; `NaN` and infinities become `null` |

```pascal
include "json.wz";

var
  buf: array[0..127] of char;
  n: int;

begin
  n := io.push(buf, 0, "{\"name\":");
  n := json.putstr(buf, n, "probe");
  n := io.push(buf, n, ",\"count\":");
  n := io.pushnum(buf, n, 42);
  n := io.push(buf, n, "}");
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

**Two different failure contracts inside this one module, and it matters which you get:**

- `json.putstr`, `json.escslice`, `json.putraw`, `json.putreal` **truncate** at
  `len(dst)`: what does not fit is silently dropped, and the position that comes back is
  simply the end of the buffer — the same contract as `io.push`. A caller that must know
  whether everything fit compares the returned position against the one passed in.
- `json.putslice` and `json.putb` **refuse**: they return `-1` and write nothing further,
  because they exist for the generated `<Schema>.write`, where a half-written JSON object
  is not a shorter object but a syntax error. **Always test their result** before
  continuing a chain — feeding a `-1` into `io.push` or another truncating appender is
  harmless (both pass a negative `at` straight through unchanged), but feeding it into an
  array index is not.

A negative `at` passed into any of the routines above (truncating or refusing) comes back
unchanged rather than indexing `dst[-1]`, precisely so a `-1` from a refusing call can
travel through a chain of appenders and be tested once at the end.

## Reals

| | |
|---|---|
| `json.real(b, at, last): int` | scan a JSON number as a `real` into `json.rval`; returns the position after it, or `-1`. Full precision up to 18 significant digits |
| `json.isnull` | (listed above) |

## Bytes as a JSON boolean question

`json.boolean` and `json.isnull` are the only two routines here that look *inside* a value
rather than merely spanning it; everything else treats a value as an opaque byte range
until something more specific (a schema, or your own code) decodes it.

## What is not here

There is no tree, no `json.get("a.b.c")` path lookup, and no in-place mutation of parsed
JSON. Looking up a field by key inside an object is `kv.find`/`kv.first`/`kv.next` (in
`lib/kv.wz`), built on top of these same scanning primitives. Building a whole typed
object from JSON, or a JSON object from a typed record, is what a `schema` declaration
generates — reach for `json` directly only when the schema mechanism does not fit (an
open-ended envelope, a proxy that passes bytes through unchanged).
