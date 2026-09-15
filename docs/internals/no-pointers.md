# No pointers, and why that is not a limitation

*Measured 15 September 2026. Nine structures built and run; the failing case is named at the
end rather than left out.*

Wantzel has no pointers, no heap and no garbage collector, and it does not need them for
data. Not as a trade-off accepted for safety — **every linked structure that normally
justifies pointers has been built and runs**, and two of them are safer this way.

There is exactly one thing that cannot be done. It is a function address rather than a data
pointer, and it is described below rather than smoothed over.

## The substitution

Where another language stores an address, this one stores the **index** of the element.
`-1` means "none". Three properties follow, and they are the entire argument:

| | a pointer | an index |
|---|---|---|
| can it dangle? | yes — that is the classic bug | **no**, there is nothing to free |
| is it checked? | no | **yes**, at every use, against both bounds |
| does it survive being written to disk? | no, addresses change | **yes**, it means the same thing |

Memory comes from one reservation — a global array, or `mmap` turned into an ordinary array
with `view` — and inside that reservation every reference is a number.

## What was built to test it

`examples/structures.wz` builds four shapes and checks each against an answer written out by
hand. It is also `tests/lang/structures.wz`, so the claim cannot quietly stop being true:

```
list built     : 3 2 1
middle removed : 3 1
tree in order  : 20 30 40 50 60 70
graph w/ cycle : 0 1 2 3
after wiping   : 0
read back      : 20 30 40 50 60 70

all four shapes correct, and not one pointer
```

Byte-identical output on Linux and on Windows.

Beyond those four, five more were measured: a heterogeneous AST without variant records, a
free list for slot reuse (`lib/store.wz` does this in earnest), zero-copy views over a buffer
(`lib/kv.wz`, `lib/json.wz`), arbitrary operating system memory turned into an array, and a
window at an offset inside it. Nine of nine.

## The two that are better without pointers

**A graph with cycles.** Elsewhere, cycles are where ownership becomes hard: who frees what,
and what happens to the other references when they do. Here there is nothing to free, so a
cycle needs exactly one thing — a visited flag to stop the walk. The failure mode that makes
cyclic structures dangerous does not exist.

**A structure that survives a restart.** Because a link is an index, the array *is* its own
file format. Write the raw bytes, read them back, and every link still points where it did:

```pascal
n := sys3(SYS.write, fd, addr(nodes[0]), nnodes * 24);   // -> 20 30 40 50 60 70
   // ... memory wiped ...                               // -> 0
n := sys3(SYS.read,  fd, addr(nodes[0]), nnodes * 24);   // -> 20 30 40 50 60 70
```

No serialisation, no fix-up pass, no version field. With real pointers this cannot work at
all: every address would be wrong after loading.

## The escape hatch, for what the shapes do not cover

The argument above would be weak if it only said "everything we happened to need worked".
What makes it hold is that there is a **general mechanism**, in three layers:

1. **`sysN`** — the system call number is a plain constant and the compiler knows no call by
   name, so everything the operating system offers is reachable without touching the
   language. `fork`, shared memory and `flock` were each called impossible here before
   someone looked.
2. **`addr()` + `view()`** — any address plus a length becomes an ordinary array. Including
   memory the program never declared, and including a window at an offset:

   ```pascal
   base := sys6(SYS.mmap, 0, 4096, bor(PROT_READ, PROT_WRITE),
                bor(MAP_PRIVATE, MAP_ANONYMOUS), -1, 0);
   fill(view(base, 4096));         // -> ABCDEFGHIJKLMNOPQRSTUVWXYZABCD
   fill(view(base + 10, 100));     // -> KLMNOPQRST
   ```

   That second line is pointer arithmetic in every respect that matters — except the window
   carries its own length, so indexing inside it is still checked.
3. **the index as the pointer** — every data structure, as above.

So the answer to "what if I need something you did not think of" is not "then the compiler
changes". It is: an operating system facility goes through layer 1, a memory shape through
layer 2, a data structure through layer 3.

## Where it genuinely stops

**The address of your own routine.** `addr(twice)` is rejected. That rules out handing a
callback to foreign code, `qsort` with a comparator, and a dispatch table of addresses.

This is a **function** pointer, not a data pointer, and the two questions have different
answers. There is a route that adds nothing to the language — a fixed thunk in the runtime
that forwards to a forward-declared routine. See [`../internals/callbacks.md`](../internals/callbacks.md), where
Windows forced exactly that question into the open.

## What this does not prove

It does not prove no such case exists. It proves that nine were tried and none needed a
pointer, that two are actively better without one, and that the escape route has a shape you
can check rather than a promise you have to take.

Anyone who finds a case that breaks the list is welcome to it — that is more useful than
another one that fits.

## The caveats that travel with this

1. **An index cannot dangle, but it can point at the wrong row.** A zeroed link field means
   index 0, not "none" — so links are initialised to `-1` explicitly. Get that wrong and a
   node becomes its own child and the walk recurses until the stack runs out. That mistake
   happened while writing these very tests.
2. **`view` and `sys*` are unsafe primitives.** Nothing verifies the address or the length.
   Everything *inside* the view is checked; getting the view itself right is on the writer.
3. **This is about data.** The function-address gap is real and stated above.
4. **Nine cases is not a proof.**
