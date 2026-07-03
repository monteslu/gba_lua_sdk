-- ufo-swamp (adapted port)
-- A gravity cave-flier inspired by "UFO Swamp Odyssey" by Paranoid Cactus
-- (lexaloffle.com/bbs/?tid=38153, CC4-BY-NC-SA). From-scratch gtlua
-- implementation of the thrust-and-rescue design, drawn with primitives.
-- This port: CC-BY-NC-SA 4.0.
--
-- 🅾️ (GT A) thrust up, ⬅️➡️ steer. Collect the frogs, reach the exit pad.
-- Touching walls hurts; watch the fuel bar. Fuel refills on a pad.

local ux = 16.0
local uy = 24.0
local vx = 0.0
local vy = 0.0
local fuel = 100
local hp = 3
local hurt = 0
local room = 1
local frogs = 0
local needed = 0
local win = 0
local dead = 0
local wob = 0.0

-- walls per room (up to 10 rects)
local wx0 = array(10)
local wy0 = array(10)
local wx1 = array(10)
local wy1 = array(10)
local wn = 0

-- frogs (up to 4)
local fx = array(4)
local fy = array(4)
local flive = array(4)
local fn = 0

local padx = 0
local pady = 0

function addw(a, b, c, d)
  wn += 1
  wx0[wn] = a
  wy0[wn] = b
  wx1[wn] = c
  wy1[wn] = d
end

function addf(a, b)
  fn += 1
  fx[fn] = a
  fy[fn] = b
  flive[fn] = 1
end

function load_room(n)
  wn = 0
  fn = 0
  ux = 16.0
  uy = 24.0
  vx = 0
  vy = 0
  if n == 1 then
    addw(0, 0, 127, 8)          -- ceiling
    addw(0, 120, 127, 127)      -- floor
    addw(0, 0, 6, 127)          -- left wall
    addw(121, 0, 127, 127)      -- right wall
    addw(40, 60, 88, 127)       -- center stalagmite block
    addw(70, 8, 90, 40)         -- hanging block
    addf(20, 108)
    addf(104, 108)
    addf(56, 48)
    padx = 100
    pady = 116
  end
  if n == 2 then
    addw(0, 0, 127, 8)
    addw(0, 120, 127, 127)
    addw(0, 0, 6, 127)
    addw(121, 0, 127, 127)
    addw(6, 40, 60, 56)         -- shelf left
    addw(70, 80, 121, 96)       -- shelf right
    addw(30, 96, 44, 120)       -- pillar
    addw(88, 8, 100, 60)        -- hanging wall
    addf(14, 110)
    addf(110, 70)
    addf(16, 30)
    addf(60, 108)
    padx = 108
    pady = 112
  end
  needed = fn
  frogs = 0
end

function _init()
  load_room(1)
end

function hitwall(nx, ny)
  for i = 1, wn do
    if nx + 3 > wx0[i] and nx - 3 < wx1[i] and ny + 2 > wy0[i] and ny - 2 < wy1[i] then
      return 1
    end
  end
  return 0
end

function _update()
  if dead == 1 or win == 1 then
    if btnp(4) then
      dead = 0
      win = 0
      hp = 3
      fuel = 100
      room = 1
      load_room(1)
    end
    return
  end

  wob += 0.04

  -- thrust
  if btn(4) and fuel > 0 then
    vy -= 0.18
    fuel -= 2
    if (fuel < 0) fuel = 0
  end
  if (btn(0)) vx -= 0.08
  if (btn(1)) vx += 0.08

  -- gravity + drag
  vy += 0.09
  vx *= 0.94
  vy = mid(-3, vy, 3)
  vx = mid(-2.6, vx, 2.6)

  local ox = ux
  local oy = uy
  ux += vx
  uy += vy

  if (hurt > 0) hurt -= 1

  if hitwall(flr(ux), flr(uy)) == 1 then
    ux = ox
    uy = oy
    vx = -vx * 0.5
    vy = -vy * 0.5
    if hurt == 0 then
      hp -= 1
      hurt = 30
      if (hp <= 0) dead = 1
    end
  end

  -- frogs
  for i = 1, fn do
    if flive[i] == 1 then
      if abs(flr(ux) - fx[i]) < 6 and abs(flr(uy) - fy[i]) < 7 then
        flive[i] = 0
        frogs += 1
      end
    end
  end

  -- landing pad: refuel, and exit when all frogs held
  if abs(flr(ux) - padx) < 8 and abs(flr(uy) - pady) < 6 then
    if (fuel < 100) fuel += 4
    if (fuel > 100) fuel = 100
    if frogs >= needed then
      if room == 1 then
        room = 2
        load_room(2)
      else
        win = 1
      end
    end
  end
end

function _draw()
  cls(0)

  -- swamp glow
  rectfill(34, 122, 94, 127, 3)

  -- cave walls
  for i = 1, wn do
    rectfill(wx0[i], wy0[i], wx1[i], wy1[i], 3)
    rectfill(wx0[i], wy0[i], wx1[i], wy0[i] + 1, 11)
  end

  -- landing pad
  rectfill(padx - 8, pady + 3, padx + 8, pady + 5, 6)
  pset(padx - 8, pady + 2, 10)
  pset(padx + 8, pady + 2, 10)

  -- frogs
  for i = 1, fn do
    if flive[i] == 1 then
      local hop = flr(sin(wob + i * 0.3) * 2)
      rectfill(fx[i] - 2, fy[i] + hop - 2, fx[i] + 2, fy[i] + hop + 2, 11)
      pset(fx[i] - 1, fy[i] + hop - 2, 7)
      pset(fx[i] + 1, fy[i] + hop - 2, 7)
    end
  end

  if dead == 1 then
    rectfill(30, 54, 97, 72, 8)
    rect(30, 54, 97, 72, 7)
    return
  end
  if win == 1 then
    rectfill(30, 54, 97, 72, 11)
    rect(30, 54, 97, 72, 7)
    circfill(64, 63, 4, 7)
    return
  end

  -- the UFO (flash while hurt)
  if hurt % 8 < 4 then
    local x = flr(ux)
    local y = flr(uy)
    rectfill(x - 2, y - 4, x + 2, y - 1, 12)  -- dome
    rectfill(x - 6, y, x + 6, y + 2, 6)       -- saucer
    pset(x - 4, y + 3, 10)
    pset(x, y + 3, 10)
    pset(x + 4, y + 3, 10)
    if btn(4) and fuel > 0 then
      line(x - 2, y + 4, x - 1, y + 6, 9)
      line(x + 2, y + 4, x + 1, y + 6, 9)
    end
  end

  -- hud: fuel bar, hp pips, frog count pips
  rectfill(2, 2, 2 + fuel \ 2, 3, 9)
  for i = 1, hp do
    rectfill(114 + i * 4, 2, 116 + i * 4, 4, 8)
  end
  for i = 1, frogs do
    rectfill(i * 6 - 2, 6, i * 6 + 1, 9, 11)
  end
end
