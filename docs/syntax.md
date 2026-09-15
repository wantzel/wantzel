# Syntax

The whole of it. Wantzel is small on purpose: thirty-nine keywords, one way to say each
thing, and no construct that needs a second look.

For what the language *means* rather than how it is written, see
[`language.md`](language.md), which is binding. For how to write it well, see
[`writing-wantzel.md`](writing-wantzel.md).

## The thirty-nine keywords

```
and       array     begin     bool      break     char      const     continue
div       do        downto    else      end       false     for       forward
function  if        include   int       mod       not       of        or
procedure real      record    return    schema    shl       shr       str
then      to        tools     true      type      var       while
```

**Case does not distinguish names.** `Foo`, `foo` and `FOO` are one name, and so are
`STORE.SET` and `store.set` — a constant in capitals beside a routine in lower case is a
collision, not a convention.

## A program

```pascal
include "io.wz";           // other files, before anything else

const
  MAX = 100;
  GREETING = "hello";

type
  Point = record
    x: int;
    y: int;
  end;

var
  count: int;
  grid:  array[0..MAX - 1] of Point;

function twice(n: int): int;
begin
  return n * 2;
end;

procedure greet(who: str);
begin
  io.puts(STDOUT, who);
end;

begin                      // the main block, last
  count := twice(21);
  greet(GREETING);
end.                       // a full stop, not a semicolon
```

The order is fixed: includes, then declarations, then the main block. There is no header
line — a file starts with its first declaration. A routine must be declared before it is
used, or declared `forward` first.

## Types

| | |
|---|---|
| `int` | a 64-bit signed integer |
| `real` | a 64-bit float |
| `bool` | `true` or `false` |
| `char` | one byte |
| `str` | a string **literal**; not a buffer you build |
| `array[a..b] of T` | fixed size, known when it compiles |
| `record ... end` | fields, no methods, no inheritance |

There is one type per concept: no `integer` beside `int`, no `single` beside `real`. Text you
assemble lives in an `array of char`, and `str` is what you write between quotes.

```pascal
var
  n:    int;
  ratio: real;
  ok:   bool;
  c:    char;
  name: str;
  buf:  array[0..255] of char;
  line: array[0..9] of array[0..79] of char;
```

## Declaring

```pascal
const
  MAX = 100;                    // the type follows from the value
  PI  = 3.14159;

type
  Colour = record
    r, g, b: int;               // several names, one type
  end;

var
  i, j, k: int;                 // the same
  p: Colour;
```

## Routines

A `function` returns a value and a `procedure` does not. Parameters are passed by value,
except an `array of T`, which is passed as a reference and its length travels with it.

```pascal
function area(w: int; h: int): int;
begin
  return w * h;
end;

procedure fill(a: array of char; c: char);
var i: int;                     // locals go here, before begin
begin
  i := 0;
  while i < len(a) do begin a[i] := c; i := i + 1; end;
end;

function later(n: int): int; forward;      // declared now, defined below
```

A function that reaches its `end` without a `return` is a runtime error, not a silent zero.

## Statements

```pascal
x := 1;                                    // assignment
greet("hi");                               // a call

if x > 0 then y := 1;                      // one statement
if x > 0 then y := 1 else y := 2;

if x > 0 then                              // several: begin ... end
begin
  y := 1;
  z := 2;
end;

while x < 10 do x := x + 1;

for i := 1 to 10 do total := total + i;
for i := 10 downto 1 do total := total + i;

while true do
begin
  if done then break;                      // leave the loop
  if skip then continue;                   // next turn
end;

return v;                                  // from a function
return;                                    // from a procedure
halt(1);                                   // end the program with an exit code
```

Note the semicolons: they **separate** statements. The one before `end` is optional, and
`end.` closes the program.

## Operators

| | |
|---|---|
| arithmetic | `+` `-` `*` `/` `div` `mod` |
| comparison | `=` `<>` `<` `<=` `>` `>=` |
| logical | `and` `or` `not` |
| bitwise | `shl` `shr`, and `band` `bor` `bxor` as builtins |

`/` is real division and `div` is integer division; mixing them by accident is the kind of
thing the type check refuses rather than rounds.

**There is no `++`, no `+=`, no `?:` and no assignment inside an expression.** One way per
concept.

## Comments

```pascal
// to the end of the line
```

That is the only form. `{ }` was removed in 0.2.0: it ended at the first `}`, so a brace
inside the comment text turned the rest of the sentence into code.

## Literals

```pascal
42          -1          1000000                        // integers
3.14        1.0e-9                         // reals
'a'         '\n'        '\x41'             // chars
"text"      "line\n"    "\x00\xff"         // strings
true        false                          // bools
```

`\xHH` takes **exactly two** hex digits, unlike C — so `"\x41BC"` is three characters, and a
generator can write a byte followed by a literal hex character without ambiguity.

## Names

A name starts with a letter and may contain letters, digits, underscores and dots. The dot is
an ordinary character, used to group things that belong together:

```pascal
calc.reset;
io.puts(STDOUT, "hi");
store.set(k, v);
```

That is a naming convention, not a module system — there is one flat namespace, and
`calc.reset` is simply a name with a dot in it. A part after a dot may start with a digit
(`Reading.level.1`); the first part may not.

## What is not here

No pointers, no heap, no `new`, no garbage collector. No classes, no inheritance, no
interfaces. No generics, no overloading, no operator overloading. No exceptions, no threads,
no closures, no lambdas. No implicit conversion between types.

Each of those is a decision rather than an omission, and
[`design.md`](design.md) argues them. The short version: a construct that costs more than it
gives is left out, because the reader of this code is usually a generator in a loop and every
extra way to say something is another way to get it wrong.
