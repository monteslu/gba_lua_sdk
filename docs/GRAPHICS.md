# Sprite sheets: the `.gtg` format

gtlua uses the GameTank console's own sprite-sheet format, **`.gtg`** - the same
format Clyde Shaffer's official GameTank C SDK uses. That means art you make for
gtlua is real GameTank art: it drops straight into the official tooling, and
existing `.gtg` sheets load into gtlua unchanged.

You pass a sheet to the build with `--sheet`:

```
gtlua build main.lua --sheet art.gtg -o game.gtr
```

For the drawing API (`spr`, cell numbers) see `CHEATSHEET.md`; for how GameTank
colors look see `PALETTE.md`.

## The bytes

A `.gtg` is one **128×128 quadrant** of sprite data:

- **Exactly 16384 bytes** (128 × 128).
- **One byte per pixel.** Each byte is a **GameTank hardware color index** (0–255)
  - the full 256-color CAPTURE palette (the same color space `gt.rgb(r,g,b)`
  resolves into). This is the console's native pixel format; there is no palette
  table in the file, because the byte *is* the color.
- **Row-major, top to bottom, left to right.** Pixel `(x, y)` (both 0–127) is at
  `byteIndex = y * 128 + x`.
- **Color 0 is transparent** - it's the blitter's color key. Everything drawn
  through `spr` skips color-0 pixels, so 0 is your "nothing here" color.

```js
// read a pixel from a .gtg quadrant (JS)
function getPixel(gtg /* Uint8Array(16384) */, x, y) {
  return gtg[y * 128 + x];            // 0..255, a GameTank color index
}
```

That's the whole format: a flat 128×128 byte bitmap, no header. It's what the
runtime copies straight into the console's sprite RAM (GRAM) at load - no
unpacking, no conversion.

### Bigger sheets: four quadrants

A full GameTank sprite sheet is **256×256** - four 128×128 quadrants. When your
source art is larger than 128×128, it's split into up to four `.gtg` files, in
the standard order:

| file          | quadrant     | source region        |
|---------------|--------------|----------------------|
| `art.gtg`     | NW (top-left)| `(0,0)–(127,127)`    |
| `art_1.gtg`   | NE           | `(128,0)–(255,127)`  |
| `art_2.gtg`   | SW           | `(0,128)–(127,255)`  |
| `art_3.gtg`   | SE           | `(128,128)–(255,255)`|

`--sheet art.gtg` automatically picks up the sibling `art_1/_2/_3.gtg` files if
they exist, so you still pass just the one path. The build loads each quadrant
into its place in the 256×256 GameTank sheet.

## Cells (how `spr(n)` indexes it)

`spr(n)` addresses the sheet as a grid of **8×8-pixel cells**, PICO-8 style:

- **16 cells per row, 16 rows** in the first quadrant → cells `0–255`.
- Cell `n` is at pixel `(x, y) = ((n % 16) * 8, (n / 16) * 8)`.
- `spr(n, x, y)` blits cell `n`; `spr(n, x, y, w, h)` blits a `w×h`-cell sprite
  (e.g. `spr(64, x, y, 2, 2)` = a 16×16 sprite).

The grid `spr(n)` path reads sprite RAM the same way no matter how the sheet was
loaded, so **you don't change any Lua to use a `.gtg` sheet** - just build with
`--sheet art.gtg`. Your existing cell numbers keep working.

`spr(n)` reaches the first 128×128 quadrant (cells 0–255). To draw from the
other quadrants of a 256×256 sheet - or to use arbitrary sprite rectangles and
per-frame offsets - use a **frame table** (`.gsi`); see `SPRITES.md`.

## Making a `.gtg`: `gtlua gfx`

gtlua ships a converter so you can author in ordinary tools and import:

```
gtlua gfx import art.png            # PNG  -> art.gtg (+ art_1/_2/_3.gtg if >128px)
gtlua gfx import cart.p8            # a PICO-8 cart's __gfx__ -> a .gtg
gtlua gfx import art.png -o hero.gtg
gtlua gfx export hero.gtg           # .gtg -> hero.png, to edit and re-import
```

- **`import`** takes a PNG (any size up to 256×256), a PICO-8 `.p8` cart, or a raw
  `.gtg`, and writes `.gtg` quadrant(s). Every pixel is matched to the nearest of
  GameTank's 256 colors; fully-transparent pixels become color 0.
- **`export`** renders a `.gtg` back to a PNG so you can round-trip through an
  image editor. (The round-trip is visually lossless.)

The converter is zero-dependency (it uses Node's built-in zlib for PNG), so it
works anywhere gtlua runs.

### Authoring tips

- **Transparency:** paint your background/empty pixels with full alpha 0 in the
  PNG (or index 0 in a PICO-8 cart). They become color 0 = transparent.
- **Palette:** you can draw in any RGB colors - `import` snaps each to the closest
  GameTank color. To stay exactly on-palette, sample from the CAPTURE palette
  (`compiler/gt_palette.js` / `PALETTE.md`).
- **Layout for `spr(n)`:** keep sprites on the 8×8 grid so cell numbers line up.

## Coming from PICO-8

If you're porting a PICO-8 cart, `gtlua gfx import cart.p8` pulls its 128×128
sprite sheet straight into a `.gtg`. PICO-8's 16 colors map onto GameTank's
palette, so the art looks like it did in PICO-8 - and from there you have the
whole 256-color palette and a 256×256 sheet to grow into if you want. See
`PORTING.md` for the full PICO-8 → gtlua walkthrough.

## The legacy 4bpp `gfx.bin` (import input only)

Earlier gtlua used an 8192-byte 4bpp `gfx.bin` (two 4-bit PICO-8 color indices
per byte, 128×128). It is **no longer a sheet format**: `--sheet` accepts only a
native `.gtg`. `gtlua gfx import` still *reads* a `.bin` (or a `.png`, or a
PICO-8 cart) to produce a `.gtg`, so old art converts forward with one command:
`gtlua gfx import old-gfx.bin -o sheet.gtg`.

## Under the hood (build-time)

In the ROM, each `.gtg` quadrant is stored **packbits-compressed** (`.gtg` art is
mostly transparent color 0, so this is a big saving) and expanded straight into
GRAM at boot by `gt_gsheet_load_packed` - one byte per pixel, no palette lookup.
This is gtlua's stand-in for the official ROM's zopfli-deflate; the bytes that
land in sprite RAM are byte-for-byte identical either way.
