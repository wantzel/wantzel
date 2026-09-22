# `math` — real arithmetic beyond the operators

`include "math.wz";` (pulls in `json.wz`, and through it `io.wz`)

Everything here is plain Wantzel over the `real` type: range reduction plus a short
series, so results are identical on Linux and Windows and there is no dependence on a C
math library. Accuracy is a few units in the last place over the ranges the routines were
built for; nothing here claims IEEE-754-exact results in every corner (`0/0`, huge
exponents), and the routines that behave specially near their domain edges say so below.

## Constants

`MATH.PI`, `MATH.E`, `MATH.LN2`, `MATH.HALFPI`, `MATH.TWOPI`.

## Basic

| | |
|---|---|
| `math.abs(x): real` | absolute value |
| `math.max(a, b): real` | larger of the two |
| `math.min(a, b): real` | smaller of the two |
| `math.floor(x): real → int` | largest `int <= x`; **`x` must fit in an `int`** |
| `math.ceil(x): real → int` | smallest `int >= x`; same requirement |
| `math.isnan(x): bool` | is `x` a NaN? (the only reliable way to ask — a NaN compares unequal to itself, which is exactly what this checks) |

`math.floor`/`math.ceil` return an `int`, not a `real` — there is no `real`-to-`real`
rounding-toward-integer here beyond that. Passing a value too large to fit in an `int`
(roughly beyond ±9.2e18) is not checked and produces a meaningless result, the same way
`trunc` on such a value would.

## Powers, exponentials and logarithms

| | |
|---|---|
| `math.pow2i(k: int): real` | `2^k` for an integer `k`, exact (built from doublings, never an approximation) |
| `math.powi(x: real; n: int): real` | `x^n` for an integer `n`, by repeated squaring |
| `math.pow(x, y: real): real` | `x^y` for real `x` and `y`. Uses `math.powi` when `y` is (numerically) a whole number, otherwise `exp(y * ln(x))`, which requires `x > 0` |
| `math.exp(x): real` | `e^x`. Saturates rather than overflowing: `+inf`-shaped for `x > 709.7`, `0.0` for `x < -745.0` |
| `math.log(x): real` | natural logarithm. NaN for `x < 0`; a very large negative value (not a proper `-inf`, since there is no such literal) for `x = 0` |
| `math.log10(x): real` | base-10 logarithm |
| `math.log2(x): real` | base-2 logarithm |

`math.pow` with `x < 0` and a non-integer `y` returns NaN (a negative base to a
fractional power is not a real number). With `x = 0`: `0^y` is `0.0` for `y > 0` and an
overflow-shaped value for `y <= 0`, matching the usual convention.

```pascal
include "math.wz";

var
  buf: array[0..31] of char;
  n: int;
  x: real;

begin
  x := math.pow(2.0, 10.0);
  n := math.fixed(buf, 0, x, 2);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");

  n := math.fixed(buf, 0, math.sin(MATH.HALFPI), 4);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

## Trigonometry

| | |
|---|---|
| `math.sin(x): real` | sine |
| `math.cos(x): real` | cosine |
| `math.tan(x): real` | tangent (`sin / cos`; not specially guarded near the poles, so it grows very large rather than erroring there) |
| `math.asin(x): real` | arcsine; NaN outside `[-1, 1]` |
| `math.acos(x): real` | arccosine; inherits `math.asin`'s NaN outside `[-1, 1]` |
| `math.atan(x): real` | arctangent |
| `math.atan2(y, x): real` | two-argument arctangent, the angle of the point `(x, y)` |
| `math.radians(deg): real` | degrees to radians |
| `math.degrees(rad): real` | radians to degrees |

All six trig functions accept and propagate NaN (a NaN in, a NaN out, no error) except
where the domain itself excludes a value (`asin`/`acos` outside `[-1, 1]`).

## Text

| | |
|---|---|
| `math.fixed(dst, at, x: real, decimals: int): int` | write `x` with exactly `decimals` digits after the point (clamped to `0..15`), rounded half away from zero; returns the new position |
| `math.text(dst, at, x: real): int` | the shortest general form (up to 15 significant digits) — this is `json.putreal` under another name, for use where "the general real-to-text form" reads better than reaching into `json` for it |
| `math.parse(s: array of char): real` | parse a decimal number from `s`; sets `math.ok` |

`math.fixed` falls back to the general form (`json.putreal`) for values beyond roughly
9e15, where a fixed number of decimals stops being meaningful.

**`math.parse` signals failure through `math.ok`, not through its return value** — `0.0`
is both a legitimate parsed value and what a failed parse returns, so the two are
indistinguishable without checking the flag:

```pascal
include "math.wz";

var
  s: array[0..15] of char;
  n: int;
  v: real;
  buf: array[0..31] of char;

begin
  n := io.push(s, 0, "3.5");
  v := math.parse(s[0..n - 1]);
  if math.ok then
  begin
    n := math.fixed(buf, 0, v, 1);
    io.out(STDOUT, addr(buf[0]), n);
    io.puts(STDOUT, "\n");
  end
  else io.puts(STDOUT, "not a number\n");
end.
```

`math.ok` is also `false` when `s` is only a **partial** number — `math.parse` requires
the entire slice to be consumed as one number, not just a prefix of it.

## What is not here

No hyperbolic functions, no complex numbers, no statistics (mean, standard deviation —
those belong to whatever application needs them, built from `+`/`*`/`/` directly), and no
arbitrary-precision arithmetic. `math.pow`/`math.exp`/`math.log` are tuned for the ranges
an ordinary application needs, not for numerical-analysis edge cases.

## What this page leaves out

Three routines in `math.wz` are not listed above: `math.reduce`, `math.sinr` and
`math.cosr`. They are the range reduction and the series behind `math.sin` and `math.cos` —
`sin` reduces the angle into a quadrant and then calls `sinr` or `cosr` on what is left.

Call `math.sin` and `math.cos`. The three take an already-reduced argument and give a wrong
answer, silently, for anything outside the first quadrant.
