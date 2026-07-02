-- cherry-bomb (adapted port)
-- A wave survival shmup inspired by "Cherry Bomb" by Krystman / Lazy Devs
-- (lexaloffle.com/bbs/?tid=48986, CC4-BY-NC-SA). Original gameplay code:
-- this is a from-scratch gtlua implementation of the design, drawn with
-- primitives. This port: CC-BY-NC-SA 4.0.
--
-- d-pad move, 🅾️ (GT A) shoot. Survive the waves.

local px = 60
local py = 108
local plive = 1
local pflash = 0
local lives = 3
local score = 0
local wave = 0
local wavetimer = 60
local gameover = 0

-- player bullets
local bx = array(8)
local by = array(8)
local blive = array(8)
local cooldown = 0

-- enemies
local ex = array(12)
local ey = array(12)
local ebase = array(12)     -- sine center x
local ephase = array(12)
local espd = array(12)
local elive = array(12)
local left = 0

function spawn_wave()
  wave += 1
  left = 0
  for i = 1, #ex do
    if i <= 4 + wave then
      if i <= #ex then
        elive[i] = 1
        ebase[i] = 16 + (i * 23) % 96
        ex[i] = ebase[i]
        ey[i] = -8 - (i % 4) * 14
        ephase[i] = i * 0.13
        espd[i] = 0.3 + wave * 0.08 + (i % 3) * 0.1
        left += 1
      end
    else
      elive[i] = 0
    end
  end
end

function fire()
  for i = 1, #bx do
    if blive[i] == 0 and cooldown == 0 then
      blive[i] = 1
      bx[i] = px
      by[i] = py - 6
      cooldown = 8
      return
    end
  end
end

function _init()
  srand(1)
  spawn_wave()
end

function _update60()
  if gameover == 1 then
    if (btnp(4)) gameover = 0 lives = 3 score = 0 wave = 0 px = 60 spawn_wave()
    return
  end

  -- player
  if (btn(0)) px -= 2
  if (btn(1)) px += 2
  if (btn(2)) py -= 1
  if (btn(3)) py += 1
  px = mid(4, px, 123)
  py = mid(70, py, 120)
  if (btn(4)) fire()
  if (cooldown > 0) cooldown -= 1
  if (pflash > 0) pflash -= 1

  -- bullets
  for i = 1, #bx do
    if blive[i] == 1 then
      by[i] -= 4
      if (by[i] < -4) blive[i] = 0
    end
  end

  -- enemies
  for i = 1, #ex do
    if elive[i] == 1 then
      ephase[i] += 0.01
      ex[i] = ebase[i] + flr(sin(ephase[i]) * 24)
      ey[i] += espd[i]
      if ey[i] > 130 then
        ey[i] = -10
      end

      -- bullet hits
      for j = 1, #bx do
        if blive[j] == 1 then
          if abs(bx[j] - ex[i]) < 6 and abs(by[j] - flr(ey[i])) < 6 then
            blive[j] = 0
            elive[i] = 0
            left -= 1
            score += 10
          end
        end
      end

      -- player collision
      if elive[i] == 1 and pflash == 0 then
        if abs(px - ex[i]) < 7 and abs(py - flr(ey[i])) < 7 then
          lives -= 1
          pflash = 90
          if (lives <= 0) gameover = 1
        end
      end
    end
  end

  if left <= 0 then
    wavetimer -= 1
    if wavetimer <= 0 then
      wavetimer = 60
      spawn_wave()
    end
  end
end

function draw_ship(x, y, c)
  rectfill(x - 1, y - 5, x + 1, y + 4, c)
  rectfill(x - 5, y, x + 5, y + 3, c)
  rectfill(x - 3, y - 2, x + 3, y + 2, c)
  pset(x, y - 5, 7)
end

function _draw()
  cls(0)

  -- starfield scroll
  local sy = flr(t() * 30) % 128
  pset(20, sy, 5)
  pset(90, (sy + 64) % 128, 5)
  pset(55, (sy + 100) % 128, 6)
  pset(110, (sy + 30) % 128, 5)

  if gameover == 1 then
    rectfill(24, 50, 103, 70, 8)
    rect(24, 50, 103, 70, 7)
    rectfill(30, 58, 30 + mid(0, score \ 10, 60), 62, 10)
    return
  end

  -- player (flash while invulnerable)
  if pflash % 8 < 4 then
    draw_ship(px, py, 12)
  end

  -- bullets
  for i = 1, #bx do
    if (blive[i] == 1) rectfill(bx[i] - 1, by[i] - 2, bx[i], by[i] + 2, 10)
  end

  -- enemies: cherry pairs
  for i = 1, #ex do
    if elive[i] == 1 then
      local eyi = flr(ey[i])
      circfill(ex[i] - 2, eyi + 2, 3, 8)
      circfill(ex[i] + 3, eyi + 1, 3, 8)
      pset(ex[i] - 2, eyi + 1, 14)
      line(ex[i] - 2, eyi - 2, ex[i], eyi - 6, 3)
      line(ex[i] + 3, eyi - 3, ex[i], eyi - 6, 3)
    end
  end

  -- hud: lives as ships, score bar, wave pips
  for i = 1, lives do
    draw_ship(8 + i * 10, 6, 12)
  end
  rectfill(0, 0, mid(0, score \ 8, 127), 1, 10)
  for i = 1, wave do
    if (i < 16) rectfill(126 - i * 4, 5, 127 - i * 4, 8, 14)
  end
end
