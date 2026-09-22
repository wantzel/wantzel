# X11 from a socket: the protocol, the fonts, and the silent failures

*Measured 15 September 2026 while building a working window with no toolkit.*

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

## When it renders, but it looks wrong

The traps above are about **nothing happening**. This one is worse: something *does* happen,
and it looks like a deliberate style rather than a fault. That is the most expensive kind of
bug in a drawing program, because it does not prompt you to debug at all — it prompts you to
adjust taste.

**Symptoms that mean "measure the data, not the picture":**

| what you see | what it usually is |
|---|---|
| everything looks faded, as if disabled | the coverage mask never reaches 255 |
| one shape is fine, another is a staircase | the smooth one is a mask, the other is drawn from rectangles |
| text is striped or sheared diagonally | rows not padded to four bytes |
| letters crowd into each other | the left side bearing was dropped |
| text sits too high or too low | the ascent is wrong, or its sign is |

**The rule: if you change a colour and nothing changes, the limit is not the colour.**
Alpha bounds what a colour can do, so a washed-out mark is an alpha problem until proven
otherwise. Raising saturation, thickening strokes and increasing sampling will all fail to
fix it, and each attempt looks plausible enough to spend a round on.

**Diagnose it by printing the data, not by looking at the window.** Parse the mask and print
the maximum coverage value and how many pixels reach it:

```
max coverage 31 of 255, 0 pixels fully covered   <- an alpha bug, in one line
max coverage 255, 130 of 400 fully covered       <- healthy
```

That measurement takes a second and cannot be argued with. One real case: a supersampling
loop counted `hits` for a pixel but carried a `break` after the first sample inside the
shape, so the count could never exceed the row length while the divisor stayed the full
sample count. Every mark was composited at 12% alpha. Three rounds of colour and geometry
changes preceded the one-line measurement that found it.

**The general form:** a fault that resembles a design decision survives far longer than one
that resembles a crash. When something looks merely *unattractive*, check that it is not
quietly broken before you start tuning it.

## Fonts: the field that matters and the zeros that matter more

> **Read this section as protocol reference, not as a recommendation.** If the interface has
> to look current, do not pick a core font at all — rasterise glyphs yourself and composite
> them through RENDER, as *When it renders, but it looks wrong* and the section on
> anti-aliasing below describe. The font names here are what a server offers and how to ask
> for them correctly; they remain useful for a quick window, a tool or a test, and they are
> what the traps below are about. None of them can produce anti-aliased text.


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

### Scalable is not the same as good — look for the bitmaps

The listing above is what one server had. **Do not conclude from it that bitmap fonts do not
exist.** On a second machine, measured 17 September 2026, the same `ListFonts` returned 967
names, and among them were hand-drawn bitmap fonts at 15, 16, 18, 20 and 24 pixels:

```
-misc-fixed-medium-r-normal--20-200-75-75-c-100-iso8859-1    monospace, 20px
-misc-fixed-medium-r-normal--18-120-100-100-c-90-iso8859-1   monospace, 18px
-sony-fixed-medium-r-normal--24-230-75-75-c-120-iso8859-1    monospace, 24px
```

The `20-200-75-75` instead of `20-0-0-0` is the whole difference: this glyph was *drawn* at
twenty pixels, not derived from an outline at run time.

**It is visibly better, and the gap is not small.** A scalable face asked for at 20px is
scaled by the server with no anti-aliasing at all — stems land between pixels and come out
uneven, which reads as a blurry, unreliable sort of text. The bitmap at the same size is
crisp, because someone chose where every pixel goes.

So the order to try is:

1. list what the server has, filtering for `-c-` or `-m-` (monospace) and a real pixel size
2. take the bitmap nearest the size you want
3. fall back to a scalable family only when there is no bitmap

To find them:

```
xlsfonts | grep -v -- '--0-0-0-0-' | grep -E -- '-c-|-m-'
```

### Core fonts are not anti-aliased

This is a property of the protocol, not a setting, and it holds for bitmap fonts too. The
X11 core font system predates anti-aliasing; smooth text on a modern Linux desktop comes
from Xft/FreeType rendering client-side and sending *images*, not from the core font
requests.

So text drawn this way has hard edges. A bitmap font at least avoids the *blurry* failure
that comes of letting the server scale an outline, but sharp-and-blocky is still the 1990s
look, and no choice of core font escapes it.

**If the interface has to look current, go straight to RENDER instead.** Rasterise the
glyphs yourself into 8-bit coverage masks, upload them to a glyph set, and composite them
with the colour as the source. It is more code than picking a font name, but it is a bounded
amount — and the alternative is spending that effort on font names that cannot reach the
result. Measured: a core font gives **2** coverage values per glyph, a rasterised one
**80 to 150**.

Two practical notes for that path, both of which fail silently:

- **Every row of a mask is padded to four bytes** — not the image, each row. Glyphs whose
  width is already a multiple of four look correct anyway, which makes the bug look like a
  font problem.
- **The left side bearing and the ascent travel with the mask**, and GLYPHINFO's x and y are
  *subtracted* from the draw position. Drop the bearing and letters crowd together; get the
  ascent wrong and the line sits at the wrong height.

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
