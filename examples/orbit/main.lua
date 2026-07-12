-- orbit: an original gt-lua demo you actually play. Fly a little ship with the
-- d-pad (real thrust + drift), boost, and scoop up the orbiting stars for points.
-- Exercises: fixed point, trig, velocity integration, input, sfx, print, camera.
--   d-pad  -> thrust (the ship drifts; no thrust = coast)
--   🅾️ A   -> boost (a shove in the facing direction + a thruster blip)
--   ❎ B   -> honk a note
-- Collect a star (fly into it): pickup sound, +1, it respawns elsewhere.

local sx = 64.0     -- ship position (16.16 fixed)
local sy = 64.0
local vx = 0.0      -- ship velocity
local vy = 0.0
local facing = 0.0  -- last thrust direction (turns), for boost + nose dot

local score = 0
local col = array8(4)   -- ship color cycles as you score (GT bytes)

-- three orbiting stars: center, radius, phase, angular speed, "alive" cooldown
local star_cx = array(3)
local star_cy = array(3)
local star_r  = array(3)
local star_ph = array(3)
local star_sp = array(3)

function _init()
  col[1] = gt.rgb(41, 173, 255)   -- blue
  col[2] = gt.rgb(0, 228, 54)     -- green
  col[3] = gt.rgb(255, 236, 39)   -- yellow
  col[4] = gt.rgb(255, 119, 168)  -- pink
  srand(3)
  for i = 1, 3 do spawn_star(i) end
end

-- place star i on a fresh orbit around a random center
function spawn_star(i)
  star_cx[i] = 20 + flr(rnd(88))
  star_cy[i] = 20 + flr(rnd(88))
  star_r[i]  = 10 + flr(rnd(22))
  star_ph[i] = rnd(1)
  star_sp[i] = 0.004 + rnd(0.01)
end

function _update()
  -- thrust: d-pad adds velocity, and records the facing for boost
  local tx = 0.0
  local ty = 0.0
  if (btn(0)) tx -= 1
  if (btn(1)) tx += 1
  if (btn(2)) ty -= 1
  if (btn(3)) ty += 1
  if tx ~= 0 or ty ~= 0 then
    vx += tx * 0.06
    vy += ty * 0.06
    facing = atan2(tx, ty)
  end

  -- boost: a strong shove in the facing direction + a blip
  if btnp(4) then
    vx += cos(facing) * 1.5
    vy += sin(facing) * 1.5
    sfx(4)                       -- blip
  end
  if (btnp(5)) sfx(7)            -- select-honk

  -- integrate + gentle drag so it settles instead of drifting forever
  vx -= vx * 0.03
  vy -= vy * 0.03
  sx += vx
  sy += vy

  -- bounce off the screen edges (with a soft bump sound)
  if sx < 4 then sx = 4  vx = -vx * 0.6  sfx(6) end
  if sx > 123 then sx = 123  vx = -vx * 0.6  sfx(6) end
  if sy < 4 then sy = 4  vy = -vy * 0.6  sfx(6) end
  if sy > 123 then sy = 123  vy = -vy * 0.6  sfx(6) end

  -- move the stars along their orbits + check pickup
  local shipx = flr(sx)
  local shipy = flr(sy)
  for i = 1, 3 do
    star_ph[i] += star_sp[i]
    local ex = star_cx[i] + flr(cos(star_ph[i]) * star_r[i])
    local ey = star_cy[i] + flr(sin(star_ph[i]) * star_r[i])
    local dx = ex - shipx
    local dy = ey - shipy
    if dx > -5 and dx < 5 and dy > -5 and dy < 5 then
      score += 1
      sfx(1)                     -- pickup
      spawn_star(i)
    end
  end
end

function _draw()
  cls(1)                          -- dark blue backdrop

  local shipx = flr(sx)
  local shipy = flr(sy)

  -- stars on their orbits (a dotted trail + the star itself)
  for i = 1, 3 do
    local ex = star_cx[i] + flr(cos(star_ph[i]) * star_r[i])
    local ey = star_cy[i] + flr(sin(star_ph[i]) * star_r[i])
    pset(star_cx[i], star_cy[i], 5)          -- orbit center (dim)
    circfill(ex, ey, 2, 10)                  -- the star (yellow)
    pset(ex, ey - 3, 7)
  end

  -- the ship: a body that recolors as you score, plus a nose dot for facing
  local c = col[(score % 4) + 1]
  circfill(shipx, shipy, 4, c)
  local nx = shipx + flr(cos(facing) * 6)
  local ny = shipy + flr(sin(facing) * 6)
  pset(nx, ny, 7)

  -- HUD
  print("score", 4, 4, 7)
  print(score, 44, 4, 10)
  print("d-pad fly  A boost", 4, 118, 6)
end
