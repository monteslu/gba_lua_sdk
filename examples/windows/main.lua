-- WINDOWS — the GBA's hardware clipping regions. A movable "spotlight" box
-- reveals the scene; everything outside the box is hidden. Free in the PPU.
--   d-pad     : move the spotlight
--   A / B     : grow / shrink it
--   start-ish : (hold L) toggle to full screen (window off)
--
-- The scene under the light is the Mode-7 affine plane, so you also see the
-- window compose with another hardware effect.
--
-- build: gtlua build --target gba examples/windows/main.lua --mode7 examples/windows/plane.png

local wx = 120        -- spotlight center
local wy = 80
local wr = 44         -- spotlight half-size (radius of the box)

function _init()
  mode7()             -- the affine plane fills the screen (BG2)
  mode7_cam(128, 128, 0, 1.0)
end

function _update()
  -- move the spotlight
  if btn(0) then wx -= 3 end
  if btn(1) then wx += 3 end
  if btn(2) then wy -= 3 end
  if btn(3) then wy += 3 end
  -- clamp to screen
  if wx < wr then wx = wr end
  if wx > 240 - wr then wx = 240 - wr end
  if wy < wr then wy = wr end
  if wy > 160 - wr then wy = 160 - wr end

  -- grow / shrink
  if btn(4) then wr += 2 end
  if btn(5) then wr -= 2 end
  if wr < 12 then wr = 12 end
  if wr > 78 then wr = 78 end

  if btn(6) then
    -- hold L: no window, full screen
    window_off()
  else
    -- the spotlight: a box centered on (wx,wy), everything outside hidden.
    window(wx - wr, wy - wr, wx + wr, wy + wr)
  end
end

function _draw()
  -- a HUD label. NOTE: sprites are IN the window too, so the text only shows
  -- when the spotlight covers its position — draw it near the top-left and keep
  -- the light from hiding it by letting window() include sprites (it does: ALL).
  print("windows", 8, 8, 7)
end
