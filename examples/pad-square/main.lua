-- pad-square: the gt-lua hello-world - a movable, resizable square.
-- d-pad moves, 🅾️ cycles color, ❎ grows, button 6 (GameTank C) shrinks.

local x = 60
local y = 60
local size = 8
-- colors are raw GameTank bytes; 🅾️ cycles over a small table of gt.rgb bytes
-- (a runtime-computed color is a raw byte, not a 0-15 index - see docs/PALETTE.md)
local pal = array8(6)
local ci = 0
local speed = 2

function _init()
  pal[1] = gt.rgb(255, 0, 77)     -- red
  pal[2] = gt.rgb(255, 163, 0)    -- orange
  pal[3] = gt.rgb(255, 236, 39)   -- yellow
  pal[4] = gt.rgb(0, 228, 54)     -- green
  pal[5] = gt.rgb(41, 173, 255)   -- blue
  pal[6] = gt.rgb(255, 119, 168)  -- pink
end

function _update60()
  if (btn(0)) x -= speed
  if (btn(1)) x += speed
  if (btn(2)) y -= speed
  if (btn(3)) y += speed

  if (btnp(4)) ci = (ci + 1) % 6
  if (btnp(5)) size = mid(4, size + 4, 32)
  if (btnp(6)) size = mid(4, size - 4, 32)

  x = mid(0, x, 127 - size)
  y = mid(0, y, 127 - size)
end

function _draw()
  cls(1)
  rectfill(x, y, x + size - 1, y + size - 1, pal[ci + 1])
  rect(x - 2, y - 2, x + size + 1, y + size + 1, 7)
end
