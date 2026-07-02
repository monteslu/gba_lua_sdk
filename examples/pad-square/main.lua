-- pad-square: move a square with the d-pad. A cycles its color,
-- B/C resize it. The gtlua hello-world.

local x = 60
local y = 60
local size = 8
local color = 92
local speed = 2

function update()
  if gt.btn(gt.LEFT) then x -= speed end
  if gt.btn(gt.RIGHT) then x += speed end
  if gt.btn(gt.UP) then y -= speed end
  if gt.btn(gt.DOWN) then y += speed end

  if gt.btnp(gt.A) then color += 17 end
  if gt.btnp(gt.B) and size < 32 then size += 4 end
  if gt.btnp(gt.C) and size > 4 then size -= 4 end

  -- keep the square on screen
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end
  if x > 127 - size then x = 127 - size end
  if y > 127 - size then y = 127 - size end

  gt.cls(32)
  gt.box(x, y, size, size, color)
end
