-- EFFECTS — shows off the GBA's free hardware color unit: fade + blend.
-- A colorful bitmap scene with bouncing sprites. The whole screen pulses
-- fade-to-black then fade-to-white; press A to instead ghost the sprites
-- (semi-transparent) over the scene. No per-pixel CPU — the PPU does it all.
--
-- build: gtlua build --target gba examples/effects/main.lua \
--          --sheet examples/effects/blob.png

local t = 0
local sx = array(6)
local sy = array(6)
local vx = array(6)
local vy = array(6)

function _init()
  music(0)   -- the richer 4-channel background tune (bitmap mode, now stable)
  for i=1,6 do
    sx[i] = 20 + i*30
    sy[i] = 40 + (i*17) % 80
    vx[i] = (i % 2)*4 - 2   -- -2 or +2
    vy[i] = (i % 3) - 1     -- -1, 0, or 1
    if vx[i] == 0 then vx[i] = 2 end
    if vy[i] == 0 then vy[i] = 1 end
  end
end

function _update()
  t += 1
  for i=1,6 do
    sx[i] += vx[i]
    sy[i] += vy[i]
    if sx[i] < 4 or sx[i] > 220 then vx[i] = -vx[i] end
    if sy[i] < 4 or sy[i] > 140 then vy[i] = -vy[i] end
  end

  if btn(4) then
    -- A held: ghost the sprites (OBJ layer = 4) at ~45% opacity over the scene.
    blend(4, 0.45)
  else
    -- otherwise: pulse the whole screen. A triangle wave over time drives the
    -- fade amount; the first half fades to black, the second half to white.
    local phase = t % 120
    if phase < 60 then
      -- 0..59 -> fade to black, ramp up 0 -> ~1 -> 0
      local a = phase / 60
      if a > 0.5 then a = 1 - a end
      fade(a*2)               -- fade to black (default)
    else
      local p = phase - 60
      local a = p / 60
      if a > 0.5 then a = 1 - a end
      fade(a*2, true)         -- fade to white
    end
  end
end

function _draw()
  cls(1)   -- dark blue backdrop
  -- a few bands of color so the fade is obvious across the whole screen
  rectfill(0, 0, 239, 26, 3)     -- green top band
  rectfill(0, 130, 239, 159, 8)  -- red bottom band
  circfill(120, 80, 30, 12)      -- blue disc center
  print("effects: fade + blend", 8, 4, 7)
  print("hold a: ghost", 8, 148, 7)

  -- the bouncing blobs (16x16 sprites)
  for i=1,6 do
    spr(0, sx[i], sy[i], 2, 2)
  end
end
