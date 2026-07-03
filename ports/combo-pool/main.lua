-- combo-pool (adapted port)
-- A marble-merge arcade game inspired by "Combo Pool" by NuSan
-- (lexaloffle.com/bbs/?tid=3467, CC4-BY-NC-SA). From-scratch gtlua
-- implementation of the design, drawn with primitives.
-- This port: CC-BY-NC-SA 4.0.
--
-- ⬅️➡️ aim, 🅾️ (GT A) drop. Same-size marbles merge. Don't overflow the top.

local MAXB = 14
local px = array(14, 0.0)   -- positions (fixed)
local py = array(14, 0.0)
local vx = array(14, 0.0)
local vy = array(14, 0.0)
local sz = array(14)        -- size level 0=dead, 1..5
local drop_x = 64
local next_sz = 1
local held = 1              -- marble waiting at the top
local score = 0
local gameover = 0
local overflow = 0

local radii = array(5)
local cols = array(5)

function _init()
  srand(1)
  radii[1] = 4
  radii[2] = 6
  radii[3] = 9
  radii[4] = 13
  radii[5] = 18
  cols[1] = 12
  cols[2] = 11
  cols[3] = 10
  cols[4] = 9
  cols[5] = 8
  next_sz = 1 + flr(rnd(2))
end

function drop()
  for i = 1, MAXB do
    if sz[i] == 0 then
      sz[i] = next_sz
      px[i] = drop_x
      py[i] = 14
      vx[i] = 0
      vy[i] = 0.4
      next_sz = 1 + flr(rnd(2))
      return
    end
  end
  -- no free slot: pool is full
  gameover = 1
end

function _update()
  if gameover == 1 then
    if btnp(4) then
      gameover = 0
      score = 0
      for i = 1, MAXB do
        sz[i] = 0
      end
    end
    return
  end

  if (btn(0)) drop_x -= 3
  if (btn(1)) drop_x += 3
  drop_x = mid(10, drop_x, 117)
  if (btnp(4)) drop()

  overflow = 0
  for i = 1, MAXB do
    if sz[i] > 0 then
      -- gravity + integrate
      vy[i] += 0.12
      px[i] += vx[i]
      py[i] += vy[i]
      vx[i] *= 0.96

      -- walls and floor
      local r = radii[sz[i]]
      if px[i] < 3 + r then
        px[i] = 3 + r
        vx[i] = -vx[i] * 0.6
      end
      if px[i] > 124 - r then
        px[i] = 124 - r
        vx[i] = -vx[i] * 0.6
      end
      if py[i] > 124 - r then
        py[i] = 124 - r
        vy[i] = -vy[i] * 0.4
        if (abs(vy[i]) < 0.3) vy[i] = 0
      end

      -- overflow check: resting above the line
      if py[i] - r < 18 and abs(vy[i]) < 0.4 then
        overflow += 1
      end
    end
  end

  -- pairwise collide / merge (coarse reject in cheap int math first)
  for i = 1, MAXB do
    if sz[i] > 0 then
      for j = 1, MAXB do
        if j > i and sz[j] > 0 then
          local rr = radii[sz[i]] + radii[sz[j]]
          local dxi = flr(px[j]) - flr(px[i])
          local dyi = flr(py[j]) - flr(py[i])
          if abs(dxi) <= rr and abs(dyi) <= rr and dxi * dxi + dyi * dyi < rr * rr then
            local dx = px[j] - px[i]
            local dy = py[j] - py[i]
            local d2 = dx * dx + dy * dy
            if sz[i] == sz[j] and sz[i] < 5 then
              -- merge j into i
              sz[i] += 1
              score += sz[i] * sz[i]
              px[i] = (px[i] + px[j]) / 2
              py[i] = (py[i] + py[j]) / 2
              vy[i] = -1.2
              sz[j] = 0
            else
              -- push apart + exchange a little velocity
              local d = sqrt(d2)
              if (d < 0.25) d = 0.25
              local nx = dx / d
              local ny = dy / d
              local push = (rr - d) / 2
              px[i] -= nx * push
              py[i] -= ny * push
              px[j] += nx * push
              py[j] += ny * push
              local tvx = vx[i]
              local tvy = vy[i]
              vx[i] = vx[i] * 0.4 + vx[j] * 0.5
              vy[i] = vy[i] * 0.4 + vy[j] * 0.5
              vx[j] = vx[j] * 0.4 + tvx * 0.5
              vy[j] = vy[j] * 0.4 + tvy * 0.5
            end
          end
        end
      end
    end
  end

  if (overflow >= 3) gameover = 1
end

function _draw()
  cls(1)

  -- pool walls
  rectfill(0, 12, 2, 127, 5)
  rectfill(125, 12, 127, 127, 5)
  rectfill(0, 125, 127, 127, 5)
  -- overflow line
  line(3, 18, 124, 18, 2)

  if gameover == 1 then
    rectfill(20, 52, 107, 76, 8)
    rect(20, 52, 107, 76, 7)
    rectfill(26, 62, 26 + mid(0, score \ 8, 76), 66, 10)
    return
  end

  -- marbles
  for i = 1, MAXB do
    if sz[i] > 0 then
      local x = flr(px[i])
      local y = flr(py[i])
      circfill(x, y, radii[sz[i]], cols[sz[i]])
      pset(x - radii[sz[i]] \ 2, y - radii[sz[i]] \ 2, 7)
    end
  end

  -- dropper + next marble
  rectfill(drop_x - 1, 0, drop_x + 1, 6, 6)
  circfill(drop_x, 10, radii[next_sz], cols[next_sz])

  -- score bar
  rectfill(0, 0, mid(0, score \ 8, 127), 1, 10)
end
