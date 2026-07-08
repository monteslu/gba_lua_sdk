-- combo pool — gametank port
-- Hand-translated from "Combo Pool" by NuSan (PICO-8, p8jam2)
-- lexaloffle.com/bbs/?tid=3467 — original licensed CC-BY-NC-SA 4.0.
-- This adaptation (real game logic, real sprite sheet) is released under
-- the same license: CC-BY-NC-SA 4.0 — see LICENSE in this directory.
-- Every divergence from the original cart is listed in PORT_NOTES.md.
--
-- ⬅️➡️ aim the launcher, hold/release 🅾️ (GT A) to shoot a ball.
-- Balls of the same color merge into the next color; merging two of the
-- last color sets off a bomb (victory outside endless mode). Keeping too
-- many balls on the table drains your life bar. GT C toggles ball numbers.
--
-- Build: node ports/combo-pool/build.mjs  (banked 2 MB FLASH2M cart;
--        the flat 32 KB CLI build overflows — see PORT_NOTES.md).

-- ---------------------------------------------------------------------
-- state (original keeps these as globals; ball objects become parallel
-- arrays so the pairwise collision pass can index any two balls)
-- ---------------------------------------------------------------------

local menuselect = 2
local maxallowed10 = 0      -- life budget x10 (ballcost kept in tenths)
local displaynumber = 0     -- original menuitem toggle; GT C here

-- balls: slot is live when ballc[slot] > 0 (original: dead flag + del)
local ballx = array(28, 0.0)
local bally = array(28, 0.0)
local ballvx = array(28, 0.0)
local ballvy = array(28, 0.0)
local ballc = array(28)     -- color/tier 1..7, 0 = free slot
local ballmul = array8(28)  -- combo multiplier 1..8
local balllm = array8(28)   -- "lastmult" cooldown, 60 -> 0
-- trail stamps in whole pixels: they only feed flr()'d draws, and int
-- arrays skip the 32-bit compare/copy tax the fixed versions paid
local trailx = array8(28)
local traily = array8(28)

local ballidx = 0           -- total balls created (endgame stat)

-- 8x8 broad-phase grid, 16px cells (original: grid[i][j] tables)

-- 1/sqrdist table for contact math: invsq[flr(d2*2)+1] ~= 1/d2 for the
-- contact range d2 < 64. gt_fdiv is a 48-step software loop (~35K cycles,
-- over half a vsync) so per-frame division is banned; see PORT_NOTES.md.
local invsq = array(128, 0.0)

-- main-menu marching-ball constants (i*136/14 and i/13 from the cart),
-- computed once at boot instead of two divisions per ball per frame
local march_off = array(14, 0.0)
local phase_off = array(14, 0.0)
local menu_march = 0.0

local parts = pool(32)      -- explosion/spark particles
local texts = pool(8, "slot") -- floating "+score" popups
-- per-popup baked digit strings: value never changes after spawn, so the
-- digits render ONCE here and each frame is two gt.print_buf calls
-- (shadow + face) instead of four ~1k print() wrapper trips
local tx_b = array8(64)         -- 8 slots x 8 bytes, NUL-terminated
local tx_free = 0
-- "sudden death : " baked once (_init) + the countdown digits on change:
-- the banner otherwise re-staged ~17 print() glyphs per frame during the
-- alarm phase, exactly when the flicker + music already load the frame
local sd_b = array8(20)
local sd_n = array8(4)
local sd_last = -1

local gtime = 0             -- original 'time' (renamed: time() builtin)
local menutime = 0.0

local launch_vrot = 0.0
local launch_rot = 0.25
local launch_dx = 0.0
local launch_dy = 1.0
local launch_x = 64
local launch_y = 120
local launch_str = 6
local launch_press = 0
local avoid_nextlaunch = 1
local launch_next = 1

local score = 0.0           -- like the original, score is points/100
local ballscore = 0.0
local maxballscore = 0.0
local ballmult = 1
local maxmult = 1
local oldscore = 0.0
local newscoretimer = 0
local newballtimer = 0
local newballappear = 0
local oldballscore = 0.0
local newballscoretimer = 0
local newmaxtimer = 0
local newmaxappear = 0

local mainmenu = 1
local intromenu = 0
local lastselect = 30

local death = 0
local suddendeath = 0
local victory = 0
local finish = 0
local finishtimer = 0

local pstam = 100.0
local astam = 0.5
local lstam = 100.0

local plife = 1.0
local llife = 1.0
local lifecost10 = 0

-- per-tier tables (filled in _init)
local bpal = array8(7)      -- ball body color
local bpal2 = array8(7)     -- highlight color
local bpal3 = array8(7)     -- rim color
local ballvalue = array8(7) -- score value per merge
local ballcost10 = array8(7)-- life cost x10 (max 40: fits a byte)
local lifes10 = array(4)    -- per-difficulty life budget x10

-- audio: tiny per-channel sequencer approximating the cart's sfx
-- converted PICO-8 sfx (tools/p8sfx.mjs from carts/combo-pool-extract):
-- real pitches/waveforms/timing from the original cart's __sfx__ section,
-- played by the SDK's FM runtime (sfx() checks the registered bank first)
local p8sfx = hexdata("1225002800470080009700d800170154018f01b201b701bc01c101c601df01e40107022802000000030e78241029112411291124112933241029112411291124113e1129113e11031b782408000829090008240900082909270824080009290800092408271a2408000829090008241129092410000929080009240800092711080a7830212822322234223c214111401143113e114022091f6d3c043e0440043e044005410440044104430441054004430441043e0540043c08400443053e04410445044005430447044004450443053e04410440044305091e7827082b082909000827092e082909000827082b09290827092e082b09290827092908000827092908000927082b11281129082b092908270929082b09091d7827082b082909000830092e082b0900082e08330935082e0933082e0930082e0930082b0829092e1900092b0830082e0900112e082b0930082e09091c5b3008371135083a093c08300933083508330937083a0933083a1135113308350937083c0937113a08300835093a083309350837093a08350909105b331035113a113f11431141113f113a113f1046113a11351137113a113f193709030149240a03016d23070301122f070801784321080b782a012b012c012f0132013b01480133012f012c012b010801784f3b0310782a012b032a012b022a0129012a032b022a012b0327012b032d012b0328022b0b080f783c0a3f0a430a460b480a4b0a4d153c0a3f0b430a460a480b4b0a4d0a3c0b080878401e431e481e4d1e401e431e481e4d1e")
-- converted __music__ patterns: 0-3 = the level tune (loops), 5 = death
-- sting (self-loops), 10 = sudden-death alarm (self-loops)
local p8music = hexdata("0b0105ffffff0006ffffff0007ffffff0208ffffff0001ffffff0303ffffff00ffffffff00ffffffff00ffffffff00ffffffff0304ffffff")

-- ---------------------------------------------------------------------
-- audio driver: gt.note sequences stand in for the cart's sfx tracker
-- ---------------------------------------------------------------------

function playfx(f)
  local ch = 2                       -- merges (12/13/14) on channel 2
  if (f == 9 or f == 10) ch = 0      -- launcher
  if (f == 11) ch = 1                -- combo ticks
  if (f == 15 or f == 17) ch = 3     -- bomb / fanfare
  sfx(f, ch)
end

-- trail-stamp sheet cells per tier (scattered into blank cells; filled
-- in _init, baked by bake_sprites)
local trailspr = array8(7)

-- ---------------------------------------------------------------------
-- sprite baking: the cart draws balls procedurally (3 nested circfills +
-- backdrop + shadow) every frame; at 3.5MHz that is 5 primitives per ball
-- (~15K cycles measured), so _init pre-renders each tier into free sheet
-- cells and the game draws one spr() per ball:
--   rows 6-7  (96+):  launcher ball per tier (aim ring + backdrop + ball)
--   rows 8-9  (128+): field ball per tier (drop shadow + backdrop + ball)
--   rows 10-11(160+): blinking field ball (red backdrop)
--   scattered singles: r3 motion-trail stamps (trailspr[])
-- build.mjs additionally composes border/lattice/panel STRIPS into rows
-- 12-15 + 4-5 of the sheet so the static art is a handful of wide blits.
-- ---------------------------------------------------------------------

function bake_span(x0, x1, y, col)
  local x = x0
  while x <= x1 do
    sset(x, y, col)
    x += 1
  end
end

-- midpoint circle, same spans as circfill so baked balls match the
-- procedurally drawn launcher/menu circles
function bake_circfill(cx, cy, r, col)
  local x = r
  local y = 0
  local d = 1 - r
  while y <= x do
    bake_span(cx - x, cx + x, cy + y, col)
    if (y ~= 0) bake_span(cx - x, cx + x, cy - y, col)
    if d < 0 then
      d += y * 2 + 3
    else
      if x ~= y then
        bake_span(cx - y, cx + y, cy + x, col)
        bake_span(cx - y, cx + y, cy - x, col)
      end
      d += (y - x) * 2 + 5
      x -= 1
    end
    y += 1
  end
end

-- midpoint circle outline into the sheet (the launcher's aim ring)
function bake_circ(cx, cy, r, col)
  local x = r
  local y = 0
  local d = 1 - r
  while y <= x do
    sset(cx + x, cy + y, col)
    sset(cx - x, cy + y, col)
    sset(cx + x, cy - y, col)
    sset(cx - x, cy - y, col)
    sset(cx + y, cy + x, col)
    sset(cx - y, cy + x, col)
    sset(cx + y, cy - x, col)
    sset(cx - y, cy - x, col)
    if d < 0 then
      d += y * 2 + 3
    else
      d += (y - x) * 2 + 5
      x -= 1
    end
    y += 1
  end
end

-- drawball's three discs; color 0 pixels would be transparent in spr(),
-- so pure black ink is swapped for the GameTank's near-black gray
function bake_ball_at(sx, sy, c, backdrop)
  bake_circfill(sx, sy, 5, backdrop)
  local rim = bpal3[c]
  if (rim == 0) rim = gt.rgb(1)
  bake_circfill(sx, sy, 4, rim)
  bake_circfill(sx, sy, 3, bpal[c])
  bake_circfill(sx + 1, sy - 1, 1, bpal2[c])
end

function bake_sprites()
  local c = 1
  while c <= 7 do
    local sx = (c - 1) * 16 + 8
    -- field ball with drop shadow: cells 128+ (2x2), center (8,7)
    bake_circfill(sx, 64 + 9, 5, 1)
    bake_ball_at(sx, 64 + 7, c, gt.rgb(1))
    -- blinking ball (red backdrop): cells 160+
    bake_circfill(sx, 80 + 9, 5, 1)
    bake_ball_at(sx, 80 + 7, c, 8)
    -- launcher ball with the aim ring, no shadow: cells 96+
    bake_circ(sx, 48 + 7, 6, 13)
    bake_ball_at(sx, 48 + 7, c, gt.rgb(1))
    -- motion-trail stamp (the cart smears trails into a persistent
    -- framebuffer; we stamp blobs instead): scattered single cells
    local tc = trailspr[c]
    bake_circfill((tc % 16) * 8 + 3, (tc \ 16) * 8 + 3, 3, bpal[c])
    c += 1
  end
end

-- spr helpers for the baked sets
function draw_ball_spr(x, y, c)
  spr(128 + (c - 1) * 2, x - 8, y - 7, 2, 2)
end

function draw_ball_blink(x, y, c)
  spr(160 + (c - 1) * 2, x - 8, y - 7, 2, 2)
end

function draw_ball_launcher(x, y, c)
  spr(96 + (c - 1) * 2, x - 8, y - 7, 2, 2)
end

-- ---------------------------------------------------------------------
-- entities
-- ---------------------------------------------------------------------

-- returns the slot used, 0 if the table is full (cap 28; the cart is
-- unbounded — see PORT_NOTES.md)
-- gt.balls engine plumbing: bounce flags + contact-pair list + draw cells
local ballfl = array8(32)
local bpairs = array8(64)
local bcell = array8(32)
local bc_norm = array8(8)
local bc_blink = array8(8)

function new_ball(xx, yy, cc)
  for i = 1, 28 do
    if ballc[i] == 0 then
      ballx[i] = xx
      bally[i] = yy
      ballvx[i] = 0
      ballvy[i] = 0
      ballc[i] = cc
      ballmul[i] = 1
      balllm[i] = 0
      trailx[i] = flr(xx)
      traily[i] = flr(yy)
      ballidx += 1
      return i
    end
  end
  return 0
end

function new_part(xx, yy, tt, cc, rr)
  add(parts, {x = xx, y = yy, vx = 0, vy = 0, c = cc, t = tt, spread = rr})
end

function new_text(xx, yy, val, nvx, nvy)
  tx_free = (tx_free % 8) + 1
  local k = (tx_free - 1) * 8 + 1
  local dv = 10000
  local started = 0
  while dv >= 1 do
    local d = (val \ dv) % 10
    if d > 0 or started == 1 or dv == 1 then
      tx_b[k] = 48 + d
      k += 1
      started = 1
    end
    dv \= 10
  end
  tx_b[k] = 48                  -- the trailing '0' (P8 shows val*10)
  tx_b[k + 1] = 0
  add(texts, {x = xx, y = yy, vx = nvx, vy = nvy, val = val, t = 1, slot = tx_free})
end

-- the static field composes into the GRAM canvas once per game start;
-- draw_game then restores it with ONE opaque wrapped blit instead of
-- eighteen 64px strip blits every frame
local fieldcol = array8(16)

function compose_field()
 local i = 0
 while i < 16 do
  fieldcol[1] = 208 + i          -- top border
  local r = 2
  while r <= 13 do               -- 12 woven lattice rows (224/240 pairs)
   fieldcol[r] = 224 + i
   fieldcol[r + 1] = 240 + i
   r += 2
  end
  fieldcol[14] = 224 + i         -- the half-pair row at y=104
  fieldcol[15] = 192 + i         -- bottom border
  fieldcol[16] = 208 + i         -- y>=120 sits under the opaque HUD band
  gt.bg_coln(fieldcol, i * 8, 0, 16)
  i += 1
 end
end

function reset_game()
  compose_field()
  for i = 1, 28 do
    ballc[i] = 0
  end
  ballidx = 0

  for p in all(parts) do
    del(parts, p)
  end
  for p in all(texts) do
    del(texts, p)
  end

  gtime = 0
  menutime = 0

  launch_vrot = 0
  launch_rot = 0.25
  launch_dx = 0
  launch_dy = 1
  launch_press = 0
  avoid_nextlaunch = 1
  launch_next = 1

  score = 0
  ballscore = 0
  maxballscore = 0
  ballmult = 1
  maxmult = 1
  oldscore = 0
  newscoretimer = 0
  newballtimer = 0
  newballappear = 0
  oldballscore = 0
  newballscoretimer = 0
  newmaxtimer = 0
  newmaxappear = 0

  mainmenu = 1
  intromenu = 0
  lastselect = 30

  music(-1)
  death = 0
  suddendeath = 0
  victory = 0
  finish = 0
  finishtimer = 0

  pstam = 100
  astam = 0.5
  lstam = 100

  plife = 1
  llife = 1

  -- six starter balls in the upper field; ballidx counts the color-1
  -- balls they are "worth" (2^tier), same as the cart
  local ballcount = 0
  local i = 0
  while i < 3 do
    local j = 0
    while j < 2 do
      local typ = flr(rnd(3))
      ballcount += 1 << typ
      new_ball(16 + j * 64 + rnd(32), 8 + i * 32 + rnd(16), typ + 1)
      j += 1
    end
    i += 1
  end
  ballidx = ballcount
end

-- ---------------------------------------------------------------------
-- physics
-- ---------------------------------------------------------------------

function bomb(x, y, rad, strv)
  for i = 1, 28 do
    if ballc[i] > 0 then
      local dx = ballx[i] - x
      local dy = bally[i] - y
      local dist = sqrt(dx * dx + dy * dy + 0.01)
      if dist < rad then
        ballvx[i] += dx * strv / dist
        ballvy[i] += dy * strv / dist
      end
    end
  end
end

function do_coll(i, j)
  -- cheap rejects before any 32-bit multiply (contact needs |d| < 8)
  local x1 = ballx[i]
  local x2 = ballx[j]
  local dx = x1 - x2
  if (dx >= 8 or dx <= -8) return
  local y1 = bally[i]
  local y2 = bally[j]
  local dy = y1 - y2
  if (dy >= 8 or dy <= -8) return
  -- contact geometry in 16ths-as-int: |dxq| <= 127, so every product
  -- below fits 16 bits and the ~550-cycle 32-bit fixed multiplies drop
  -- to ~200-cycle int ones (this resolver was the cart's biggest single
  -- cycle sink). The x16 / /256 conversions are power-of-two fixed
  -- multiplies = shift chains, not helper calls.
  local dxq = flr(dx * 16)
  local dyq = flr(dy * 16)
  local sq256 = dxq * dxq + dyq * dyq
  if (sq256 >= 16384) return
  if (ballc[i] == 0 or ballc[j] == 0) return

  local vx1 = ballvx[i]
  local vy1 = ballvy[i]
  local vx2 = ballvx[j]
  local vy2 = ballvy[j]

  -- ~1/sqrdist without a division (table), then 1/dist = dist/sqrdist
  local inv_sq = 4.0
  if (sq256 >= 64) inv_sq = invsq[sq256 \ 128 + 1]
  local adxq = abs(dxq)
  local adyq = abs(dyq)
  -- alpha-max-beta-min in 16ths: 123/128 = .9609, 51/128 = .3984
  local d16 = 0
  if adxq > adyq then
    d16 = (adxq * 123 + adyq * 51) \ 128
  else
    d16 = (adyq * 123 + adxq * 51) \ 128
  end
  local dist = d16 * 0.0625
  local invd = dist * inv_sq

  if ballc[i] == ballc[j] then
    -- merge j into i
    x1 = (x1 + x2) / 2
    y1 = (y1 + y2) / 2
    vx1 += vx2
    vy1 += vy2
    ballx[i] = x1
    bally[i] = y1
    ballvx[i] = vx1
    ballvy[i] = vy1

    local nx = dy * invd
    local ny = -dx * invd

    local cnew = ballc[i]
    if cnew < 7 then
      cnew += 1
      ballc[i] = cnew
      local snd = 13
      if (cnew > 3) snd = 12
      if (cnew > 5) snd = 14
      playfx(snd)
    else
      bomb(x1, y1, 80, 5)
      local pp = 0
      while pp < 20 do
        local pvx = vx1 * 0.5 + (rnd() - 0.5) * 3
        local pvy = vy1 * 0.5 + (rnd() - 0.5) * 3
        add(parts, {x = x1, y = y1, vx = pvx, vy = pvy,
                    c = 3, t = 0.5, spread = pp * 3 \ 20})
        pp += 1
      end
      if death == 0 and maxallowed10 > 0 then
        if (victory == 0) finishtimer = 0
        victory = 1
        finish = 1
      end
      playfx(15)
      -- popped: retire the merged ball too (score still uses tier 7)
      ballc[i] = 0
    end

    ballmult += ballmul[i] * ballmul[j]
    local addscore = ballmult * ballvalue[cnew]
    ballscore += addscore / 100
    score += addscore / 100

    if ny > 0 then
      ny = -ny
      nx = -nx
    end
    new_text(x1, y1, addscore, nx, ny)

    ballc[j] = 0
    ballmul[i] = min(ballmul[i] * 2, 8)
    balllm[i] = 60
  else
    if sq256 > 0 then
      -- swap the velocity components along the contact axis. Same math as
      -- the cart's dotpart() exchange, reformulated on the unnormalized
      -- axis d so no sqrt is needed:  v1' = v1 + ((v2-v1)·d)d/|d|²
      -- velocity dot in 16ths-as-int too: |dv| < 8 so |dvq| < 128 and
      -- the dot stays inside 16 bits; /256 back to fixed is shifts
      local dvxq = flr((vx2 - vx1) * 16)
      local dvyq = flr((vy2 - vy1) * 16)
      local k = (dvxq * dxq + dvyq * dyq) * 0.00390625
      k *= inv_sq
      local kx = dx * k
      local ky = dy * k

      -- positional push apart
      local push = (max(0, 9 - dist) / 2) * invd
      local pdx = dx * push
      local pdy = dy * push
      ballx[i] = x1 + pdx
      bally[i] = y1 + pdy
      ballx[j] = x2 - pdx
      bally[j] = y2 - pdy

      vx1 += kx
      vy1 += ky
      ballvx[i] = vx1
      ballvy[i] = vy1
      vx2 -= kx
      vy2 -= ky
      ballvx[j] = vx2
      ballvy[j] = vy2

      local iscombo = 0
      if balllm[i] <= 55 then
        ballmul[i] = min(ballmul[i] * 2, 8)
        balllm[i] = 60
        iscombo = 1
      end
      if balllm[j] <= 55 then
        ballmul[j] = min(ballmul[j] * 2, 8)
        balllm[j] = 60
        iscombo = 1
      end

      if iscombo == 1 then
        local bestmult = max(ballmul[i], ballmul[j])
        ballmul[i] = bestmult
        ballmul[j] = bestmult
        add(parts, {x = (x1 + x2) / 2, y = (y1 + y2) / 2,
                    vx = (vx1 + vx2) * 0.5, vy = (vy1 + vy2) * 0.5,
                    c = 2, t = 0.25, spread = 0})
        playfx(11)
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- update
-- ---------------------------------------------------------------------

function update_mainmenu()
  if btnp(2) then
    menuselect -= 1
    lastselect = 30
  end
  if btnp(3) then
    menuselect += 1
    lastselect = 30
  end
  menuselect = ((menuselect % 4) + 4) % 4
  if (lastselect > 0) lastselect -= 1

  if btnp(4) or btnp(5) then
    intromenu = 1
    mainmenu = 0
    playfx(12)
    avoid_nextlaunch = 1
  end

  if (gtime == 0) playfx(13)
  if gtime == 60 then
    playfx(14)
    music(0)
  end

  -- marching-ball advance (the cart computes animtime*10 % 136 per ball
  -- per frame; a wrapped accumulator needs no division)
  if menutime > 1.5 then
    menu_march += 0.3333
    if (menu_march >= 136) menu_march -= 136
  end

  gtime += 1
  menutime += 0.0333
end

function update_intromenu()
  local pressed = 0
  if (btnp(4) or btnp(5)) pressed = 1
  if pressed == 1 and avoid_nextlaunch == 0 then
    maxallowed10 = lifes10[menuselect + 1]
    playfx(14)
    srand(gtime + 1)
    reset_game()
    mainmenu = 0
    intromenu = 0
  else
    avoid_nextlaunch = 0
  end
  gtime += 1
end

function update_game()
  if (death == 1 or victory == 1) and finishtimer > 60 then
    if btnp(4) or btnp(5) then
      reset_game()
      return
    end
  end

  if (btnp(6)) displaynumber = 1 - displaynumber

  -- particles: movement + drag in bulk asm (a merge burst is ~20 live
  -- particles x ~2.5k cycles through the long helpers otherwise);
  -- lifetimes and deletes stay here
  gt.parts_step(parts)
  for p in all(parts) do
    p.t -= 0.0333
    if (p.t <= 0) del(parts, p)
  end
  gt.parts_step(texts)
  for p in all(texts) do
    p.t -= 0.0333
    if (p.t <= 0) del(texts, p)
  end

  local curpress = 0
  if (btn(4)) curpress = 1
  local resetmult = 0

  if finish == 0 then
    -- keyboard aiming (the cart also supports the P8 mouse; GameTank
    -- has no mouse)
    local vrot = 0.002
    if (curpress == 1) vrot = 0.003
    if (btn(0)) launch_vrot += vrot
    if (btn(1)) launch_vrot -= vrot

    launch_rot = min(max(0.005, launch_rot + launch_vrot), 0.495)
    launch_dx = cos(launch_rot)
    launch_dy = sin(launch_rot)

    if curpress == 1 then
      launch_vrot = 0
    else
      launch_vrot *= 0.8
    end

    -- no pure-vertical shots (cart keeps a tiny bias so you can't play 1d)
    if launch_dx == 0 then
      launch_dx += 0.01
      launch_dy += 0.01
    end

    local canrelease = 0
    if (pstam > 0 and avoid_nextlaunch == 0) canrelease = 1

    if (curpress == 1 and launch_press == 0 and canrelease == 1) playfx(9)

    if curpress == 0 and launch_press == 1 and canrelease == 1 then
      local nb = new_ball(launch_x, launch_y, launch_next)
      if nb > 0 then
        ballvx[nb] = launch_dx * launch_str
        ballvy[nb] = launch_dy * launch_str

        ballscore = 0
        ballmult = 1
        resetmult = 1
        pstam -= 40
        astam = 0.5

        playfx(10)
      end
    end
  else
    finishtimer += 1
  end

  launch_press = curpress
  if (curpress == 0) avoid_nextlaunch = 0

  -- integrate + wall bounces + collisions, 2 substeps (cart: 5 — see
  -- PORT_NOTES.md). The movement + spatial grid + pair SCAN run in the asm
  -- engine (gt_balls.s, ~4k/substep vs ~28k compiled); the branchy impulse
  -- and merge resolution stays here in do_coll, fed from the pair list.
  local s = 0
  while s < 2 do
    gt.balls_step(ballx, bally, ballvx, ballvy, ballc, ballfl, bpairs, 28)
    local k = 1
    while bpairs[k] > 0 do
      do_coll(bpairs[k], bpairs[k + 1])
      k += 2
    end
    for i = 1, 28 do
      if ballc[i] > 0 then
        if ballfl[i] == 1 then
          if balllm[i] <= 55 then
            ballmul[i] = min(ballmul[i] * 2, 8)
            balllm[i] = 60
            new_part(ballx[i], bally[i], 0.25, 2, 0)
            playfx(11)
          end
        end
        if (resetmult == 1) ballmul[i] = 1
      end
    end
    s += 1
  end

  -- drag, life cost, combo cooldown (cart ticks lastmult once per
  -- substep = 5/frame; we tick 5 per frame to match). Drag 0.98 becomes
  -- 1 - 1/64 - 1/256 = 0.98047 — shifts instead of a 16.16 multiply.
  gt.balls_drag(ballvx, ballvy, ballc, 28)
  -- life-cost sum + combo-cooldown decay, one asm walk (gt.cost_decay)
  lifecost10 = gt.cost_decay(ballc, balllm, ballcost10, 28)

  -- score HUD bookkeeping
  if (maxballscore < ballscore) newmaxtimer = 60
  if newmaxtimer > 0 then
    newmaxtimer -= 1
    newmaxappear = min(60, newmaxappear + 1)
  else
    newmaxappear = max(0, newmaxappear - 1)
  end
  maxballscore = max(maxballscore, ballscore)

  newballscoretimer = max(0, newballscoretimer - 1)
  if ballscore ~= oldballscore then
    newballscoretimer = 32
    oldballscore = ballscore
  end

  newscoretimer = max(0, newscoretimer - 1)
  if score ~= oldscore then
    newscoretimer = 4
    oldscore = score
  end

  maxmult = max(ballmult, maxmult)

  newballtimer = 0
  if (ballscore > 0) newballtimer = 10
  newballappear += max(-1, min(1, newballtimer - newballappear))

  if pstam < 100 then
    pstam = min(100, pstam + astam)
    astam *= 1.1
  end
  lstam += max(-1, min(1, pstam - lstam))

  if finish == 1 and victory == 1 then
    if finishtimer == 30 then
      music(-1)
      playfx(17)
    end
  end

  -- life bar / sudden death
  if maxallowed10 > 0 and death == 0 and victory == 0 then
    -- 8.8 range audit: 1/400 underflows (and 400 itself wraps 8.8), so the
    -- old inv_maxlife precompute produced a NEGATIVE inverse and the cubic
    -- rode an overflow cliff (sudden death fired on wrap, not on the rule).
    -- Divide directly (0..~2.8 fits) and clamp so ratio^3*100 stays in range
    -- past the death threshold.
    local ratio = lifecost10 / maxallowed10
    if (ratio > 1.05) ratio = 1.05
    local r2 = ratio * ratio
    plife = 100 - (r2 * ratio) * 100
    if plife < 0 then
      if (suddendeath == 0) music(10)   -- alarm in
      suddendeath = 1
      finish = 1
      if finishtimer >= 120 then
        music(5)                         -- death sting
        suddendeath = 0
        finishtimer = 0
        death = 1
      end
    else
      if finishtimer < 120 then
        if (suddendeath == 1) music(-1)  -- recovered
        suddendeath = 0
        finish = 0
        finishtimer = 0
      else
        death = 1
        finish = 1
      end
    end
    llife += max(-1, min(1, plife - llife))
  end

  gtime += 1
end

function _update()
  -- no cls(): every screen fully repaints (game = opaque field strips +
  -- HUD backdrop; main menu = weave band + black fills). Intro is the
  -- one sparse screen and clears itself.
  if (intromenu == 1) cls(0)
  if mainmenu == 1 then
    update_mainmenu()
    return
  end
  if intromenu == 1 then
    update_intromenu()
    return
  end
  update_game()
end

-- ---------------------------------------------------------------------
-- draw helpers
-- ---------------------------------------------------------------------

-- P8 score format: score is points/100, shown as (score*100) .. "0"
-- per-slot ASCII cache: scores change on merges, not per frame. The old
-- path re-split AND made up to four print() calls per score per frame
-- (~1.1k each — the wrapper dominates); now the digits render into a
-- byte buffer when the value changes and draw with ONE gt.print_buf.
local ps_v = array(3, -1.0)
local ps_b = array8(36)         -- 12 bytes per slot, NUL-terminated
local mb_b = array8(8)          -- cached 'x<mult>' string
local mb_last = -1
local mb_x = 0

function print_score(sl, v, x, y, c)
  if v ~= ps_v[sl] then
    ps_v[sl] = v
    local iv = flr(v)
    local fr = flr((v - iv) * 100 + 0.5)
    iv += fr \ 100
    fr %= 100
    local k = (sl - 1) * 12 + 1
    if sl == 3 then
      ps_b[k] = 43              -- '+' fused into the ballscore string
      k += 1
    end
    if iv > 0 then
      -- iv digits (no leading zeros), then fr zero-padded to 2, then '0'
      local dv = 10000
      local started = 0
      while dv >= 1 do
        local d = (iv \ dv) % 10
        if d > 0 or started == 1 or dv == 1 then
          ps_b[k] = 48 + d
          k += 1
          started = 1
        end
        dv \= 10
      end
      ps_b[k] = 48 + fr \ 10
      ps_b[k + 1] = 48 + fr % 10
      ps_b[k + 2] = 48
      k += 3
    elseif fr > 0 then
      if fr >= 10 then
        ps_b[k] = 48 + fr \ 10
        k += 1
      end
      ps_b[k] = 48 + fr % 10
      ps_b[k + 1] = 48
      k += 2
    else
      ps_b[k] = 48
      k += 1
    end
    ps_b[k] = 0
  end
  return gt.print_buf(ps_b, (sl - 1) * 12, x, y, c)
end

-- rounded HUD panel: corner cells + edge lines matching the cart's
-- sspr-stretched strips (gtlua has no sspr)
function draw_panel(x, y, sx, sy)
  rectfill(x + 8, y + 1, x + sx - 9, y + 1, 13)
  rectfill(x + 8, y + 2, x + sx - 9, y + 2, 1)
  rectfill(x + 8, y + sy - 2, x + sx - 9, y + sy - 2, 1)
  rectfill(x + 8, y + sy - 1, x + sx - 9, y + sy - 1, 5)
  rectfill(x, y + 8, x, y + sy - 9, 1)
  rectfill(x + 1, y + 8, x + 1, y + sy - 9, 13)
  rectfill(x + 2, y + 8, x + 2, y + sy - 9, 1)
  rectfill(x + sx - 3, y + 8, x + sx - 3, y + sy - 9, 1)
  rectfill(x + sx - 2, y + 8, x + sx - 2, y + sy - 9, 13)
  rectfill(x + sx - 1, y + 8, x + sx - 1, y + sy - 9, 1)
  spr(66, x, y)
  spr(67, x + sx - 8, y)
  spr(82, x, y + sy - 8)
  spr(83, x + sx - 8, y + sy - 8)
end

-- stamina/life bar; v/m are 0..100 ints; bg < 0 skips the backing strip.
-- (v*0.3 becomes v*77>>8 = v*0.3008 in cheap int math.)
function draw_dbar(px, py, v, m, c, c2, bg)
  local b = bg
  if (b < 0) b = 255
  gt.dbar(px, py, v, m, c, c2, b)
end

-- the cart's boldline() is five 130px Bresenham passes (~1.5 vsyncs of
-- CPU psets); the guide here is a single line — see PORT_NOTES.md
function draw_boldline(x1, y1, x2, y2, c)
  line(x1, y1, x2, y2, c)
end

-- ---------------------------------------------------------------------
-- draw
-- ---------------------------------------------------------------------

function draw_mainmenu()
  local mx = 40
  local my = 37

  -- checkerboard weave band (cart: map(0,0,0,1,16,16) over a blue fill;
  -- here 4 composed row-strip blits)
  spr(240, 0, 17, 16, 1)
  spr(224, 0, 25, 16, 2)
  spr(224, 0, 41, 16, 2)
  spr(224, 0, 57, 16, 2)

  -- title logos fly in (cart repals sprites for shadows + rainbow
  -- cycling; GameTank blits can't be repalled, so the sheet colors show).
  -- The sin/t^2 bounce settles by t=4s; skip its divisions after that.
  local animtime = min(2, menutime) / 2
  local a2 = animtime * animtime
  local a4 = a2 * a2
  local titlex = a4 * a4 * a2
  local titleb = flr(-32 + 64 * titlex)
  local titley = my
  local title2x = flr(134 - 70 * titlex)
  local title2y = my
  if menutime < 4 then
    titley = flr(my + (sin(menutime + 0.3) * 5) / (menutime * menutime))
    title2y = flr(my + (sin(menutime) * 10) / menutime)
  end
  spr(5, titleb, titley, 4, 2)
  spr(37, title2x, title2y, 4, 2)

  my = 66
  local second = 50

  rectfill(0, my + 3, 127, 127, 0)
  rectfill(0, 0, 127, my - second + 2, 0)
  rect(0, my + 3, 127, my - second + 2, 1)

  print("nusan - p8jam2", mx, 1, 6)
  print("v4", 116, 122, 1)

  -- marching balls: march accumulator + boot-time per-ball offsets stand
  -- in for the cart's per-ball %136 and /13 //14 divisions
  local phbase = 0.0
  if (menutime > 1.5) phbase = (menutime - 1.5) * 0.4
  local easein = 0
  if menutime < 2 then
    local ease = 1 - menutime / 2
    -- 136*x overflows 8.8 (limit 127.99): halve the factor, double after
    easein = flr(68 * (1 - ease * ease)) * 2 - 136
  end
  local i = 0
  local bid = 1
  while i < 14 do
    local ss = sin(phbase + phase_off[i + 1])
    local avance = menu_march + (ss << 2) + ss + march_off[i + 1] - 4
    if (avance >= 132) avance -= 136
    if (avance >= 132) avance -= 136
    local bx = flr(avance) + easein
    draw_ball_spr(bx, my, bid)
    draw_ball_spr(128 - bx, my - second, bid)
    bid += 1
    if (bid > 7) bid = 1
    i += 1
  end

  my = 77

  draw_panel(mx - 7, my + 3, 61, 48)

  i = 1
  while i <= 4 do
    local ty = my + i * 10
    if i == menuselect + 1 then
      local ls = lastselect
      local selw = 50 - (ls * ls * ls) \ 540
      rectfill(mx - 2, ty - 2, mx - 2 + selw, ty + 6, 1)
      if (i == 1) print("endless", mx, ty, 7)
      if (i == 2) print("easy", mx, ty, 7)
      if (i == 3) print("normal", mx, ty, 7)
      if (i == 4) print("hard", mx, ty, 7)
    else
      if (i == 1) print("endless", mx, ty, 13)
      if (i == 2) print("easy", mx, ty, 13)
      if (i == 3) print("normal", mx, ty, 13)
      if (i == 4) print("hard", mx, ty, 13)
    end
    i += 1
  end
end

function draw_intromenu()
  local mx = 2
  local my = 1
  if (menuselect == 0) my = 24
  print("goal", 56, my, 7)
  my += 10
  print("merge two balls of same color", mx, my, 6)
  print("to transform them to next color", mx, my + 7, 6)

  my += 24
  rectfill(0, my - 10, 127, my + 18, 1)

  local i = 1
  while i <= 7 do
    local bx = i * 16 - 9
    spr(50, bx + 4, my + 1)
    draw_ball_spr(bx, my, i)
    draw_ball_spr(bx, my + 9, i)
    i += 1
  end

  print("?", 119, my + 2, 6)

  if menuselect > 0 then
    my += 26
    print("avoid keeping too much balls", mx, my, 6)
    print("or your life will end soon", mx, my + 7, 6)
    my += 17
    rectfill(25, my - 2, 105, my + 13, 1)
    draw_dbar(29, my + 2, 60, 60, 8, 2, 0)
    spr(50, 60, my + 1)
    spr(12, 70, my, 4, 2)
    draw_dbar(71, my + 2, 15, 15, 8, 2, 7)
  end

  my += 21
  print("hold the launch button", mx, my, 6)
  print("to use precise rotations", mx, my + 7, 6)

  local arrow = 52
  if (gtime \ 4 % 6 == 0) arrow = 51
  spr(arrow, 104, my + 4)

  local blinkc = 5
  if (gtime \ 8 % 2 == 0) blinkc = 7
  print("press to start", 36, my + 20, blinkc)
end

function draw_game()
  -- static field: composed sheet strips (top border, 13 woven lattice
  -- rows, bottom border) — 9 wide blits instead of ~90 primitives.
  -- Fully opaque, so no cls() is needed in game mode.
  -- static field: one opaque canvas blit (composed once in reset_game)
  gt.canvas_view(0, 0, 1)

  -- sudden-death flicker (cart tints its persistent trail noise red)
  if suddendeath == 1 then
    local k = 0
    while k < 3 do
      circfill(8 + rnd(112), 8 + rnd(104), 2, 2)
      pset(8 + rnd(112), 8 + rnd(104), 2)
      pset(8 + rnd(112), 8 + rnd(104), 2)
      k += 1
    end
  end

  -- ball motion trails, one asm walk (stamp + anchor update)
  local tupd = 0
  if (gtime % 2 == 0) tupd = 1
  gt.trail_stamp(ballc, ballx, bally, trailx, traily, trailspr, 28, tupd)

  -- aim guide (cart: 5-pass boldline over the trail layer, under the map;
  -- the strips are opaque so it draws over the lattice in the same color)
  if finish == 0 then
    draw_boldline(flr(launch_x), flr(launch_y), flr(launch_x + launch_dx * 90),
                  flr(launch_y + launch_dy * 90), 1)
  end

  -- balls (baked composite): cell choice here, the 16x16 blits in bulk asm
  local blinkon = 0
  if (gtime \ 8 % 2 == 0) blinkon = 1
  for i = 1, 28 do
    local c = ballc[i]
    local cl = 0
    if c > 0 then
      cl = bc_norm[c]
      if blinkon == 1 then
        if (c == 7 or (ballmul[i] >= 8 and balllm[i] > 30)) cl = bc_blink[c]
      end
    end
    bcell[i] = cl
  end
  gt.balls_draw(ballx, bally, bcell, 28)
  if displaynumber == 1 then
    for i = 1, 28 do
      if (ballc[i] > 0) print(ballc[i], flr(ballx[i]) - 1, flr(bally[i]) - 2, 0)
    end
  end

  rectfill(0, 119, 127, 127, 0)

  if finish == 0 then
    -- HUD panels: one composed 56x16 sheet image each (transparent
    -- interior, like the cart's corner cells + stretched edges)
    spr(68, 0, 112, 7, 2)

    local maxcol = 13
    if (newmaxtimer > 0 and newmaxtimer \ 4 % 2 == 0) maxcol = 7
    print_score(1, maxballscore, 5, 115, maxcol)
    local scorecol = 13
    if (newscoretimer > 0 and newscoretimer \ 4 % 2 == 0) scorecol = 7
    print_score(2, score, 5, 121, scorecol)

    local a2 = newballappear * newballappear
    local ballmenuy = 130 - (a2 * 12) \ 100

    -- the ball-score panel slides UP from y=130; at rest it sits fully below
    -- the 128px screen. Drawing it there was ~2 print()s of entirely
    -- off-screen glyphs EVERY resting frame — and off-screen y>123 takes the
    -- slow CPU-glyph path (each one drains the blit queue). Skip the whole
    -- panel until any of it is on-screen (its glyphs are 5px tall).
    if ballmenuy <= 127 then
      local bscol = 13
      if (newballscoretimer > 0 and newballscoretimer \ 4 % 2 == 0) bscol = 7
      print_score(3, ballscore, 80, ballmenuy, bscol)
      if ballmult ~= mb_last then
        mb_last = ballmult
        local m = ballmult
        local digits = 1
        if (m >= 10) digits = 2
        if (m >= 100) digits = 3
        if (m >= 1000) digits = 4
        mb_x = 124 - (digits + 1) * 4
        local k = 1
        mb_b[k] = 120             -- 'x'
        k += 1
        local dv = 1000
        local started = 0
        while dv >= 1 do
          local d = (m \ dv) % 10
          if d > 0 or started == 1 or dv == 1 then
            mb_b[k] = 48 + d
            k += 1
            started = 1
          end
          dv \= 10
        end
        mb_b[k] = 0
      end
      gt.print_buf(mb_b, 0, mb_x, ballmenuy, bscol)
    end

    spr(68, 72, 112, 7, 2)

    if newmaxappear > 0 then
      local sl = 60 - newmaxappear
      spr(44, 2 - ((sl * sl \ 4) * 33) \ 900, 103, 4, 2)
    end

    if suddendeath == 0 then
      line(launch_x, launch_y, flr(launch_x + launch_dx * 20),
           flr(launch_y + launch_dy * 20), 13)
      draw_ball_launcher(launch_x, launch_y, launch_next)

      draw_dbar(50, 124, flr(max(0, pstam)), flr(lstam), 13, 5, 1)
      if maxallowed10 > 0 then
        local warn = 0
        if (lifecost10 + 40 > maxallowed10) warn = 1
        if (warn == 1) spr(12, 49, 0, 4, 2)
        local lifebg = 0
        if (warn == 1) lifebg = 7
        draw_dbar(50, 2, flr(max(0, plife)), flr(llife), 8, 2, lifebg)
      end
    end
  end

  -- particles + score popups
  for p in all(parts) do
    if p.c == 3 then
      circfill(p.x, p.y, 10 - p.t * 20, 8 + p.spread)
    elseif p.c == 2 then
      circ(p.x, p.y, 7 - p.t * 24, 7)
    end
  end
  -- score popups: digits baked at spawn (new_text) — the shadow + face
  -- are two buffered draws instead of four print() wrapper trips
  for p in all(texts) do
    local px = flr(p.x)
    local py = flr(p.y)
    local off = (p.slot - 1) * 8
    gt.print_buf(tx_b, off, px + 1, py + 1, 0)
    gt.print_buf(tx_b, off, px, py, 7)
  end

  if finish == 1 then
    local gx = 16
    local gy = 128 - min(96, finishtimer)

    if suddendeath == 1 then
      gt.print_buf(sd_b, 0, 33, 120, 8)
      local sdv = 120 - finishtimer
      if sdv ~= sd_last then
        sd_last = sdv
        local k = 1
        if sdv >= 100 then
          sd_n[k] = 49
          k += 1
        end
        if sdv >= 10 then
          sd_n[k] = 48 + (sdv \ 10) % 10
          k += 1
        end
        sd_n[k] = 48 + sdv % 10
        sd_n[k + 1] = 0
      end
      gt.print_buf(sd_n, 0, 92, 120, 8)
    else
      rectfill(gx + 3, gy + 3, gx + 94, gy + 61, 0)
      draw_panel(gx, gy, 97, 64)
      if death == 1 then
        local rx = print("game over : ", 30, gy + 6, 7)
        if (menuselect == 0) print("endless", rx, gy + 6, 7)
        if (menuselect == 1) print("easy", rx, gy + 6, 7)
        if (menuselect == 2) print("normal", rx, gy + 6, 7)
        if (menuselect == 3) print("hard", rx, gy + 6, 7)
      else
        local rx = print("victory : ", 34, gy + 6, 7)
        if (menuselect == 0) print("endless", rx, gy + 6, 7)
        if (menuselect == 1) print("easy", rx, gy + 6, 7)
        if (menuselect == 2) print("normal", rx, gy + 6, 7)
        if (menuselect == 3) print("hard", rx, gy + 6, 7)
      end
      local rx = print("final score: ", gx + 5, gy + 18, 6)
      print_score(2, score, rx, gy + 18, 6)
      rx = print("max ball: ", gx + 5, gy + 24, 6)
      print_score(1, maxballscore, rx, gy + 24, 6)
      rx = print("last ball: ", gx + 5, gy + 30, 6)
      print_score(3, ballscore, rx, gy + 30, 6)
      rx = print("max multiplyer: ", gx + 5, gy + 36, 6)
      rx = print(maxmult, rx, gy + 36, 6)
      print("x", rx, gy + 36, 6)
      rx = print("ball count: ", gx + 5, gy + 42, 6)
      print(ballidx, rx, gy + 42, 6)
    end

    if (death == 1 or victory == 1) and finishtimer > 60 then
      local blinkc = 5
      if (gtime \ 8 % 2 == 0) blinkc = 7
      print("press to restart", 32, gy + 53, blinkc)
    end
  end
end

function _draw()
  if mainmenu == 1 then
    draw_mainmenu()
    return
  end
  if intromenu == 1 then
    draw_intromenu()
    return
  end
  draw_game()
end

-- ---------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------

function _init()
  sd_b[1] = 115
  sd_b[2] = 117
  sd_b[3] = 100
  sd_b[4] = 100
  sd_b[5] = 101
  sd_b[6] = 110
  sd_b[7] = 32
  sd_b[8] = 100
  sd_b[9] = 101
  sd_b[10] = 97
  sd_b[11] = 116
  sd_b[12] = 104
  sd_b[13] = 32
  sd_b[14] = 58
  sd_b[15] = 32
  sd_b[16] = 0
  bpal[1] = 1
  bpal[2] = 13
  bpal[3] = 6
  bpal[4] = 9
  bpal[5] = 10
  bpal[6] = 8
  bpal[7] = 14
  bpal2[1] = 13
  bpal2[2] = 6
  bpal2[3] = 7
  bpal2[4] = 15
  bpal2[5] = 7
  bpal2[6] = 14
  bpal2[7] = 15
  bpal3[1] = 0
  bpal3[2] = 1
  bpal3[3] = 13
  bpal3[4] = 4
  bpal3[5] = 9
  bpal3[6] = 2
  bpal3[7] = 2

  ballvalue[1] = 1
  ballvalue[2] = 2
  ballvalue[3] = 3
  ballvalue[4] = 5
  ballvalue[5] = 10
  ballvalue[6] = 20
  ballvalue[7] = 100

  ballcost10[1] = 40
  ballcost10[2] = 35
  ballcost10[3] = 30
  ballcost10[4] = 20
  ballcost10[5] = 15
  ballcost10[6] = 10
  ballcost10[7] = 0

  lifes10[1] = 0
  lifes10[2] = 500
  lifes10[3] = 400
  lifes10[4] = 340


  -- contact-math reciprocal table: invsq[m] ~ 1/sqrdist for
  -- sqrdist = (m-0.5)/2 (the only per-frame divisions left are here,
  -- paid once at boot)
  local m = 1
  while m <= 128 do
    invsq[m] = 1 / (m - 0.5)
    invsq[m] += invsq[m]
    m += 1
  end

  -- marching-ball per-ball constants (cart: i*136/14 and i/13)
  m = 0
  while m < 14 do
    march_off[m + 1] = (m * 136) / 14
    phase_off[m + 1] = m / 13
    m += 1
  end

  -- free single cells for the 7 trail stamps (rows 0-1 gaps)
  trailspr[1] = 3
  trailspr[2] = 4
  trailspr[3] = 9
  trailspr[4] = 10
  trailspr[5] = 11
  trailspr[6] = 25
  trailspr[7] = 26

  sfx_bank(p8sfx)
  music_bank(p8music)

  bake_sprites()
  for c = 1, 7 do
    bc_norm[c] = 128 + (c - 1) * 2
    bc_blink[c] = 160 + (c - 1) * 2
  end
  reset_game()
end
