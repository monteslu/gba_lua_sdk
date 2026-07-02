# ports/ — PICO-8 games adapted for the GameTank

Playable gtlua adaptations of well-loved PICO-8 games. These are
**from-scratch reimplementations of each game's design** — no original cart
code or assets are used; graphics are gtlua primitives. Sprites/tiles/sound
arrive as the SDK grows (see PICO8.md); these will get closer to their
inspirations with each release.

Build any of them with:

```sh
node bin/gtlua.js build ports/<name>/main.lua
```

| Port | Inspired by | Original license | Controls |
|---|---|---|---|
| `cherry-bomb` | Cherry Bomb — Krystman / Lazy Devs (BBS 48986) | CC4-BY-NC-SA | d-pad move, 🅾️ shoot |
| `combo-pool` | Combo Pool — NuSan (BBS 3467) | CC4-BY-NC-SA | ⬅️➡️ aim, 🅾️ drop |
| `celeste-like` (summit) | Celeste Classic — Maddy Thorson & Noel Berry (BBS 2145) | none published; movement design reimplemented | ⬅️➡️ run, 🅾️ jump, ❎ dash |
| `ufo-swamp` | UFO Swamp Odyssey — Paranoid Cactus (BBS 38153) | CC4-BY-NC-SA | 🅾️ thrust, ⬅️➡️ steer |
| `jelpi` | Jelpi — zep's PICO-8 demo cart | none published; run/stomp design reimplemented | ⬅️➡️ run, 🅾️ jump |

GameTank buttons: 🅾️ = GT A, ❎ = GT B (libretro `b` / `y` in RetroArch-style
frontends; `start` works on the title-less games' restart screens via 🅾️).

Adaptations of CC4-BY-NC-SA games are themselves CC-BY-NC-SA 4.0
(attribution above; non-commercial; share-alike). They are showcase ROMs —
don't sell them or bundle them with anything paid. The SDK itself stays MIT;
these directories are license-firewalled.
