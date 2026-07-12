-- orbit: an original gt-lua demo - a planet orbits with sin/cos turn math,
-- d-pad nudges the orbit, 🅾️ reverses, ❎ cycles the planet color.
-- Exercises: fixed point, trig, one-line ifs, btnp, circfill, camera.

local angle = 0
local speed = 0.016
local radius = 40
-- a small palette of GameTank color bytes to cycle the planet through. Runtime-
-- computed colors are raw GT bytes (not PICO-8 indices), so we cycle over actual
-- bytes here - the native way to do "change colors" on the GameTank.
local ship_pal = array8(6)
local ship_i = 0
local trail = 0.0
local shake = 0
local ringx = array(16)
local ringy = array(16)
local lastr = 0

function _init()
  srand(7)
  -- six GameTank color bytes to cycle the planet through (red, orange, yellow,
  -- green, blue, pink) - gt.rgb resolves each to a byte at compile time.
  ship_pal[1] = gt.rgb(255, 0, 77)
  ship_pal[2] = gt.rgb(255, 163, 0)
  ship_pal[3] = gt.rgb(255, 236, 39)
  ship_pal[4] = gt.rgb(0, 228, 54)
  ship_pal[5] = gt.rgb(41, 173, 255)
  ship_pal[6] = gt.rgb(255, 119, 168)
end

function _update()
  angle += speed
  if (btn(0)) radius -= 2
  if (btn(1)) radius += 2
  if (btnp(4)) speed = -speed
  if (btnp(5)) ship_i = (ship_i + 1) % 6
  radius = mid(8, radius, 58)
  if (btnp(2)) shake = 6
  if (shake > 0) shake -= 1
end

function _draw()
  cls(1)                          -- p8 dark blue

  local cx = 64
  local cy = 64
  if shake > 0 then
    cx += flr(rnd(shake)) - shake \ 2
    cy += flr(rnd(shake)) - shake \ 2
  end

  -- orbit ring: dotted, precomputed when radius changes
  if radius ~= lastr then
    for k = 1, 16 do
      ringx[k] = flr(cos(k * 0.0625) * radius)
      ringy[k] = flr(sin(k * 0.0625) * radius)
    end
    lastr = radius
  end
  for k = 1, 16 do
    pset(cx + ringx[k], cy + ringy[k], 13)
  end

  -- sun
  circfill(cx, cy, 10, 9)
  circfill(cx, cy, 7, 10)

  -- planet on the orbit
  local px = cx + flr(cos(angle) * radius)
  local py = cy + flr(sin(angle) * radius)
  circfill(px, py, 5, ship_pal[ship_i + 1])
  pset(px, py - 6, 7)

  -- moon, twice the angular speed, quarter turn ahead
  local mx = px + flr(cos(angle * 2 + 0.25) * 8)
  local my = py + flr(sin(angle * 2 + 0.25) * 8)
  circfill(mx, my, 2, 6)

  -- starfield corners + hud line
  pset(10, 10, 7)
  pset(120, 14, 6)
  pset(24, 110, 7)
  pset(100, 100, 6)
  line(0, 127, flr(t() * 8) % 128, 127, 11)
end
