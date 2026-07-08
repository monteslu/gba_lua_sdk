# Fidelity trade-offs — reversible perf cuts

This file tracks every change that trades a small amount of **gameplay or visual
fidelity** for performance, so each one can be **reversed later** if the SDK
gains a function (or an asm engine) that makes the original affordable.

Structural and graphical fidelity is kept as close to the source cart as
possible; these are deliberate, minor reductions (fewer particles, smaller
effect budgets) applied only where they buy real frame-time and the difference
is hard to notice at 30 fps.

Each entry records: **what** changed, the **original** value, the **reason**,
the **measured** effect, and the **revert trigger** (the SDK capability that
would let us restore the original for free).

---

## cherry-bomb — explosion particle counts

**File:** `ports/cherry-bomb/main.lua` (`explode`, `bigexplode`,
`pump_explosions`)

| Knob | Original | Reduced | 
|------|---------:|--------:|
| `explode()` fireball particles (`fleft`) | 30 | 20 |
| `explode()` spark particles (`sleft`) | 20 | 14 |
| `bigexplode()` fireball particles (`fleft`) | 60 | 40 |
| `bigexplode()` spark particles (`sleft`) | 100 | 66 |
| alive-particle ceiling (`#parts >=`) | 44 | 36 |

**Reason:** each live particle is a blit + a pool walk step. Multi-kill volleys
spawned the biggest bursts, producing the deep 7–9 vsync spikes (the worst
hitches). The particle SWARM is decorative; the flash blob + shockwave (which
carry the "hit" read) are untouched.

**Measured:** during a sustained-combat window the deep tail shrank
(`{7:10, 9:5}` → `{7:3, 9:2}`); the explosion still plays with a full cloud,
just a thinner one on the heaviest frames.

**Revert trigger:** a particle DRAW ENGINE (`gt.parts_draw`-style asm that
stages all live particle blits in one walk, like `gt.balls_draw`) — memory
`romdev`/gtlua notes flag this as the deferred "parts draw engine (~9k)". Once
that lands, particles are cheap enough to restore the original counts. Restore
the five values in the table above.

---

*(Add new entries above this line as further trade-offs are made. Keep the
original values exact so a revert is mechanical.)*
