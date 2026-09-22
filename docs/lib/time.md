# `time` — calendar time without a time zone

`include "time.wz";` (pulls in `io.wz`)

A moment is an ordinary `int`: seconds since `1970-01-01T00:00:00Z`, negative before it.
The calendar is proleptic Gregorian, everything is UTC, and there are no zones, no DST and
no leap seconds. The day arithmetic (Howard Hinnant's days-from-civil algorithm) is exact
for years 1..9999 and well beyond in both directions.

## Converting between a moment and a calendar date

| | |
|---|---|
| `time.days(y, m, d): int` | days since 1970-01-01 for the civil date `y-m-d` |
| `time.join(y, m, d, hh, mm, ss): int` | the full moment (seconds since the epoch) for a civil date and time |
| `time.split(t: int)` | the inverse: fills `time.year`, `time.month` (1..12), `time.day` (1..31), `time.hour`, `time.minute`, `time.second`, `time.weekday` (0 = Monday .. 6 = Sunday), `time.yday` (0 = January 1st) from a moment |
| `time.leap(y: int): bool` | is `y` a leap year? |
| `time.daysin(y, m: int): int` | how many days are in month `m` of year `y`; `0` for a month outside `1..12` |

`time.split` is a procedure, not a function — it writes into the module's own globals
rather than returning a record (there is no record return in Wantzel). Read the fields
immediately after calling it, before anything else in the program calls `time.split` or
`time.iso` again (which calls `time.split` itself).

## Formatting and parsing ISO 8601

| | |
|---|---|
| `time.iso(dst, at, t: int): int` | write `t` as `YYYY-MM-DDTHH:MM:SSZ` (20 characters for a year in `0..9999`; more digits for a year outside that range) to `dst` at `at`; returns the new position |
| `time.parseiso(s: array of char): int` | parse an ISO 8601 timestamp; returns the moment, and sets `time.ok` |
| `time.pad(dst, at, v, w: int): int` | write `v` as exactly `w` zero-padded decimal digits; used internally by `time.iso`, rarely needed directly |
| `time.num(s, at, n: int): int` | read exactly `n` decimal digits at `s[at]`; `-1` if any of them is not a digit |

```pascal
include "time.wz";

var
  buf: array[0..31] of char;
  n: int;

begin
  n := time.iso(buf, 0, 0);                    // the epoch itself
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

`time.parseiso` accepts the shapes produced by Python's `datetime.isoformat()` and by
Postgres:

```
2026-09-11                     a bare date, read as midnight UTC
2026-09-11T12:00:00            no zone, read as UTC
2026-09-11T12:00:00.123456     a fractional part, scanned over and dropped
2026-09-11T12:00:00Z           explicit UTC
2026-09-11T12:00:00+02:00      an offset, subtracted to give UTC
```

A space is accepted in place of the `T`, as Postgres writes it.

**`time.parseiso` signals failure through `time.ok`, not through its return value.** `-1`
is itself a valid moment (`1969-12-31T23:59:59Z`), so a caller that only checks the return
value against `-1` will treat a genuine moment one second before the epoch as a parse
failure, and — the more dangerous direction — will treat an actual parse failure that
happens to compute to some other value as success. Always test `time.ok` after the call:

```pascal
include "time.wz";

var
  s1: array[0..15] of char;
  s2: array[0..25] of char;
  n1, n2: int;
  t1, t2: int;

begin
  n1 := io.push(s1, 0, "2026-09-11");
  t1 := time.parseiso(s1[0..n1 - 1]);
  io.putn(STDOUT, t1); io.puts(STDOUT, " ");
  if time.ok then io.puts(STDOUT, "ok\n") else io.puts(STDOUT, "bad\n");

  n2 := io.push(s2, 0, "2026-09-11T12:00:00+02:00");
  t2 := time.parseiso(s2[0..n2 - 1]);
  io.putn(STDOUT, t2); io.puts(STDOUT, " ");
  if time.ok then io.puts(STDOUT, "ok\n") else io.puts(STDOUT, "bad\n");
end.
```

## The current time

| | |
|---|---|
| `time.nowsec: int` | the current moment, in seconds since the epoch (`io.realtime div 1000000000`) |

`time.nowsec` calls `io.realtime` underneath, so it shares that routine's failure
behavior: if the system clock cannot be read, the program stops (`io.fatal`) rather than
returning a wrong time — see `docs/lib/io.md`.

## What is not here

There are no time zones beyond UTC (an offset in `time.parseiso` is only ever subtracted
to reach UTC, never kept), no duration/interval type, and no calendar arithmetic beyond
the moment ↔ civil-date conversion above (adding "one month" is not a fixed number of
seconds and is left to the caller to define for its own purposes).
