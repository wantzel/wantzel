# X11 from a socket: the protocol, the fonts, and the silent failures

*Measured 15 September 2026 while building a working calculator with no toolkit.*

An X11 program is a program that opens a Unix socket and speaks a binary protocol on it.
There is no library involved — no Xlib, no toolkit, nothing to install. That is why it suits
a language with no dependencies, and the whole cost is knowing what the protocol demands.

## What the protocol needs, in order

Each step has a visible result, so it is obvious where it breaks.

1. **The handshake.** Send byte order (`l` for little-endian), protocol 11.0 and an empty
   auth field; read the reply. The reply carries what everything else needs: the root
   window, the **resource-id base and mask**, and the visual. Print those numbers — without
   the base you cannot construct a single id.
2. **CreateWindow + MapWindow.** Two requests, and an empty window appears.
3. **A graphics context and text.** CreateGC, then PolyText8 in response to an Expose event.
   This is where the event loop starts: read 32-byte events from the socket and react to
   Expose (12).
4. **Closing cleanly**, on a key press or on the window being closed.

Roughly five or six request types for a window with text in it.

## The thing that makes X11 hard to debug

**Errors arrive asynchronously.** You send a malformed request, the program carries on, and
the error turns up later — or not at all, if nothing reads the socket. So the failure mode
is almost never a message. It is **"nothing happened"**.

That single fact explains every trap below. **Read the socket while developing**, even when
you do not need a reply, or you are debugging blind.

## The traps

- **Lengths are in units of four bytes, not bytes.** The classic first mistake, and it
  produces errors that look unrelated to the request that caused them. A CreateWindow
  declared as 10 words when the request was 8 gives `BadLength` — against a request that
  looks correct.
- **Every request is padded to a multiple of four.** Forget it once and the stream is out of
  step from there on.
- **Two different things are called "mask".** The *value mask* of CreateWindow says which
  attributes follow; the *event mask* is one of those attributes. Putting an event bit
  (`ExposureMask`, 32768) into the value mask gives `BadValue`, because 32768 is not a valid
  attribute bit. The correct value mask for background, backing store and events is
  `2 + 64 + 2048`, with the three values following in bit order.
- **You build resource ids yourself**: `id := base bor (n band mask)`. You do not ask the
  server for them.
- **The handshake reply is variable length** (screens, visuals). Read the length from the
  header and skip the rest, rather than assuming a fixed offset.

## Fonts: the field that matters and the zeros that matter more

An X Logical Font Description has fourteen fields:

```
-foundry-family-weight-slant-setwidth-style-PIXELS-points-resx-resy-spacing-width-charset-encoding
-adobe-helvetica-bold-r-normal--18-0-0-0-p-0-iso8859-1
```

Two things matter far more than the rest:

1. **The seventh field is the pixel height.** That is your size.
2. **Zeros in the fields after it ask for a SCALABLE font.** `18-0-0-0-p-0` means "render
   this at 18 pixels" and the server scales. A *fixed* size the server does not happen to
   have simply fails.

And that failure is silent, for the reason above: `OpenFont` on a name the server cannot
match returns an error asynchronously, the graphics context keeps its default font, and the
program draws in the 6-pixel built-in. Which looks like "setting the font did nothing".

```
-*-helvetica-bold-r-normal--17-*-*-*-*-*-iso8859-1     <- fails, silently
-adobe-helvetica-bold-r-normal--18-0-0-0-p-0-iso8859-1 <- works, any size
```

### Find out what the server actually has

`ListFonts` (opcode 49) answers with names. On one machine it returned 200, and **every one
had `0-0-0-0`** — all scalable, no fixed bitmap sizes at all. So asking for `-18-` as a fixed
size could never have matched.

Verify by opening them rather than assuming: `-adobe-helvetica-bold` and `-adobe-times-bold`
at 28px were accepted, `-urw-nimbus sans-bold` was refused. The refusal is an error you will
not see unless you read the socket.

### Core fonts are not anti-aliased

This is a property of the protocol, not a setting. The X11 core font system predates
anti-aliasing; smooth text on a modern Linux desktop comes from Xft/FreeType rendering
client-side and sending *images*, not from the core font requests.

So text drawn this way has hard edges. For a demonstration that is acceptable and worth
naming rather than hiding. Genuinely smooth text means rendering glyphs yourself and sending
them as an image — a different and much larger exercise.

## Why X11 and not Wayland

Wayland is the modern answer, so this is a real choice.

**X11 is far cheaper for a first window.** The protocol has drawing primitives, so a
rectangle and a line of text are a request each. Wayland has none: it hands you a pixel
buffer through shared memory (`wl_shm`), and everything on screen is something you rendered
yourself, with `xdg-shell` on top before you even get a title bar. It is also XML-defined
with version negotiation, which is more surface to get wrong.

**X11 still works everywhere that matters**, including on Wayland desktops through Xwayland.

The honest counterpoint: X11 is being retired on pure Linux desktops, so this is the right
choice for a first window and probably not the last word.

## What this side does not need

No callback, no window procedure, and therefore no language feature. Events arrive on the
socket and the program reads them in its own loop. The Windows side of the same application
requires a construct the compiler had to grow — see [`../internals/callbacks.md`](../internals/callbacks.md).
That asymmetry is worth keeping in view when reading either document.
