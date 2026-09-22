# `io` — output, numbers, and little-endian byte access

`include "io.wz";`

The lowest layer: every other module in `lib/` builds on this one. There is no buffering
and no allocation — every call here is a syscall or a few instructions over a buffer you
already own. `io` also carries the two clock reads (`io.now`, `io.realtime`) because they
go through the same raw syscall path as everything else here.

## Writing

| | |
|---|---|
| `io.write(fd, a, n): int` | the raw `write(2)`; returns what the kernel returns (bytes written, or negative on error) |
| `io.read(fd, a, n): int` | the raw `read(2)`; same contract |
| `io.out(fd, a, n)` | a **procedure** — write and forget. Use it for output where a short write cannot be acted on anyway |
| `io.puts(fd, s: str)` | write a string **literal** straight to `fd`. `s` must be a literal, not a buffer — see the pitfall below |
| `io.putn(fd, v: int)` | write the decimal form of `v` to `fd` |
| `io.fatal(s: str)` | write `s` and a newline to `STDERR`, then `halt(1)` — never returns |

`io.out` is a procedure, not a function: it does not tell you how many bytes actually went
out. If you need that count, call `sys3(SYS.write, fd, addr(b[0]), n)` yourself.

`io.puts` only accepts a string literal (the `str` type), because that is the only thing
`slen`/`sadr` work on. For a buffer, use `io.out(fd, addr(b[0]), n)`.

```pascal
include "io.wz";

var
  buf: array[0..63] of char;
  n: int;

begin
  n := io.push(buf, 0, "count = ");
  n := io.pushnum(buf, n, 42);
  io.out(STDOUT, addr(buf[0]), n);
  io.puts(STDOUT, "\n");
end.
```

`STDIN`, `STDOUT`, `STDERR` are the three file descriptor constants.

## Building text in a buffer

| | |
|---|---|
| `io.push(b, at, s: str): int` | append the literal `s` to `b` at position `at`; returns the new position |
| `io.pushnum(b, at, v: int): int` | append the decimal form of `v`; returns the new position |
| `io.digits(v: int): int` | render `v` into the module's own scratch buffer (`io.nbuf`); returns the length. Only useful directly if you need the digits without writing them into your own buffer yet |

**Both appenders truncate rather than fail.** If `at` is already negative, it comes back
unchanged — that is what lets a `-1` from a *refusing* routine elsewhere (`json.putslice`,
a generated `<Schema>.write`) travel through a chain of `io.push` calls undamaged, to be
tested once at the end. If `at` is not negative but the buffer is full, `io.push` and
`io.pushnum` write as much as fits and return `len(b)` — a shortened message is still a
message, so there is no error to report. A caller that must know whether everything fit
compares the position that comes back with the one it passed in.

```pascal
n := io.push(buf, 0, "item");
n := io.pushnum(buf, n, 42);
if n >= len(buf) then ...   // it truncated
```

## Little-endian byte access

| | |
|---|---|
| `io.put32(b, at, v)` | write `v` as 4 bytes, little-endian |
| `io.get16(b, at): int` | read 2 bytes as an unsigned little-endian value |
| `io.get32(b, at): int` | read 4 bytes |
| `io.get64(b, at): int` | read 8 bytes |

These do no bounds checking of their own beyond the array they are given — `b[at + 3]` for
`io.put32` is an ordinary indexed access, so it is checked the same way any array access
is, against the length of `b`.

## Clocks

| | |
|---|---|
| `io.now: int` | monotonic nanoseconds; for measuring elapsed time |
| `io.realtime: int` | wall-clock nanoseconds since the Unix epoch |

**Both stop the program rather than return a wrong time.** If the underlying
`clock_gettime` fails, the timespec it was supposed to fill is left untouched, so decoding
it anyway would silently hand back whatever the previous reading was (or a zero timestamp
on the very first call, which decodes as 1 January 1970). Since a wrong time that gets
stored is afterwards indistinguishable from a real one, `io.now` and `io.realtime` call
`io.fatal` instead of returning a bad value. This case does not arise on Windows, where the
equivalent call cannot fail.

Use `io.now` for elapsed time and `io.realtime` for calendar time (it is what
`time.nowsec` and the request logging in `lib/http.wz` build on).

## What is not here

`io` has no formatted output beyond decimal integers — no float formatting (`json.putreal`
does that), no padding, no field width. It also has no line-oriented reading; scanning
input is `json`'s job once bytes are in a buffer, and getting bytes into that buffer in the
first place is `io.read` or `fs`.
