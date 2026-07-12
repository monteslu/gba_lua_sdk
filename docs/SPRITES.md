# Frame tables: `sprf` and `.gsi`

`spr(n)` draws sprites off an 8×8 grid — quick and PICO-8-familiar. When you want
**arbitrary-size sprites**, **per-frame draw offsets**, **animation frames**, or
sprites anywhere in a **full 256×256 sheet**, use a **frame table**: a `.gsi`
file listing named/numbered frames, drawn with `sprf`.

This is the GameTank console's own sprite model — a `.gsi` is the exact format
Clyde Shaffer's official SDK uses, so frame data made for GameTank drops straight
into gtlua.

## Drawing: `sprf(frame, x, y, [flipx], [flipy])`

```lua
sprf(3, px, py)              -- draw frame 3 at (px, py)
sprf(3, px, py, true)        -- flipped horizontally
sprf(3, px, py, false, true) -- flipped vertically
```

- `frame` is the frame's index in the table (0-based).
- `x, y` place the sprite (camera offset applies, like `spr`).
- `flipx`, `flipy` mirror it. Flipping works from **any** quadrant of the sheet.
- The frame's own size, source position, and draw offset come from the table —
  you don't pass width/height.

## The `.gsi` format

A `.gsi` is a packed array of **8-byte frame records**:

| offset | field | type  | meaning                                        |
|--------|-------|-------|------------------------------------------------|
| 0      | vxo   | int8  | draw X offset from the sprite's anchor         |
| 1      | vyo   | int8  | draw Y offset                                  |
| 2      | w     | uint8 | sprite width in pixels                         |
| 3      | h     | uint8 | sprite height in pixels                        |
| 4      | gx    | uint8 | source X in the sheet (0–255)                  |
| 5      | gy    | uint8 | source Y in the sheet (0–255)                  |
| 6–7    | —     | —     | reserved (0), for byte-for-byte SDK compat     |

`gx/gy` are pixel coordinates in the 256×256 sheet, so a frame can point into any
of the four quadrants; gtlua figures out the quadrant for you at build time. The
draw offset (`vxo/vyo`) lets frames of different sizes share a common anchor
(e.g. a walk cycle where each frame is a slightly different height) — the classic
use is centering: `vxo = -w/2, vyo = -h/2`.

## Building with a frame table

```
gtlua build main.lua --sheet art.gtg --frames art.gsi -o game.gtr
```

The frame table is baked into the ROM alongside the sheet. `sprf` reads it at
draw time. You can mix `spr(n)` (grid) and `sprf(frame)` (table) in the same game
on the same sheet.

## Making a `.gsi`

Frame tables come from your sprite layout. The most direct path today:

- **Author the numbers directly.** A `.gsi` is tiny and regular; a short script
  can emit one. gtlua's converter exposes `encodeGsi(frames)` in
  `compiler/gfx.mjs`:

  ```js
  import { encodeGsi } from "gametank-lua-sdk/compiler/gfx.mjs";
  import { writeFileSync } from "node:fs";
  const frames = [
    { vxo: -8, vyo: -8, w: 16, h: 16, gx: 0,  gy: 32 },  // hero idle
    { vxo: -8, vyo: -8, w: 16, h: 16, gx: 16, gy: 32 },  // hero walk 1
    { vxo: -8, vyo: -8, w: 16, h: 16, gx: 32, gy: 32 },  // hero walk 2
  ];
  writeFileSync("hero.gsi", encodeGsi(frames));
  ```

- **From Aseprite:** the official GameTank SDK exports `.gsi` from an Aseprite
  JSON sprite sheet (`sprite_metadata.js`); that output loads here unchanged.

(A `gtlua gfx frames` authoring command is a natural future addition; for now the
format above is the contract.)

## Grid vs. frame table — when to use which

| use `spr(n)` when…                        | use `sprf(frame)` when…                        |
|-------------------------------------------|------------------------------------------------|
| sprites are 8×8-aligned                   | sprites are arbitrary sizes                    |
| you want the quick PICO-8-style path      | you want animation frames / named frames       |
| your art fits the first 128×128 quadrant  | you use the full 256×256 sheet (all quadrants) |
| porting a PICO-8 game with minimal changes| authoring natively for GameTank                |

Both read the same `.gtg` sheet — you can start on the grid and add frame tables
where you need the extra reach.
