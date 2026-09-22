# `fs` — directories, file metadata and byte search

`include "fs.wz";` (pulls in `io.wz`)

Read-only: nothing in `fs` creates, writes, renames or deletes anything. Opening a file
for reading and opening it for writing/creating both go through `sys3(SYS.open, ...)`
directly with the flag constants from `io.wz` — `fs.open` is a convenience for the
read-only case, nothing more.

## Metadata

| | |
|---|---|
| `fs.stat(a: int): bool` | fill `fs.size`, `fs.mode`, `fs.mtime` for the NUL-terminated path at address `a`; `false` if the path does not exist or is not reachable |
| `fs.isdir: bool` | is the mode from the last `fs.stat` a directory? |
| `fs.isfile: bool` | is it a regular file? |

`fs.stat` takes a raw address, not a `str` or an `array of char` — the path must already
be NUL-terminated in memory, because it goes straight into a syscall. Build it with
`io.push` and add the terminator yourself:

```pascal
include "fs.wz";

var
  path: array[0..15] of char;
  n: int;

begin
  n := io.push(path, 0, "/tmp");
  path[n] := chr(0);
  if fs.stat(addr(path[0])) then
  begin
    if fs.isdir then io.puts(STDOUT, "directory\n")
    else io.puts(STDOUT, "not a directory\n");
  end
  else io.puts(STDOUT, "stat failed\n");
end.
```

`fs.isdir`/`fs.isfile` read `fs.mode`, which `fs.stat` fills — calling either one before a
successful `fs.stat` reads whatever the last call left there.

## Opening and reading

| | |
|---|---|
| `fs.open(a: int): int` | open the NUL-terminated path at `a` read-only; returns the file descriptor, or a negative value on failure |
| `fs.opendir(a: int): int` | the same, but for reading directory entries (`O_DIRECTORY`); also resets the module's internal directory cursor |
| `fs.close(fd)` | close a file descriptor |
| `fs.next(fd): bool` | step to the next directory entry, skipping `.` and `..`; fills `fs.name`, `fs.namelen`, `fs.type`. `false` once the directory is exhausted |

`fs.next` reads and buffers directory entries internally (`fs.dbuf`), refilling that
buffer with a `getdents` call whenever it runs out; you never see that buffer, only the
one entry at a time in `fs.name[0..fs.namelen)`. `fs.type` is one of the `DT_*` constants
(`DT_DIR`, `DT_REG`, `DT_LNK`) taken directly from the kernel's directory entry.

```pascal
include "fs.wz";

var
  path: array[0..15] of char;
  n, fd, count: int;

begin
  n := io.push(path, 0, "/tmp");
  path[n] := chr(0);
  fd := fs.opendir(addr(path[0]));
  if fd < 0 then io.fatal("cannot open directory");
  count := 0;
  while fs.next(fd) do count := count + 1;
  fs.close(fd);
  io.puts(STDOUT, "entries seen: ");
  io.putn(STDOUT, count);
  io.puts(STDOUT, "\n");
end.
```

## Searching bytes

| | |
|---|---|
| `fs.find(h, from, upto, n, nlen): int` | find the first occurrence of `n[0..nlen)` inside `h[from..upto)`; returns the index, or `-1` if absent |

This is not file-specific — it works on any two `array of char` values, and is used for
scanning file content already read into a buffer. It locates the first byte of `n` with
the SIMD `scan` builtin before comparing the rest, so a search over a large haystack with
a rare leading byte runs close to `memchr` speed rather than a byte-by-byte loop. An empty
needle (`nlen = 0`) matches immediately at `from`.

## What is not here

`fs` has no writing, creating, deleting or renaming — those go through `sys3`/`sys2`
directly with the constants defined in `io.wz` (`O_CREAT`, `O_TRUNC`, `SYS.unlink`,
`SYS.rename`, `SYS.mkdir`, `SYS.rmdir`, ...). There is also no recursive directory walk;
`fs.opendir`/`fs.next` gives you one directory at a time, and recursing into
subdirectories (using `fs.type = DT_DIR` to decide) is left to the caller.
