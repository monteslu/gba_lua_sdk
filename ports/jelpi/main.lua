-- jelpi (adapted port)
-- A run-and-stomp platformer inspired by "Jelpi", zep's PICO-8 demo cart
-- (ships with PICO-8; no formal license — this is a from-scratch gtlua
-- implementation of the run/jump/stomp design, drawn with primitives, not
-- affiliated with Lexaloffle).
--
-- ⬅️➡️ run, 🅾️ (GT A) jump. Stomp the critters, grab the coins,
-- reach the flag.

local x = 10.0
local y = 90.0
local dx = 0.0
local dy = 0.0
local grounded = 0
local face = 1
local coins = 0
local hp = 3
local hurt = 0
local win = 0
local dead = 0
local anim = 0.0
local anim8 = 0                 -- 64ths-of-a-turn mirror for the bob LUT
local bobsin = array(64)

-- platforms
local plx0 = array(8)
local ply0 = array(8)
local plx1 = array(8)
local ply1 = array(8)
local pn = 0

-- critters
local cx = array(5, 0.0)
local cdir = array(5)
local cy = array(5)
local cx0 = array(5)      -- patrol bounds
local cx1 = array(5)
local clive = array(5)
local cn = 0

-- coins
local nx = array(6)
local ny = array(6)
local nlive = array(6)
local nn = 0

local flagx = 118
local flagy = 0

function addp(a, b, c, d)
  pn += 1
  plx0[pn] = a
  ply0[pn] = b
  plx1[pn] = c
  ply1[pn] = d
end

function addc(a, b, lo, hi)
  cn += 1
  cx[cn] = a
  cy[cn] = b
  cx0[cn] = lo
  cx1[cn] = hi
  cdir[cn] = 1
  clive[cn] = 1
end

function addn(a, b)
  nn += 1
  nx[nn] = a
  ny[nn] = b
  nlive[nn] = 1
end

function build_level()
  pn = 0
  cn = 0
  nn = 0
  addp(0, 104, 60, 127)         -- left ground
  addp(76, 104, 127, 127)       -- right ground (gap between)
  addp(28, 80, 56, 86)          -- step
  addp(64, 60, 96, 66)          -- higher step
  addp(100, 84, 127, 90)        -- ledge to flag
  addc(20, 98, 8, 52)        -- ground critter
  addc(88, 98, 80, 118)      -- right ground critter
  addc(70, 54, 66, 92)       -- platform critter
  addn(40, 72)
  addn(80, 52)
  addn(110, 76)
  addn(10, 96)
  flagy = 84
end

local hitp = 0
function solid(px, py)
  for i = 1, pn do
    if px + 4 > plx0[i] and px < plx1[i] and py + 7 > ply0[i] and py < ply1[i] then
      hitp = i
      return 1
    end
  end
  return 0
end

function respawn()
  x = 10.0
  y = 90.0
  dx = 0
  dy = 0
end

-- static sky decor lives in GRAM cells (sset once at boot) and blits as two
-- sprites; drawing it with circfills was ~38 blits + Bresenham per frame.
-- Cell blocks: sun 17x17 at cells 6..8 (3x3), cloud 23x8 at cells 9..11 (3x1
-- of the lobes' visible band + the rect drawn live, it's 1 fill).
function decor_disc(bx, by, cx, cy, r, c)
  local dy = -r
  while dy <= r do
    local w = flr(sqrt(r * r - dy * dy))
    local xx = -w
    while xx <= w do
      sset(bx + cx + xx, by + cy + dy, c)
      xx += 1
    end
    dy += 1
  end
end

function decor_clear(bx, by, w, h)
  local yy = 0
  while yy < h do
    local xx = 0
    while xx < w do
      sset(bx + xx, by + yy, 0)
      xx += 1
    end
    yy += 1
  end
end

-- disc sprites: an r2 circfill through the C circle machinery costs ~2k
-- cycles; the same disc sset into a sheet cell at boot blits for ~190.
-- Cell 1 = yellow disc (coins + coin pips), cell 2 = red disc (hearts).
function make_disc(cell, c, r)
  local bx = (cell % 16) * 8
  local by = (cell \ 16) * 8
  local bs = 8
  if (r > 3) bs = 16
  -- clear the whole cell block first: GRAM boots random, and spr() only
  -- colorkeys value 0 — un-cleared neighbors render as noise squares
  local yy = 0
  while yy < bs do
    local xx = 0
    while xx < bs do
      sset(bx + xx, by + yy, 0)
      xx += 1
    end
    yy += 1
  end
  local cx = bx + r
  local cy = by + r
  local dy = -r
  while dy <= r do
    local w = flr(sqrt(r * r - dy * dy))
    local xx = -w
    while xx <= w do
      sset(cx + xx, cy + dy, c)
      xx += 1
    end
    dy += 1
  end
end

function _init()
  make_disc(1, 10, 2)           -- coin / coin pip
  make_disc(2, 8, 2)            -- heart
  make_disc(3, 8, 4)            -- critter body (9x9: spans cells 3,4,19,20)
  make_disc(5, 15, 3)           -- player head (7x7)
  decor_clear(48, 0, 24, 24)    -- sun block: cells 6..8 x 3 rows
  decor_disc(48, 0, 8, 8, 8, 10)
  decor_clear(72, 0, 24, 16)    -- cloud block: cells 9..11 x 2 rows
  decor_disc(72, 0, 4, 7, 5, 7)     -- lobe (28,18) rel to (24,11)
  decor_disc(72, 0, 16, 6, 6, 7)    -- lobe (40,17)
  for i = 1, 64 do
    bobsin[i] = flr(sin((i - 1) / 64) * 2)   -- coin-bob LUT
  end
  gt.autocls(12)               -- frame clear rides the post-flip vsync wait
  build_level()
end

function _update()
  if dead == 1 or win == 1 then
    if btnp(4) then
      dead = 0
      win = 0
      hp = 3
      coins = 0
      build_level()
      respawn()
    end
    return
  end

  anim += 0.06
  anim8 = (anim8 + 4) & 63      -- 0.06 turns ~ 3.84/64; 4 keeps the wave rate
  if (hurt > 0) hurt -= 1

  -- run
  if btn(0) then
    dx -= 0.3
    face = -1
  else
    if btn(1) then
      dx += 0.3
      face = 1
    else
      dx *= 0.65
      if (abs(dx) < 0.15) dx = 0
    end
  end
  dx = mid(-2.6, dx, 2.6)

  -- gravity
  dy += 0.32
  if (dy > 4) dy = 4

  -- jump
  if (grounded == 1 and btnp(4)) dy = -3.8 grounded = 0

  local fxp = flr(x)
  local fyp = flr(y)

  x += dx
  x = mid(0, x, 122)
  if (solid(flr(x), fyp) ~= 0) x = fxp dx = 0

  y += dy
  grounded = 0
  if solid(flr(x), flr(y)) ~= 0 then
    if dy > 0 then
      y = ply0[hitp] - 7
      grounded = 1
    else
      y = flr(y) + 1
    end
    dy = 0
  end
  if (y > 132) hp = 0 dead = 1

  fxp = flr(x)
  fyp = flr(y)

  -- critters patrol
  for i = 1, cn do
    if clive[i] == 1 then
      cx[i] += cdir[i] * 0.8
      if (cx[i] < cx0[i]) cdir[i] = 1
      if (cx[i] > cx1[i]) cdir[i] = -1

      local ccx = flr(cx[i])
      if abs(fxp - ccx) < 6 and abs(fyp - cy[i]) < 8 then
        if dy > 0.5 and fyp < cy[i] - 2 then
          -- stomp!
          clive[i] = 0
          dy = -2.5
          coins += 1
        else
          if hurt == 0 then
            hp -= 1
            hurt = 30
            dx = -face * 3
            dy = -1.6
            if (hp <= 0) dead = 1
          end
        end
      end
    end
  end

  -- coins
  for i = 1, nn do
    if nlive[i] == 1 then
      if abs(fxp - nx[i]) < 6 and abs(fyp - ny[i]) < 8 then
        nlive[i] = 0
        coins += 1
      end
    end
  end

  -- flag
  if (fxp > flagx - 6 and fyp + 7 > flagy) win = 1
end

function _draw()
  cls(12)                       -- sky

  -- sun + cloud: one sprite each (blocks built at boot)
  spr(6, 100, 6, 3, 3)
  rectfill(24, 18, 46, 24, 7)
  spr(9, 24, 11, 3, 2)

  -- platforms: dirt with grass tops
  for i = 1, pn do
    rectfill(plx0[i], ply0[i], plx1[i], ply1[i], 4)
    rectfill(plx0[i], ply0[i], plx1[i], ply0[i] + 2, 11)
  end

  -- the gap is a pit: water at the bottom
  rectfill(60, 124, 76, 127, 1)

  -- coins
  for i = 1, nn do
    if nlive[i] == 1 then
      local bob = bobsin[((anim8 + i * 13) & 63) + 1]
      spr(1, nx[i] - 2, ny[i] + bob - 2)
      rectfill(nx[i], ny[i] + bob - 1, nx[i], ny[i] + bob - 1, 7)
    end
  end

  -- critters
  for i = 1, cn do
    if clive[i] == 1 then
      local ccx = flr(cx[i])
      spr(3, ccx - 4, cy[i] - 2, 2, 2)
      rectfill(ccx - 4, cy[i] + 4, ccx + 4, cy[i] + 6, 2)
      pset(ccx - 2, cy[i], 7)
      pset(ccx + 2, cy[i], 7)
    end
  end

  -- flag
  line(flagx, flagy, flagx, flagy - 18, 6)
  rectfill(flagx + 1, flagy - 18, flagx + 8, flagy - 12, 8)

  -- jelpi: little jumping hero
  if hurt % 8 < 4 then
    local px = flr(x)
    local py = flr(y)
    rectfill(px, py + 2, px + 4, py + 6, 9)          -- body
    spr(5, px - 1, py - 3)                           -- head (7x7 disc cell)
    pset(px + 2 + face, py, 0)                       -- eye
    if grounded == 1 and abs(dx) > 0.2 then
      local step = flr(anim * 40) % 2
      if step == 0 then
        pset(px, py + 7, 9)
        pset(px + 4, py + 6, 9)
      else
        pset(px, py + 6, 9)
        pset(px + 4, py + 7, 9)
      end
    end
  end

  -- hud: hp hearts + coin pips
  for i = 1, hp do
    spr(2, i * 8 - 5, 2)
  end
  for i = 1, coins do
    if (i < 16) spr(1, 118 - i * 6, 2)
  end

  if dead == 1 then
    rectfill(30, 54, 97, 72, 8)
    rect(30, 54, 97, 72, 7)
  end
  if win == 1 then
    rectfill(30, 54, 97, 72, 11)
    rect(30, 54, 97, 72, 7)
    circfill(64, 63, 4, 10)
  end
end
