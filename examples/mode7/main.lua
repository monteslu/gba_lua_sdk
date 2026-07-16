-- MODE7 — fly a camera over an affine ground plane, the GBA's signature effect.
-- The plane rotates, scales, and scrolls entirely in hardware (no per-pixel CPU).
--   d-pad left/right : turn
--   d-pad up/down    : drive forward / back (in the direction you're facing)
--   A / B            : zoom in / out
--
-- build: gbalua build --target gba examples/mode7/main.lua --mode7 examples/mode7/plane.png

local cx = 128        -- camera world position (center of the 256x256 plane)
local cy = 128
local ang = 0         -- heading, in turns (0..1)
local zoom = 1.0

function _init()
  mode7()             -- show the affine plane on BG2, Mode 1
end

function _update()
  -- turn
  if btn(0) then ang -= 0.005 end   -- left
  if btn(1) then ang += 0.005 end   -- right
  if ang < 0 then ang += 1 end
  if ang > 1 then ang -= 1 end

  -- drive along the heading. sin/cos take turns and return 16.16; scale by speed.
  local spd = 0
  if btn(2) then spd = 3 end        -- up = forward
  if btn(3) then spd = -3 end       -- down = back
  if spd != 0 then
    cx += cos(ang) * spd
    cy += sin(ang) * spd
  end

  -- zoom
  if btn(4) then zoom += 0.03 end   -- A
  if btn(5) then zoom -= 0.03 end   -- B
  if zoom < 0.25 then zoom = 0.25 end
  if zoom > 4.0 then zoom = 4.0 end

  -- drive the hardware affine camera: center on (cx,cy), rotate by ang, scale.
  mode7_cam(cx, cy, ang, zoom)
end

function _draw()
  -- the plane is drawn by hardware; a HUD sprite-text line rides on top.
  print("mode7", 8, 8, 7)
  print("dpad+ab", 8, 20, 7)
end
