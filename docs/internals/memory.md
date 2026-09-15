# Memory in Wantzel: arrays, indexes, slices, `view` and `mmap`

*Written 11 September 2026; examples re-checked against the compiler on 15 September.*

Wantzel has no heap, no pointers and no garbage collector. This document
explains how you do work with large chunks of data, with lists whose length
is unknown up front, with dicts and sets, and with files that do not fit in
memory. All examples are in
`tests/lang/memory_patterns.wz` and run in the test suite.

## 1. The model in three sentences

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

## 2. A list: array + counter

```pascal
const MAXITEMS = 1000;
type Item = record
  key: int;
  weight: real;
end;
var
  items: array[0..MAXITEMS - 1] of Item;
  nitems: int;                              // how many are filled

function items.add(key: int; w: real): int;   // returns the index, or -1
begin
  if nitems >= MAXITEMS then return -1;       // a clean error, not an OOM
  items[nitems].key := key;
  items[nitems].weight := w;
  nitems := nitems + 1;
  return nitems - 1;
end;
```

Growing is `nitems := nitems + 1`. Removing is either copying the last one
over it (`items[i] := items[nitems - 1]; nitems := nitems - 1`, order is
lost) or a free list (§4). The upper bound is a constant that you change
with a recompile; above the bound you get `-1`, never corruption. This is
exactly how the compiler keeps its symbol tables and how the HTTP server
keeps its connections.

Passing a list on: `total(items[0..nitems - 1])` gives a view on the filled
part; the receiver sees `len(a)` elements and cannot go outside them.

## 3. Text of unknown length: one arena + slices

```pascal
var
  arena: array[0..1048575] of char;         // 1 MB for all texts together
  used: int;

// store text; returns the start position (the "pointer"), -1 if full
function text.store(s: array of char): int;
var i, at: int;
begin
  if used + len(s) > len(arena) then return -1;
  at := used;
  for i := 0 to len(s) - 1 do arena[used + i] := s[i];
  used := used + len(s);
  return at;
end;
```

A text is then `(at, n)`; you pass it on as the slice
`put(arena[at..at + n - 1])`. A record keeps `name_at` and `name_n`
instead of a pointer. This is how `lib/json.wz` (`json.sat/json.send`),
`lib/http.wz` (`http.pathat/pathlen`) and the schema views (`f_at/f_end`)
work.

## 4. Linked structures: indexes as references

```pascal
const NIL = -1;
type Node = record
  value: int;
  next: int;                                // index of the next one, or NIL
end;
var
  nodes: array[0..255] of Node;
  free: int;                                // head of the free list
  head: int;                                // head of the used list

procedure nodes.init;
var i: int;
begin
  for i := 0 to len(nodes) - 1 do nodes[i].next := i + 1;
  nodes[len(nodes) - 1].next := NIL;
  free := 0;
  head := NIL;
end;

function nodes.alloc: int;                  // an allocator of five lines
var i: int;
begin
  if free = NIL then return NIL;
  i := free;
  free := nodes[i].next;
  return i;
end;

procedure nodes.release(i: int);
begin
  nodes[i].next := free;
  free := i;
end;
```

Trees (`left`, `right`), queues (`head`, `tail`), and graphs work the same
way. The difference with a heap: `nodes.alloc` can only return `NIL` (never
a crash in the middle of a request), and a `release` of an index that is
still in use is visible in the code instead of being a use-after-free.

## 5. Dict and set: a hash table on two arrays

```pascal
const HSIZE = 1024;                         // a power of two, > 2× the number of keys
var
  hkey: array[0..HSIZE - 1] of int;         // 0 = empty
  hval: array[0..HSIZE - 1] of int;
  hcount: int;

function hash.slot(key: int): int;          // open addressing, linear probing
var i: int;
begin
  i := band(key * 2654435761, HSIZE - 1);   // Knuth's multiplication
  while (hkey[i] <> 0) and (hkey[i] <> key) do i := band(i + 1, HSIZE - 1);
  return i;
end;

function hash.put(key: int; v: int): bool;
var i: int;
begin
  if hcount * 2 >= HSIZE then return false; // keep the table half full
  i := hash.slot(key);
  if hkey[i] = 0 then hcount := hcount + 1;
  hkey[i] := key;
  hval[i] := v;
  return true;
end;

function hash.get(key: int): int;           // -1 if absent
var i: int;
begin
  i := hash.slot(key);
  if hkey[i] = 0 then return -1;
  return hval[i];
end;
```

Text keys: hash the bytes (FNV-1a) to an `int`, keep the text in the arena
of §3 and compare the bytes on a hit. A set is the same table without
`hval`. You remove with tombstones or by rebuilding; if keys almost never
disappear, rebuilding is enough.

## 6. `view(addr, n)`: any address as an array

`view` turns an address and a number of elements into an ordinary
`array of T` view, with a bounds check. It is the only unsafe primitive
besides `sys*`: if the address is wrong, that is your mistake. Three uses:

```pascal
// 1. reinterpreting bytes: the 32 bytes of four ints as chars
sumb(view(addr(words[0]), 32));

// 2. part of a large array without a copy
fill(view(addr(bytes[8]), 8), 'x');        // the same as fill(bytes[8..15], 'x')

// 3. memory that does not come from a declaration: mmap, kernel buffers, argv
fill(view(p, 1048576), chr(0));            // p comes from mmap (§7)
```

The element type follows from the parameter that receives it: `procedure
f(a: array of real)` and `f(view(p, n))` gives `n` reals from `p` onward.
`view` exists only as an argument; it is not a value that you keep. Keep
the address (`int`) and make the view at the moment you need it.

## 7. `mmap`: files and large regions as memory

`mmap` asks the operating system for an address range that either lies on a
file or is anonymous (zeroes, from virtual memory). The kernel only fetches
pages when you touch them and writes them back on `msync` or `munmap`.
On Windows the runtime translates this to `CreateFileMapping`/`MapViewOfFile`.

```pascal
include "lib/io.wz";

// a region of 64 MB whose size is only fixed at startup
p := sys6(SYS.mmap, 0, size, bor(PROT_READ, PROT_WRITE), bor(MAP_PRIVATE, MAP_ANONYMOUS), -1, 0);
if p < 0 then io.fatal("no memory");
fill(view(p, size), chr(0));
sys2(SYS.munmap, p, size);

// a file as an array: reading without read(), writing without write()
fd := sys3(SYS.open, addr(path[0]), O_RDWR, 0);
p := sys6(SYS.mmap, 0, filesize, bor(PROT_READ, PROT_WRITE), MAP_SHARED, fd, 0);
bump(view(p, filesize));                   // changes land in the file
sys3(SYS.msync, p, filesize, 4);           // MS_SYNC: now on disk as well
sys2(SYS.munmap, p, filesize);
sys1(SYS.close, fd);
```

Rules:

- `mmap` returns an address (`int`), or a negative errno. The address
  is a multiple of 4096.
- You make a file larger before mapping it, with `ftruncate`; a view
  beyond the end of the file gives SIGBUS.
- `MAP_SHARED` shares with the file (and with other processes that map it),
  `MAP_PRIVATE` is copy-on-write and does not touch the file.
- Thousands of separate mappings cost address space and descriptors: rather
  map one large file with an offset index than a file per object. That is
  the design of `lib/store.wz`.
- `mmap` and `view` are how a service reaches "one memory space": the file
  is the memory, the writer writes to the socket from those same bytes,
  nothing is copied between "database" and "application".

## 8. Records on disk: the format is the memory layout

A `record` has a fixed layout (fields in declaration order, `char`/`bool`
on byte boundaries, the rest on 8 bytes, size a multiple of 8; see
`docs/language.md`). That makes an array of records directly a file format:

```pascal
// writing: the whole table in one write
sys3(SYS.write, fd, addr(items[0]), nitems * (addr(items[1]) - addr(items[0])));

// reading through mmap: the table is the file
p := sys6(SYS.mmap, 0, n * 16, PROT_READ, MAP_SHARED, fd, 0);
total(view(p, n));                          // procedure total(a: array of Item)
```

What you gain by it: no serialisation, no schema drift between memory and
storage, and a snapshot is a file copy. What you have to arrange: a version
number in a header, and indexes (§4) instead of addresses, because
addresses differ per run.

## 9. Which form when

| situation | form |
|---|---|
| number known and small (< a few MB) | static array + counter |
| number unknown, but a reasonable upper bound exists | static array with that bound; measure the bound with `tests/limits` |
| size only known at startup | anonymous `mmap` of that size + `view` |
| data that has to survive a restart | file + `mmap`, records as the format, indexes as references |
| larger than RAM | file + `mmap`; the kernel pages |
| temporary workspace per call | local array (stack, max 8 MB in total) or a slice of a global arena |
| key → value | hash table on arrays (§5) |
| references between objects | indexes in one table, free list for reuse (§4) |

What you never need: an allocator per object. Every structure gets one
reservation, at compile time or at startup, and inside it all references
are indexes.
