-- audio: sfx() and music() on the GameTank audio coprocessor (FM synth).
--   boot         -> looping built-in tune 0
--   🅾️ (GT A)    -> jump sound        sfx(0)
--   ❎ (GT B)     -> explosion         sfx(3)
--   GT C         -> pickup            sfx(1)
--   up           -> toggle music on/off
--   down         -> powerup on channel 2

local playing = 1
local flash = 0

function _init()
  music(0)                 -- start built-in tune 0 (loops)
end

function _update60()
  if btnp(4) then sfx(0) flash = 8 end     -- jump
  if btnp(5) then sfx(3) flash = 8 end     -- explosion
  if btnp(6) then sfx(1) flash = 8 end     -- pickup
  if btnp(3) then sfx(5, 2) flash = 8 end  -- powerup, pinned to channel 2
  if btnp(2) then
    if playing == 1 then
      music(-1)            -- stop
      playing = 0
    else
      music(0)             -- restart, looping
      playing = 1
    end
  end
  if flash > 0 then flash -= 1 end
end

function _draw()
  cls(1)
  local c = 8
  if flash > 0 then c = 10 end
  circfill(64, 60, 20, c)
  print("sfx + music", 34, 18, 7)
  if playing == 1 then
    print("music: on", 42, 100, 11)
  else
    print("music: off", 40, 100, 8)
  end
end
