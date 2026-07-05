-- summit (adapted port)
-- A single-screen precision platformer inspired by "Celeste Classic" by
-- Maddy Thorson & Noel Berry (lexaloffle.com/bbs/?tid=2145). From-scratch
-- gtlua implementation of the jump+dash movement design, drawn with
-- primitives. Not affiliated with the original authors.
--
-- ⬅️➡️ run, 🅾️ (GT A) jump, ❎ (GT B) dash (direction = d-pad).
-- Climb 3 screens, grab the strawberry, avoid spikes.

local x = 12.0
local y = 100.0
local dx = 0.0
local dy = 0.0
local grounded = 0
local dashes = 1
local dtime = 0            -- frames of dash remaining
local ddx = 0.0
local ddy = 0.0
local room = 1
local deaths = 0
local berry = 0            -- collected flag
local win = 0
local freeze = 0

-- platforms per room (up to 8): x0,y0,x1,y1 packed in parallel arrays
local plx0 = array(8)
local ply0 = array(8)
local plx1 = array(8)
local ply1 = array(8)
local pn = 0

-- spikes (up to 6): x0..x1 at floor y
local spx0 = array(6)
local spx1 = array(6)
local spy = array(6)
local sn = 0

local goalx = 0
local goaly = 0

function addp(a, b, c, d)
  pn += 1
  plx0[pn] = a
  ply0[pn] = b
  plx1[pn] = c
  ply1[pn] = d
end

function adds(a, b, c)
  sn += 1
  spx0[sn] = a
  spx1[sn] = b
  spy[sn] = c
end

function load_room(n)
  pn = 0
  sn = 0
  goaly = -20
  if n == 1 then
    addp(0, 112, 127, 127)        -- floor
    addp(48, 88, 80, 94)          -- mid ledge
    addp(96, 64, 127, 70)         -- right ledge
    addp(0, 40, 24, 46)           -- top-left exit ledge
    adds(28, 44, 112)             -- floor spikes
    adds(84, 92, 112)
  end
  if n == 2 then
    addp(0, 112, 40, 127)         -- entry floor
    addp(64, 96, 88, 102)
    addp(24, 72, 48, 78)
    addp(88, 52, 118, 58)
    addp(0, 28, 20, 34)           -- exit ledge
    adds(41, 63, 124)             -- pit spikes
    adds(89, 127, 124)
    adds(92, 114, 52)             -- ledge spikes
  end
  if n == 3 then
    addp(0, 112, 127, 127)
    addp(30, 90, 50, 96)
    addp(70, 72, 90, 78)
    addp(40, 50, 60, 56)
    addp(90, 34, 110, 40)
    adds(0, 28, 112)
    adds(52, 68, 112)
    goalx = 100
    goaly = 24
  end
end

function respawn()
  x = 12.0
  y = 100.0
  dx = 0
  dy = 0
  dtime = 0
  dashes = 1
  if (room == 2) y = 100.0
  if (room == 3) y = 100.0
end

function die()
  deaths += 1
  freeze = 6
  respawn()
end

-- solid test for the player's 5x6 box at (nx, ny)
local hitfloor = 0
function solid(nx, ny)
  for i = 1, pn do
    if nx + 4 > plx0[i] and nx < plx1[i] and ny + 6 > ply0[i] and ny < ply1[i] then
      hitfloor = i
      return 1
    end
  end
  hitfloor = 0
  return 0
end

-- background hills, rasterized ONCE into row spans (identical pixels to the
-- three circfills, ~35 span fills instead of ~88 blits + Bresenham per frame;
-- rows >= 120 are covered by the ground fill so only the domes are needed)
local hn = 0
local hx0 = array(48)
local hx1 = array(48)
local hy = array(48)

function hill_spans(cx, cy, r)
  local dy = -r
  while dy <= r do
    local y = cy + dy
    if y >= 104 and y < 120 then
      local dx = flr(sqrt(r * r - dy * dy))
      hn += 1
      hx0[hn] = cx - dx
      hx1[hn] = cx + dx
      hy[hn] = y
    end
    dy += 1
  end
end

function _init()
  gt.autocls(1)                 -- the frame clear rides the post-flip vsync wait
  hill_spans(24, 122, 14)
  hill_spans(70, 126, 18)
  hill_spans(104, 121, 12)
  load_room(1)
end

function _update()
  if freeze > 0 then
    freeze -= 1
    return
  end
  if win == 1 then
    if (btnp(4)) win = 0 room = 1 deaths = 0 berry = 0 load_room(1) respawn()
    return
  end

  local fx = flr(x)
  local fy = flr(y)

  if dtime > 0 then
    -- dashing: fixed velocity, gravity off
    dtime -= 1
    dx = ddx
    dy = ddy
  else
    -- run
    local accel = 0.4
    if (grounded == 0) accel = 0.24
    if btn(0) then
      dx -= accel
    else
      if btn(1) then
        dx += accel
      else
        dx *= 0.65
        if (abs(dx) < 0.2) dx = 0
      end
    end
    dx = mid(-3, dx, 3)

    -- gravity
    dy += 0.36
    if (dy > 4) dy = 4

    -- jump
    if grounded == 1 and btnp(4) then
      dy = -4.4
      grounded = 0
    end

    -- dash
    if dashes > 0 and btnp(5) then
      local ax = 0.0
      local ay = 0.0
      if (btn(0)) ax = -1
      if (btn(1)) ax = 1
      if (btn(2)) ay = -1
      if (btn(3)) ay = 1
      if ax == 0 and ay == 0 then
        ax = 1
        if (dx < 0) ax = -1
      end
      ddx = ax * 5.4
      ddy = ay * 5.4
      if (ax ~= 0 and ay ~= 0) ddx = ax * 4 ddy = ay * 4
      dtime = 5
      dashes -= 1
      freeze = 2
    end
  end

  -- move horizontally
  x += dx
  if (x < 0) x = 0
  if x > 123 then
    -- right edge: nothing special
    x = 123
  end
  if solid(flr(x), fy) ~= 0 then
    x = fx
    dx = 0
  end

  -- move vertically
  y += dy
  grounded = 0
  if solid(flr(x), flr(y)) ~= 0 then
    if dy > 0 then
      -- land on top
      y = ply0[hitfloor] - 6
      grounded = 1
      dashes = 1
      dtime = 0
    else
      y = flr(y) + 1
    end
    dy = 0
  end

  -- room transitions: exit off the top-left ledge
  if y < -6 then
    if room < 3 then
      room += 1
      load_room(room)
      x = 12.0
      y = 110.0
      dy = -1
    end
  end
  if (y > 130) die()

  fx = flr(x)
  fy = flr(y)

  -- spikes
  for i = 1, sn do
    if fx + 4 > spx0[i] and fx < spx1[i] and fy + 6 > spy[i] - 3 and fy < spy[i] + 2 then
      die()
    end
  end

  -- strawberry
  if room == 3 and berry == 0 then
    if abs(fx - goalx) < 7 and abs(fy - goaly) < 8 then
      berry = 1
      win = 1
    end
  end
end

function _draw()

  -- background hills (precomputed spans + the ground band)
  rectfill(0, 120, 127, 127, 13)
  -- constant bound on purpose: the compiler narrows the counter to a byte
  -- and folds the 1-based indexing only for provably-bounded loops — worth
  -- ~1k cycles/frame here, which is real margin this close to the vsync line
  for i = 1, 35 do
    rectfill(hx0[i], hy[i], hx1[i], hy[i], 13)
  end

  -- platforms
  for i = 1, pn do
    rectfill(plx0[i], ply0[i], plx1[i], ply1[i], 5)
    rectfill(plx0[i], ply0[i], plx1[i], ply0[i] + 1, 11)
  end

  -- spikes: cheap tooth strip (one fill + tip dots)
  for i = 1, sn do
    rectfill(spx0[i], spy[i] - 2, spx1[i], spy[i], 6)
    local sx = spx0[i] + 2
    while sx < spx1[i] do
      -- teeth as 1x2 fills: pset would bounce the pipeline between CPU mode
      -- and the blitter per tooth (a queue drain each way); a fill stays on
      -- the blitter path. Same pixels.
      rectfill(sx, spy[i] - 4, sx, spy[i] - 3, 6)
      sx += 4
    end
  end

  -- strawberry
  if room == 3 and berry == 0 then
    local bob = flr(sin(t()) * 2)
    circfill(goalx, goaly + bob, 3, 8)
    rectfill(goalx - 1, goaly + bob - 1, goalx - 1, goaly + bob - 1, 7)
    -- the 3px stem as fills (a diagonal line() walks pset_raw in CPU mode)
    rectfill(goalx, goaly + bob - 4, goalx, goaly + bob - 4, 11)
    rectfill(goalx + 1, goaly + bob - 4, goalx + 1, goaly + bob - 5, 11)
    rectfill(goalx + 2, goaly + bob - 5, goalx + 2, goaly + bob - 5, 11)
  end

  -- player: hair color shows dash availability
  local fx = flr(x)
  local fy = flr(y)
  local hair = 8
  if (dashes == 0) hair = 12
  rectfill(fx, fy, fx + 4, fy + 5, 15)
  rectfill(fx, fy, fx + 4, fy + 2, hair)
  -- eyes as 1x1 FILLS: a pset here switches the pipeline to CPU mode, and
  -- that transition drains every queued fill's pixels first (~16k cycles
  -- with a full clear in flight). Two pixels were costing two drains.
  rectfill(fx + 1, fy + 3, fx + 1, fy + 3, 0)
  rectfill(fx + 3, fy + 3, fx + 3, fy + 3, 0)

  -- hud: room pips + death count bar
  for i = 1, room do
    rectfill(i * 6 - 4, 2, i * 6 - 1, 5, 7)
  end
  if (deaths > 0) rectfill(127 - mid(0, deaths, 40), 2, 127, 3, 8)

  if win == 1 then
    rectfill(28, 54, 99, 74, 3)
    rect(28, 54, 99, 74, 7)
    circfill(64, 64, 4, 8)
    rectfill(63, 62, 63, 62, 7)
  end
end
