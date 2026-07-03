-- newleste — GameTank port
--
-- A gtlua hand-port of newleste.p8 (the CelesteClassic community's base
-- cart, built on evercore v2.0.2), for the GameTank console.
--   original game: Maddy Thorson + Noel Berry
--   newleste.p8 / evercore: taco360, meep, gonengazit, akliant and the
--   CelesteClassic community — github.com/CelesteClassic/newleste.p8
-- newleste.p8 is GPL-3.0; this port (this file, tools/, gfx.bin) is
-- likewise GPL-3.0 — see ports/newleste/LICENSE. Source cart:
-- carts/newleste-base.p8. Divergences are documented in PORT_NOTES.md.
--
-- ⬅️➡️⬆️⬇️ move, 🅾️ (GT A) jump, ❎ (GT B) dash. P2 ⬆️ toggles screenshake.
--
-- Build (from the repo root; regenerate map/gfx with tools/genassets.mjs):
--   node ports/newleste/tools/genassets.mjs
--   node bin/gtlua.js build ports/newleste/main.lua --sheet ports/newleste/gfx.bin
--
-- The cart runs _update() at 30 fps, same as PICO-8, so every movement
-- constant below is carried over from the original unchanged.

-- ---------------------------------------------------------------------
-- map + sprite flags (filled by map_init, generated from __map__/__gff__)
-- ---------------------------------------------------------------------
-- 64 cols x 16 rows; mget(x,y) = m[y*64+x+1]. Level 1 = cols 0-15,
-- level 2 = cols 16-63. fl[t+1] = PICO-8 fget byte for tile t:
--   bit0 (1) solid  bit1 (2) terrain/spikes  bit2 (4) bg  bit3 (8) one-way
-- PERF: the map + flag tables hold bytes (tile ids 0-255, flag masks 0-15),
-- so array8 stores them one byte per cell — HALF the RAM (2KB -> 1KB for m)
-- and roughly half the cycles per read in the collision scans and the level
-- composer, the hottest array reads in the game. See docs/performance.md.
local m = array8(1024)
local fl = array8(64)

-- ---------------------------------------------------------------------
-- globals
-- ---------------------------------------------------------------------
local freeze = 0
local delay_restart = 0
local sfx_timer = 0
local ui_timer = -99
local shake = 0
local screenshake = 0          -- newleste defaults screenshake OFF
local full_restart = 0
local has_dashed = 0

local frames = 0
local seconds = 0
local minutes = 0
local time_ticking = 1
local deaths = 0
local max_djump = 1
local berry_count = 0

-- camera
local cam_x = 0.0
local cam_y = 0.0
local cam_spdx = 0.0
local cam_spdy = 0.0
local draw_x = 0
local draw_y = 0

-- level
local lvl_id = 0
local lvl_x = 0
local lvl_y = 0
local lvl_w = 16
local lvl_h = 16
local lvl_pw = 128
local lvl_ph = 128
local exit_top = 1
local exit_right = 0
local exit_bottom = 0
local exit_left = 0

-- transition wipe
local tstate = -1
local tpos = -20

-- player / spawn (pmode: 0 = none, 1 = player_spawn, 2 = player)
local pmode = 0
local px = 0
local py = 0
-- PERF: player speeds/remainders are 8.8 fixed-point stored in fast 16-bit
-- INTS (value*256), not 16.16 longs. Speeds never exceed +-8, remainders are
-- always in (-1,1), so 8.8 loses nothing that survives to a pixel — and every
-- add/compare becomes cheap int math instead of 4-byte long arithmetic.
-- 256 = 1.0. See docs/performance.md "shrink your fixed-point".
local prx8 = 0
local pry8 = 0
local pvx8 = 0
local pvy8 = 0
local pflip = 0
local pdjump = 1
local pgrace = 0
local pjbuf = 0
local pdash_t = 0
local pdash_eff = 0
local pdtx8 = 0
local pdty8 = 0
local pdax8 = 0
local pday8 = 0
local psproff8 = 0
local pspr = 1
local pwasog = 0
local pphin = 0
local pjprev = 0
local pdprev = 0
local pbtimer = 0              -- player berry_timer
local pbcount = 0              -- player-local berry_count (lifeup values)
local spstate = 0
local sptarget = 0
local spdelay = 0

-- hair (5 segments)
local hx = array(5)
local hy = array(5)

-- got_fruit (berry ids: level*4-4 + scan ordinal)
local got = array(8)

-- fruits (10/11 + the one a fly fruit drops); train via frtrain (0 = free)
local fract = array(4)
local frx = array(4, 0.0)
local fry_ = array(4, 0.0)     -- un-bobbed y_
local frdy = array(4, 0.0)     -- bobbed draw y
local frtx = array(4, 0.0)
local frty = array(4, 0.0)
local froff8 = array(4)        -- bob phase, 8.8 int (205/frame = 1 turn/40f)
-- PERF: the fruit bob was sin(froff8)*2.5 per fruit per frame — a fixed-point
-- sin + multiply each. frwob is that waveform precomputed once (32 entries,
-- one turn); the int phase wraps harmlessly (32768/256=128, 128%32==0).
local frwob = array(32, 0.0)
local frspr = array(4)
local frgold = array(4)
local frid = array(4)
local frtrain = array(4)
local frr = array(4)
local trainn = 0
local ttx = array(6, 0.0)      -- train slot targets (slot 1 = player)
local tty = array(6, 0.0)

-- fly fruit (one per level in the base cart)
local flyact = 0
local flx = 0
local fly = 0.0
local flstart = 0
local flstep = 0.0
local flspdy = 0.0
local flsfxd = 0
local flyid = 0

-- springs
local spgx = array(6)
local spgy = array(6)
local spgdir = array(6)        -- 0 floor, -1/1 wall
local spgdelta = array(6, 0.0)
local spgn = 0

-- fall floors
local ffx = array(8)
local ffy = array(8)
local ffstate = array(8)       -- 0 idle, 1 shaking, 2 invisible
local ffdelay = array(8, 0.0)
local ffcol = array(8)         -- collideable
local ffn = 0

-- refills
local rfx = array(2)
local rfy = array(2)
local rftimer = array(2)
local rfoff = array(2, 0.0)
local rfn = 0

-- lifeup popups
local lux = array(3, 0.0)
local luy = array(3, 0.0)
local ludur = array(3)
local luflash = array(3, 0.0)
local luval = array(3)

-- smoke (ring buffer; smspr < 0 = free)
local smfx = array(12, 0.0)
local smfy = array(12, 0.0)
local smvx = array(12, 0.0)
local smspr = array(12, -1.0)
local smidx = 0

-- clouds / particles / dead particles
local clx = array(17, 0.0)
local cly = array(17)
local clspd = array(17, 0.0)
local clw = array(17)
local clh = array(17)
local pax = array(25, 0.0)
local pay = array(25, 0.0)
local pas = array(25)
local paspd = array(25, 0.0)
local paoff = array(25, 0.0)
local pac = array(25)
local dpx = array(8, 0.0)
local dpy = array(8, 0.0)
local dpdx = array(8, 0.0)
local dpdy = array(8, 0.0)
local dpt = array(8, 0.0)

-- one-way platform tiles collected during the map pass, drawn over objects
-- one-way platforms are collected LEVEL-WIDE at load (not per frame): the
-- static map lives in the GRAM canvas (see compose_level) and the old
-- per-frame 256-cell scan is gone.
local platx = array(64)
local platy = array(64)
local plats = array(64)
local platn = 0
local composed_lvl = 0         -- which level the GRAM canvas currently holds


-- ---------------------------------------------------------------------
-- generated map data (node ports/newleste/tools/genassets.mjs)
-- ---------------------------------------------------------------------
function map_init()
  -- @gen-map-begin
  -- __map__ cols 0-63 x rows 0-15 -> m[row*64+col+1] (generated)
  m[1] = 43
  m[2] = 59
  m[3] = 41
  m[14] = 42
  m[15] = 59
  m[16] = 43
  m[65] = 59
  m[66] = 41
  m[79] = 42
  m[80] = 59
  m[129] = 41
  m[136] = 1
  m[144] = 42
  m[198] = 19
  m[199] = 33
  m[200] = 34
  m[201] = 34
  m[202] = 35
  m[203] = 18
  m[262] = 19
  m[263] = 49
  m[264] = 50
  m[265] = 50
  m[266] = 51
  m[267] = 18
  m[321] = 16
  for i = 327, 330 do m[i] = 17 end
  m[336] = 16
  m[385] = 39
  m[386] = 8
  m[399] = 8
  m[400] = 39
  m[449] = 55
  m[450] = 8
  m[457] = 11
  m[463] = 8
  m[464] = 55
  m[581] = 10
  m[588] = 12
  m[661] = 10
  for i = 708, 710 do m[i] = 23 end
  m[715] = 20
  m[716] = 21
  m[717] = 22
  m[770] = 15
  m[840] = 9
  m[841] = 9
  m[849] = 1
  for i = 897, 900 do m[i] = 34 end
  m[901] = 35
  m[902] = 23
  m[903] = 23
  m[904] = 32
  m[905] = 32
  m[906] = 23
  m[907] = 23
  m[908] = 33
  for i = 909, 912 do m[i] = 34 end
  m[913] = 35
  m[961] = 56
  for i = 962, 964 do m[i] = 37 end
  m[965] = 38
  m[972] = 36
  for i = 973, 975 do m[i] = 37 end
  m[976] = 56
  m[977] = 38
  -- __gff__ sprite flags -> fl[tile+1] (generated)
  for i = 17, 20 do fl[i] = 2 end
  for i = 21, 23 do fl[i] = 8 end
  for i = 33, 40 do fl[i] = 3 end
  for i = 41, 45 do fl[i] = 4 end
  for i = 49, 57 do fl[i] = 3 end
  for i = 58, 61 do fl[i] = 4 end
  -- @gen-map-end
end

-- ---------------------------------------------------------------------
-- map/flag helpers (the mget/fget the SDK doesn't have yet)
-- ---------------------------------------------------------------------
function mget(x, y)
  return m[y * 64 + x + 1]
end

function tile_at(x, y)
  return mget(lvl_x + x, lvl_y + y)
end

-- ---------------------------------------------------------------------
-- sfx (SILENT — the ACP audio firmware does not fit; see PORT_NOTES.md).
-- The cart's __sfx__ 9-22 were converted to a gtlua note-event player
-- (scripts/p8sfx.mjs) and wired through here, but linking gt.note pulls
-- the 4312-byte ACP firmware RODATA into the FLASH2M FIXED bank, whose
-- 16 KB already holds 13.9 KB of runtime CODE + ~1.5 KB RODATA — adding
-- the firmware overflows the fixed bank's RODATA by 3758 bytes. The SDK
-- can't bank that RODATA, so sfx ids just flow through sfx_play (a no-op)
-- and audio can be reinstated the moment the SDK banks the firmware blob.
-- ---------------------------------------------------------------------
function sfx_play(n)
  -- silent: the ACP firmware overflows the fixed bank for a game this size
end

function psfx(n)
  if (sfx_timer <= 0) sfx_play(n)
end

-- ---------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------
function appr(val, target, amount)
  return mid(val - amount, val + amount, target)
end

-- integer twin of appr() for the 8.8 player physics (int mid, no long math)
function appr8(val, target, amount)
  return mid(val - amount, val + amount, target)
end

function sign0(v)
  if (v > 0) return 1
  if (v < 0) return -1
  return 0
end

-- player box (hitbox 1,3,6,5) against a world box, current position (0/1)
function p_over(bx0, by0, bx1, by1)
  if (pmode ~= 2) return 0
  if bx1 >= px + 1 and bx0 <= px + 6 and by1 >= py + 3 and by0 <= py + 7 then
    return 1
  end
  return 0
end

function smoke_spawn(x, y)
  smidx += 1
  if (smidx > 12) smidx = 1
  smfx[smidx] = x - 1 + rnd(2)
  smfy[smidx] = y - 1 + rnd(2)
  smvx[smidx] = 0.3 + rnd(0.2)
  smspr[smidx] = 26
end

function lifeup_spawn(x, y, val)
  local slot = 1
  for i = 1, 3 do
    if (ludur[i] <= 0) slot = i
  end
  lux[slot] = x
  luy[slot] = y
  ludur[slot] = 30
  luflash[slot] = 0
  luval[slot] = val
  sfx_timer = 20
  sfx_play(9)
end

-- ---------------------------------------------------------------------
-- player terrain queries (is_flag / is_solid / oob / spikes)
-- ---------------------------------------------------------------------
function p_is_flag(ox, oy, mask)
  local l = px + 1 + ox
  local r = px + 6 + ox
  local t2 = py + 3 + oy
  local b = py + 7 + oy
  local b0 = py + 7            -- one-way check uses the un-offset bottom
  local i0 = mid(0, lvl_w - 1, l \ 8)
  local i1 = mid(0, lvl_w - 1, r \ 8)
  local j0 = mid(0, lvl_h - 1, t2 \ 8)
  local j1 = mid(0, lvl_h - 1, b \ 8)
  -- PERF: i/j are clamped in-level by the mids above, so fetch tiles with a
  -- direct array read — tile_at()->mget() was two nested cc65 calls per tile,
  -- x4 tiles, in the hottest routine in the game. See docs/performance.md.
  for i = i0, i1 do
    local rowb = (lvl_y + j0) * 64 + lvl_x + i + 1
    for j = j0, j1 do
      local v = m[rowb]
      rowb += 64
      if (fl[v + 1] & mask) ~= 0 then
        if mask ~= 8 or j * 8 > b0 then
          return 1
        end
      end
    end
  end
  return 0
end

function p_is_solid(ox, oy)
  -- solid objects: fall floors (while collideable)
  for i = 1, ffn do
    if ffcol[i] == 1 then
      if ffx[i] + 7 >= px + 1 + ox and ffx[i] <= px + 6 + ox and
         ffy[i] + 7 >= py + 3 + oy and ffy[i] <= py + 7 + oy then
        return 1
      end
    end
  end
  -- PERF: one merged scan collects solid (mask 1) AND one-way (mask 8) hits
  -- in a single pass over the 2x2 tile window — this used to be up to THREE
  -- separate p_is_flag scans (~2.5k cycles each) and it runs several times a
  -- frame. The un-offset "already inside a one-way?" scan now only happens in
  -- the rare case a one-way was actually hit. See docs/performance.md.
  local l = px + 1 + ox
  local r = px + 6 + ox
  local t2 = py + 3 + oy
  local b = py + 7 + oy
  local b0 = py + 7
  local i0 = mid(0, lvl_w - 1, l \ 8)
  local i1 = mid(0, lvl_w - 1, r \ 8)
  local j0 = mid(0, lvl_h - 1, t2 \ 8)
  local j1 = mid(0, lvl_h - 1, b \ 8)
  local hit8 = 0
  local i = i0
  while i <= i1 do
    local rowb = (lvl_y + j0) * 64 + lvl_x + i + 1
    local j = j0
    while j <= j1 do
      local f = fl[m[rowb] + 1]
      rowb += 64
      if (f & 1) ~= 0 then
        return 1
      end
      if (f & 8) ~= 0 and j * 8 > b0 then hit8 = 1 end
      j += 1
    end
    i += 1
  end
  if oy > 0 and hit8 == 1 then
    if (p_is_flag(ox, 0, 8) == 0) return 1
  end
  return 0
end

-- is_solid(0,1,true): same but fall floors (unsafe_ground) don't count
function p_on_safe_ground()
  -- same merged single-scan pattern as p_is_solid (see the note there)
  local b0 = py + 7
  local i0 = mid(0, lvl_w - 1, (px + 1) \ 8)
  local i1 = mid(0, lvl_w - 1, (px + 6) \ 8)
  local j0 = mid(0, lvl_h - 1, (py + 4) \ 8)
  local j1 = mid(0, lvl_h - 1, (py + 8) \ 8)
  local hit8 = 0
  local i = i0
  while i <= i1 do
    local rowb = (lvl_y + j0) * 64 + lvl_x + i + 1
    local j = j0
    while j <= j1 do
      local f = fl[m[rowb] + 1]
      rowb += 64
      if (f & 1) ~= 0 then
        return 1
      end
      if (f & 8) ~= 0 and j * 8 > b0 then hit8 = 1 end
      j += 1
    end
    i += 1
  end
  if hit8 == 1 then
    if (p_is_flag(0, 0, 8) == 0) return 1
  end
  return 0
end

function p_oob(ox, oy)
  if (exit_left == 0 and px + 1 + ox < 0) return 1
  if (exit_right == 0 and px + 6 + ox >= lvl_pw) return 1
  if (py + 3 + oy <= -8) return 1
  return 0
end

-- is_flag(0,0,-1): spike tiles 16-19 with directional overlap rules
function p_spiked()
  local l = px + 1
  local r = px + 6
  local t2 = py + 3
  local b = py + 7
  local i0 = mid(0, lvl_w - 1, l \ 8)
  local i1 = mid(0, lvl_w - 1, r \ 8)
  local j0 = mid(0, lvl_h - 1, t2 \ 8)
  local j1 = mid(0, lvl_h - 1, b \ 8)
  for i = i0, i1 do
    local rowb = (lvl_y + j0) * 64 + lvl_x + i + 1
    for j = j0, j1 do
      local v = m[rowb]
      rowb += 64
      if v == 16 then
        if (pvy8 >= 0 and b % 8 >= 6) return 1
      elseif v == 17 then
        if (pvy8 <= 0 and t2 % 8 <= 2) return 1
      elseif v == 18 then
        if (pvx8 <= 0 and l % 8 <= 2) return 1
      elseif v == 19 then
        if (pvx8 >= 0 and r % 8 >= 6) return 1
      end
    end
  end
  return 0
end

-- ---------------------------------------------------------------------
-- player movement (the evercore move(): pixel-stepped, rem-accumulated)
-- ---------------------------------------------------------------------
function p_move(ox, oy, start)
  -- PERF: with start=0 the i=0 iteration is an "already embedded in solid?"
  -- check at zero offset — and when BOTH axes are at rest (standing still,
  -- the most common frame) the two axes were doing that identical full
  -- collision scan twice. idle_hit computes it once and shares it.
  local idle_hit = -1
  prx8 += ox
  local amt = (prx8 + 128) \ 256
  prx8 -= amt * 256
  local step = sign0(amt)
  if amt == 0 and start == 0 then
    idle_hit = 0
    if (p_is_solid(0, 0) == 1 or p_oob(0, 0) == 1) idle_hit = 1
    if idle_hit == 1 then
      pvx8 = 0
      prx8 = 0
    end
  else
    for i = start, abs(amt) do
      if p_is_solid(step, 0) == 1 or p_oob(step, 0) == 1 then
        pvx8 = 0
        prx8 = 0
        break
      else
        px += step
      end
    end
  end

  pry8 += oy
  amt = (pry8 + 128) \ 256
  pry8 -= amt * 256
  step = sign0(amt)
  if amt == 0 and start == 0 then
    if idle_hit < 0 then
      idle_hit = 0
      if (p_is_solid(0, 0) == 1 or p_oob(0, 0) == 1) idle_hit = 1
    end
    if idle_hit == 1 then
      pvy8 = 0
      pry8 = 0
    end
  else
    for i = start, abs(amt) do
      if p_is_solid(0, step) == 1 or p_oob(0, step) == 1 then
        pvy8 = 0
        pry8 = 0
        break
      else
        py += step
      end
    end
  end
end

-- ---------------------------------------------------------------------
-- death
-- ---------------------------------------------------------------------
function kill_player()
  sfx_timer = 12
  shake = 9
  sfx_play(17)
  deaths += 1
  pmode = 0
  local dir = 0.0
  for i = 1, 8 do
    dpx[i] = px + 4
    dpy[i] = py + 4
    dpt[i] = 2
    dpdx[i] = sin(dir) * 3
    dpdy[i] = cos(dir) * 3
    dir += 0.125
  end
  -- a golden in the train forces a full restart; unbanked berries respawn
  for i = 1, 4 do
    if fract[i] == 1 and frtrain[i] > 0 then
      if (frgold[i] == 1) full_restart = 1
      fract[i] = 0
    end
    frtrain[i] = 0
  end
  trainn = 0
  delay_restart = 15
  tstate = 0
end

-- ---------------------------------------------------------------------
-- hair
-- ---------------------------------------------------------------------
function update_hair()
  local lx = px + 1
  if (pflip == 1) lx = px + 6
  local ly = py + 3
  if (pmode == 2 and btn(3)) ly = py + 4
  -- PERF: hair positions in whole pixels with integer smoothing. The original
  -- fixed-point (delta)/1.5 smoothing cost 10 fixed divides (~12k cycles
  -- each!) per frame; even as table-multiplies it was ~13k cycles total — for
  -- 1-2px dots whose position gets floored to a pixel anyway. Integer 5/8
  -- smoothing ((d*5+4)\8 — the +4 rounds so the last pixel converges) is
  -- visually identical hair lag and near-free. See docs/performance.md.
  for i = 1, 5 do
    hx[i] += ((lx - hx[i]) * 5 + 4) \ 8
    hy[i] += ((ly - hy[i]) * 5 + 4) \ 8
    lx = hx[i]
    ly = hy[i]
  end
end

function draw_hair()
  local hc = 8
  if (pdjump == 0) hc = 12
  circfill(hx[1], hy[1], 2, hc)
  circfill(hx[2], hy[2], 2, hc)
  circfill(hx[3], hy[3], 1, hc)
  circfill(hx[4], hy[4], 1, hc)
  circfill(hx[5], hy[5], 1, hc)
end

-- ---------------------------------------------------------------------
-- player spawn + player
-- ---------------------------------------------------------------------
function spawn_init(x, y)
  pmode = 1
  sfx_play(15)
  pspr = 3
  pflip = 0
  sptarget = y
  px = x
  py = min(y + 48, lvl_ph)
  cam_x = mid(x, 64, lvl_pw - 64)
  cam_y = mid(y, 64, lvl_ph - 64)
  pvx8 = 0
  pvy8 = -1024
  prx8 = 0
  pry8 = 0
  spstate = 0
  spdelay = 0
  pdjump = max_djump
  for i = 1, 5 do
    hx[i] = px
    hy[i] = py
  end
  -- the fruit train follows the player between levels: re-seat it here
  for i = 1, 4 do
    if fract[i] == 1 and frtrain[i] > 0 then
      frx[i] = px
      fry_[i] = py
      frdy[i] = py
      frtx[i] = px
      frty[i] = py
      froff8[i] = 0
    end
  end
end

function player_init()
  pmode = 2
  pspr = 1
  pflip = 0
  pvx8 = 0
  pvy8 = 0
  prx8 = 0
  pry8 = 0
  pdjump = max_djump
  pgrace = 0
  pjbuf = 0
  pdash_t = 0
  pdash_eff = 0
  psproff8 = 0
  pbtimer = 0
  pbcount = 0
  pjprev = 0
  pdprev = 0
  pwasog = 0
  pphin = 0
  for i = 1, 5 do
    hx[i] = px
    hy[i] = py
  end
end

function spawn_update()
  -- move (spawn never collides)
  pry8 += pvy8
  local amt = (pry8 + 128) \ 256
  pry8 -= amt * 256
  py += amt

  if spstate == 0 then
    -- jumping up
    if py < sptarget + 16 then
      spstate = 1
      spdelay = 3
    end
  elseif spstate == 1 then
    -- falling
    pvy8 += 128
    if pvy8 > 0 then
      if spdelay > 0 then
        -- stall at peak
        pvy8 = 0
        spdelay -= 1
      elseif py > sptarget then
        -- clamp at target y
        py = sptarget
        pvy8 = 0
        pry8 = 0
        spstate = 2
        spdelay = 5
        shake = 4
        smoke_spawn(px, py + 4)
        sfx_play(16)
      end
    end
  else
    -- landing, then hand over to the player object
    spdelay -= 1
    pspr = 6
    if spdelay < 0 then
      player_init()
    end
  end
  update_hair()
end

function next_level()
  load_level(lvl_id + 1)
end

function p_update()
  -- horizontal input (right wins when both held, like btn()%4 lookup)
  local h_input = 0
  if (btn(0)) h_input = -1
  if (btn(1)) h_input = 1

  -- spike collision / bottom death
  if p_spiked() == 1 or (py > lvl_ph and exit_bottom == 0) then
    kill_player()
    return
  end

  local on_ground = p_is_solid(0, 1)

  -- <fruitrain>: bank the train while standing on safe ground
  if p_on_safe_ground() == 1 then
    pbtimer += 1
  else
    pbtimer = 0
    pbcount = 0
  end
  if pbtimer > 5 and trainn > 0 then
    -- bank the head of the train (goldens never bank)
    for i = 1, 4 do
      if fract[i] == 1 and frtrain[i] == 1 and frgold[i] == 0 then
        pbcount += 1
        berry_count += 1
        pbtimer = -5
        got[frid[i]] = 1
        lifeup_spawn(frx[i], frdy[i], pbcount)
        fract[i] = 0
        frtrain[i] = 0
        trainn -= 1
        for k = 1, 4 do
          if (fract[k] == 1 and frtrain[k] > 1) frtrain[k] -= 1
        end
        break
      end
    end
  end
  -- </fruitrain>

  -- landing smoke
  if (on_ground == 1 and pwasog == 0) smoke_spawn(px, py + 4)

  -- jump/dash edge detection (manual, preserving the jump buffer)
  local jump = 0
  local dash = 0
  if (btn(4) and pjprev == 0) jump = 1
  if (btn(5) and pdprev == 0) dash = 1
  pjprev = 0
  pdprev = 0
  if (btn(4)) pjprev = 1
  if (btn(5)) pdprev = 1

  -- jump buffer
  if (jump == 1) pjbuf = 5
  pjbuf = max(pjbuf - 1)

  -- grace frames and dash restoration
  if on_ground == 1 then
    pgrace = 7
    if pdjump < max_djump then
      psfx(22)
      pdjump = max_djump
    end
  end
  pgrace = max(pgrace - 1)

  pdash_eff -= 1

  if pdash_t > 0 then
    -- dash startup: accelerate toward the dash target speed
    smoke_spawn(px, py)
    pdash_t -= 1
    pvx8 = appr8(pvx8, pdtx8, pdax8)
    pvy8 = appr8(pvy8, pdty8, pday8)
  else
    -- x movement
    local accel8 = 102                     -- 0.4
    if (on_ground == 1) accel8 = 154       -- 0.6
    if abs(pvx8) <= 256 then
      pvx8 = appr8(pvx8, h_input * 256, accel8)
    else
      pvx8 = appr8(pvx8, sign0(pvx8) * 256, 38)   -- 0.15
    end

    -- facing
    if pvx8 ~= 0 then
      pflip = 0
      if (pvx8 < 0) pflip = 1
    end

    -- y movement: wall slide caps fall speed
    local maxfall8 = 512          -- 2.0
    if h_input ~= 0 and p_is_solid(h_input, 0) == 1 then
      maxfall8 = 102              -- wall slide, 0.4
      if (rnd(1) < 0.2) smoke_spawn(px + h_input * 6, py)
    end

    -- gravity
    if on_ground == 0 then
      local gacc8 = 27                    -- 0.105
      if (abs(pvy8) > 38) gacc8 = 54      -- 0.21 above 0.15
      pvy8 = appr8(pvy8, maxfall8, gacc8)
    end

    -- jump
    if pjbuf > 0 then
      if pgrace > 0 then
        -- normal jump
        psfx(18)
        pjbuf = 0
        pgrace = 0
        pvy8 = -512
        smoke_spawn(px, py + 4)
      else
        -- wall jump
        local wall_dir = 0
        if (p_is_solid(-3, 0) == 1) wall_dir = -1
        if (wall_dir == 0 and p_is_solid(3, 0) == 1) wall_dir = 1
        if wall_dir ~= 0 then
          psfx(19)
          pjbuf = 0
          pvx8 = wall_dir * -512
          pvy8 = -512
          smoke_spawn(px + wall_dir * 6, py)
        end
      end
    end

    -- dash
    if dash == 1 then
      if pdjump > 0 then
        smoke_spawn(px, py)
        pdjump -= 1
        pdash_t = 4
        has_dashed = 1
        pdash_eff = 10
        local v_input = 0
        if (btn(2)) v_input = -1
        if (v_input == 0 and btn(3)) v_input = 1
        local dspd8 = 1280                  -- 5.0
        if (h_input ~= 0 and v_input ~= 0) dspd8 = 905  -- 5/sqrt(2)
        if h_input ~= 0 then
          pvx8 = h_input * dspd8
        elseif v_input ~= 0 then
          pvx8 = 0
        else
          pvx8 = 256
          if (pflip == 1) pvx8 = -256
        end
        pvy8 = v_input * dspd8
        psfx(20)
        freeze = 2
        shake = 5
        -- dash target speeds and accels
        pdtx8 = 512 * sign0(pvx8)
        pdty8 = 0
        if (v_input == -1) pdty8 = -384
        if (v_input == 1) pdty8 = 512
        pdax8 = 272
        if (v_input == 0) pdax8 = 384
        pday8 = 272
        if (pvx8 == 0) pday8 = 384
        -- emulate soft dashes (reversing off a wall)
        if (pphin == -h_input and h_input ~= 0 and p_oob(pphin, 0) == 1) pvx8 = 0
      else
        -- failed dash
        psfx(21)
        smoke_spawn(px, py)
      end
    end
  end

  -- animation
  psproff8 += 64                        -- 0.25
  local s = 1
  if on_ground == 1 then
    if btn(3) then
      s = 6                       -- crouch
    elseif btn(2) then
      s = 7                       -- look up
    elseif pvx8 ~= 0 and h_input ~= 0 then
      s = 1 + (psproff8 \ 256) % 4    -- walk
    end
  else
    s = 3                         -- mid air
    if (h_input ~= 0 and p_is_solid(h_input, 0) == 1) s = 5 -- wall slide
  end
  pspr = s

  update_hair()

  -- exit level
  local exiting = 0
  if (exit_right == 1 and px + 1 >= lvl_pw) exiting = 1
  if (exit_top == 1 and py < -4) exiting = 1
  if (exit_left == 1 and px + 6 < 0) exiting = 1
  if (exit_bottom == 1 and py + 3 >= lvl_ph) exiting = 1
  if exiting == 1 and lvl_id < 2 then
    next_level()
    return
  end

  pwasog = on_ground
  pphin = h_input
end

function draw_player()
  draw_hair()
  local cell = pspr
  if pdjump == 0 then
    cell = pspr + 71                 -- blue-hair recolor
    if (pflip == 1) cell = pspr + 79 -- blue, mirrored
  else
    if (pflip == 1) cell = pspr + 63 -- mirrored
  end
  spr(cell, px, py)
end

-- ---------------------------------------------------------------------
-- entities
-- ---------------------------------------------------------------------
function update_fall_floors()
  for i = 1, ffn do
    if ffdelay[i] > 0 then
      -- idling (0.2/frame keeps the vanilla frame counts)
      ffdelay[i] -= 0.2
    elseif ffstate[i] == 0 then
      -- check the player standing on / hugging the sides.
      -- PERF: a broad-phase box (the union of the three test rects, inline
      -- int compares) skips the three p_over calls when the player is nowhere
      -- near — which is nearly every floor, nearly every frame.
      local hit = 0
      if ffx[i] - 1 <= px + 6 and px + 1 <= ffx[i] + 8 and
         ffy[i] - 1 <= py + 7 and py + 3 <= ffy[i] + 7 then
        if (p_over(ffx[i] - 1, ffy[i], ffx[i] + 6, ffy[i] + 7) == 1) hit = 1
        if (p_over(ffx[i], ffy[i] - 1, ffx[i] + 7, ffy[i] + 6) == 1) hit = 1
        if (p_over(ffx[i] + 1, ffy[i], ffx[i] + 8, ffy[i] + 7) == 1) hit = 1
      end
      if hit == 1 then
        psfx(13)
        ffstate[i] = 1
        ffdelay[i] = 2.79
        smoke_spawn(ffx[i], ffy[i])
      end
    elseif ffstate[i] == 1 then
      -- done shaking: vanish
      ffstate[i] = 2
      ffdelay[i] = 11.79
      ffcol[i] = 0
    else
      -- invisible, waiting to reset (only when the player is clear)
      if p_over(ffx[i], ffy[i], ffx[i] + 7, ffy[i] + 7) == 0 then
        psfx(12)
        ffstate[i] = 0
        ffcol[i] = 1
        smoke_spawn(ffx[i], ffy[i])
      end
    end
  end
end

function update_springs()
  for i = 1, spgn do
    -- PERF: the compression delta decays to exactly 0 (16.16 truncation), so
    -- skip the fixed multiply once it gets there — it ran every spring, every
    -- frame, forever. The overlap test is p_over inlined (int compares).
    if (spgdelta[i] ~= 0) spgdelta[i] *= 0.75
    if pmode == 2 and spgx[i] <= px + 6 and px + 1 <= spgx[i] + 7 and
       spgy[i] <= py + 7 and py + 3 <= spgy[i] + 7 then
      if spgdir[i] == 0 then
        p_move(0, spgy[i] - py - 4, 1)
        pvx8 = pvx8 \ 5                -- *0.2
        pvy8 = -768
      else
        p_move(spgx[i] + spgdir[i] * 4 - px, 0, 1)
        pvx8 = spgdir[i] * 768
        pvy8 = -384
      end
      pdash_t = 0
      pdash_eff = 0
      spgdelta[i] = 4
      pdjump = max_djump
    end
  end
end

function update_refills()
  for i = 1, rfn do
    if rftimer[i] > 0 then
      rftimer[i] -= 1
      if rftimer[i] == 0 then
        psfx(12)
        smoke_spawn(rfx[i], rfy[i])
      end
    else
      rfoff[i] += 0.02
      if pdjump < max_djump and
         p_over(rfx[i] - 1, rfy[i] - 1, rfx[i] + 8, rfy[i] + 8) == 1 then
        psfx(11)
        smoke_spawn(rfx[i], rfy[i])
        pdjump = max_djump
        rftimer[i] = 60
      end
    end
  end
end

function fruit_join_train(i)
  pbtimer = 0
  trainn += 1
  frtrain[i] = trainn
  frr[i] = 8
  if (trainn == 1) frr[i] = 12
end

function update_flyfruit()
  if flyact == 0 then
    return
  end
  if has_dashed == 1 then
    -- fly away
    flsfxd -= 1
    if flsfxd == 0 then
      sfx_timer = 20
      sfx_play(10)
    end
    flspdy = appr(flspdy, -3.5, 0.25)
    fly += flspdy
    if fly < -16 then
      flyact = 0
      return
    end
  else
    -- wait, bobbing
    flstep += 0.05
    flspdy = sin(flstep) * 0.5
    fly += flspdy
  end
  -- collect
  if p_over(flx, flr(fly), flx + 7, flr(fly) + 7) == 1 then
    smoke_spawn(flx - 6, flr(fly))
    smoke_spawn(flx + 6, flr(fly))
    -- drop a regular fruit straight into the train
    for i = 1, 4 do
      if fract[i] == 0 then
        fract[i] = 1
        frx[i] = flx
        fry_[i] = fly
        frdy[i] = fly
        frtx[i] = flx
        frty[i] = fly
        froff8[i] = 0
        frspr[i] = 10
        frgold[i] = 0
        frid[i] = flyid
        fruit_join_train(i)
        break
      end
    end
    flyact = 0
  end
end

function update_fruits()
  -- train slot targets: slot 1 is the player (or spawn)
  ttx[1] = px
  tty[1] = py
  -- train members chase the member ahead of them
  for k = 1, trainn do
    for i = 1, 4 do
      if fract[i] == 1 and frtrain[i] == k then
        frtx[i] += 0.2 * (ttx[k] - frtx[i])
        frty[i] += 0.2 * (tty[k] - frty[i])
        local dtx = mid(-100, 100, frx[i] - frtx[i])
        local dty = mid(-100, 100, fry_[i] - frty[i])
        local a = atan2(dtx, dty)
        local rr = frr[i]
        local k2 = 0.1
        if (dtx * dtx + dty * dty > rr * rr) k2 = 0.2
        frx[i] += k2 * (rr * cos(a) - dtx)
        fry_[i] += k2 * (rr * sin(a) - dty)
        froff8[i] += 205
        frdy[i] = fry_[i] + frwob[((froff8[i] \ 256) & 31) + 1]
        ttx[k + 1] = frx[i]
        tty[k + 1] = frdy[i]
      end
    end
  end
  -- free fruits bob in place and wait for the player
  for i = 1, 4 do
    if fract[i] == 1 and frtrain[i] == 0 then
      froff8[i] += 205
      frdy[i] = fry_[i] + frwob[((froff8[i] \ 256) & 31) + 1]
      local fx = flr(frx[i])
      local fy = flr(frdy[i])
      if p_over(fx, fy, fx + 7, fy + 7) == 1 then
        fruit_join_train(i)
      end
    end
  end
end

function update_lifeups()
  for i = 1, 3 do
    if ludur[i] > 0 then
      ludur[i] -= 1
      luy[i] -= 0.25
      luflash[i] += 0.5
    end
  end
end

function update_smoke()
  for i = 1, 12 do
    if smspr[i] >= 0 then
      smfx[i] += smvx[i]
      smfy[i] -= 0.1
      smspr[i] += 0.2
      if (smspr[i] >= 29) smspr[i] = -1
    end
  end
end

-- ---------------------------------------------------------------------
-- camera
-- ---------------------------------------------------------------------
function move_camera()
  cam_spdx = 0.1 * (4 + px - cam_x)
  cam_spdy = 0.1 * (4 + py - cam_y)
  cam_x += cam_spdx
  cam_y += cam_spdy
  local cx = mid(cam_x, 64, lvl_pw - 64)
  local cy = mid(cam_y, 64, lvl_ph - 64)
  if cam_x ~= cx then
    cam_spdx = 0
    cam_x = cx
  end
  if cam_y ~= cy then
    cam_spdy = 0
    cam_y = cy
  end
end

-- ---------------------------------------------------------------------
-- levels
-- ---------------------------------------------------------------------
-- PERF: the level map is STATIC, so it composes into the 256x256 GRAM canvas
-- once per level as 128-tall strips (strip s = world x [s*256,(s+1)*256) at
-- canvas rows [s*128, s*128+128)) — level 2 is 384px wide, 1.5 strips. The
-- per-frame map draw is then FOUR gt.gspr blits instead of ~80 tile blits
-- (colorkey keeps empty cells transparent over the clouds, same as spr did).
-- Death respawns reuse the canvas (composed_lvl cache) so there is no reload
-- hitch; only a real level change pays the clear+stamp. One-way platforms
-- (f&8, drawn OVER entities) are collected level-wide here instead of being
-- re-scanned every frame.
function compose_level()
  local fresh = 0
  if composed_lvl ~= lvl_id then
    fresh = 1
    gt.bg_clear()
    composed_lvl = lvl_id
  end
  platn = 0
  local j = 0
  while j < lvl_h do
    local base = (lvl_y + j) * 64 + lvl_x + 1
    local i = 0
    while i < lvl_w do
      local v = m[base + i]
      if v > 0 then
        local f = fl[v + 1]
        if (f & 6) ~= 0 then
          if (fresh == 1) gt.bg_tile(v, (i & 31) * 8, (i \ 32) * 128 + j * 8)
        elseif (f & 8) ~= 0 then
          if platn < 64 then
            platn += 1
            platx[platn] = i * 8
            platy[platn] = j * 8
            plats[platn] = v
          end
        end
      end
      i += 1
    end
    j += 1
  end
end

function load_level(id)
  -- clear level-owned objects; train fruits ride along to the next spawn
  ffn = 0
  spgn = 0
  rfn = 0
  flyact = 0
  platn = 0
  for i = 1, 3 do ludur[i] = 0 end
  for i = 1, 12 do smspr[i] = -1 end
  for i = 1, 4 do
    if (frtrain[i] == 0) fract[i] = 0
  end

  ui_timer = 5
  cam_spdx = 0
  cam_spdy = 0
  has_dashed = 0

  lvl_id = id
  -- level table: "x,y,w,h,exits" in 16-tile units (both exit at the top)
  if id == 1 then
    lvl_x = 0
    lvl_w = 16
  else
    lvl_x = 16
    lvl_w = 48
  end
  lvl_y = 0
  lvl_h = 16
  lvl_pw = lvl_w * 8
  lvl_ph = lvl_h * 8
  exit_top = 1
  exit_right = 0
  exit_bottom = 0
  exit_left = 0

  pmode = 0
  local bid = lvl_id * 4 - 4    -- berry-id base for this level
  local ord = 0                 -- berry scan ordinal (stable across reloads)

  -- entities (scan order matches the cart: column-major)
  for tx = 0, lvl_w - 1 do
    for ty = 0, lvl_h - 1 do
      local tile = tile_at(tx, ty)
      local x = tx * 8
      local y = ty * 8
      if tile == 1 then
        spawn_init(x, y)
      elseif tile == 8 or tile == 9 then
        spgn += 1
        spgx[spgn] = x
        spgy[spgn] = y
        spgdelta[spgn] = 0
        if tile == 9 then
          spgdir[spgn] = 0
        else
          -- wall spring: face away from the solid side
          local lx = tx - 1
          if (lx < 0) lx = 0
          spgdir[spgn] = -1
          if ((fl[tile_at(lx, ty) + 1] & 1) ~= 0) spgdir[spgn] = 1
        end
      elseif tile == 10 or tile == 11 then
        ord += 1
        local ok = 1
        if (got[bid + ord] == 1) ok = 0
        if (tile == 11 and deaths > 0) ok = 0
        if ok == 1 then
          for i = 1, 4 do
            if fract[i] == 0 then
              fract[i] = 1
              frx[i] = x
              fry_[i] = y
              frdy[i] = y
              frtx[i] = x
              frty[i] = y
              froff8[i] = 0
              frspr[i] = tile
              frgold[i] = 0
              if (tile == 11) frgold[i] = 1
              frid[i] = bid + ord
              frtrain[i] = 0
              frr[i] = 8
              break
            end
          end
        end
      elseif tile == 12 then
        ord += 1
        if got[bid + ord] == 0 then
          flyact = 1
          flx = x
          fly = y
          flstart = y
          flstep = 0.5
          flspdy = 0
          flsfxd = 8
          flyid = bid + ord
        end
      elseif tile == 15 then
        rfn += 1
        rfx[rfn] = x
        rfy[rfn] = y
        rftimer[rfn] = 0
        rfoff[rfn] = rnd(1)
      elseif tile == 23 then
        ffn += 1
        ffx[ffn] = x
        ffy[ffn] = y
        ffstate[ffn] = 0
        ffdelay[ffn] = 0
        ffcol[ffn] = 1
      end
    end
  end
  compose_level()
end

-- ---------------------------------------------------------------------
-- boot / restart
-- ---------------------------------------------------------------------
function game_init()
  max_djump = 1
  deaths = 0
  frames = 0
  seconds = 0
  minutes = 0
  time_ticking = 1
  berry_count = 0
  full_restart = 0
  trainn = 0
  tstate = -1
  tpos = -20
  for i = 1, 8 do got[i] = 0 end
  for i = 1, 4 do
    fract[i] = 0
    frtrain[i] = 0
  end
  for i = 1, 8 do dpt[i] = 0 end
  for i = 1, 12 do smspr[i] = -1 end
  for i = 1, 17 do
    clx[i] = rnd(128)
    cly[i] = flr(rnd(128))
    clspd[i] = 1 + rnd(4)
    local w = 32 + flr(rnd(32))
    clw[i] = w
    clh[i] = flr(16 - w * 0.1875)
  end
  for i = 1, 25 do
    pax[i] = rnd(128)
    pay[i] = rnd(128)
    pas[i] = flr(rnd(1.25))
    paspd[i] = 0.25 + rnd(5)
    paoff[i] = rnd(1)
    pac[i] = 6 + flr(rnd(2))
  end
  load_level(1)
end

function _init()
  local i = 1
  while i <= 32 do
    frwob[i] = sin((i - 1) / 32) * 2.5
    i += 1
  end
  map_init()
  game_init()
end

-- ---------------------------------------------------------------------
-- update
-- ---------------------------------------------------------------------
function _update()
  cls()                          -- clear kicks off while logic runs

  frames += 1
  if time_ticking == 1 then
    seconds += frames \ 30
    minutes += seconds \ 60
    seconds %= 60
  end
  frames %= 30

  sfx_timer = max(sfx_timer - 1)

  -- freeze: state holds still, the same frame is redrawn
  if freeze > 0 then
    freeze -= 1
    return
  end

  -- screenshake toggle (player 2 ⬆️)
  if (btnp(2, 1)) screenshake = 1 - screenshake

  -- restart (soon)
  if delay_restart > 0 then
    cam_spdx = 0
    cam_spdy = 0
    delay_restart -= 1
    if delay_restart == 0 then
      if full_restart == 1 then
        full_restart = 0
        game_init()
      else
        load_level(lvl_id)
      end
    end
  end

  -- objects update in the cart's insertion order: level entities, then
  -- the player (who was appended last by the spawn)
  update_fall_floors()
  update_springs()
  update_refills()
  update_flyfruit()
  update_fruits()
  update_lifeups()
  update_smoke()

  if pmode == 1 then
    spawn_update()
  elseif pmode == 2 then
    p_move(pvx8, pvy8, 0)
    p_update()
  end

  if (pmode > 0) move_camera()
end

-- ---------------------------------------------------------------------
-- draw
-- ---------------------------------------------------------------------
function draw_time(x, y)
  rectfill(x, y, x + 32, y + 6, 0)
  local mm = minutes % 60
  print(minutes \ 60, x + 1, y + 1, 7)
  print(":", x + 5, y + 1, 7)
  print(mm \ 10, x + 9, y + 1, 7)
  print(mm % 10, x + 13, y + 1, 7)
  print(":", x + 17, y + 1, 7)
  print(seconds \ 10, x + 21, y + 1, 7)
  print(seconds % 10, x + 25, y + 1, 7)
end

function draw_lifeup(i)
  local v = min(luval[i], 6)
  local x = flr(lux[i]) - 4
  local y = flr(luy[i]) - 4
  local c = 7 + flr(luflash[i] % 2)
  if v <= 1 then
    print("1000", x, y, c)
  elseif v == 2 then
    print("2000", x, y, c)
  elseif v == 3 then
    print("3000", x, y, c)
  elseif v == 4 then
    print("4000", x, y, c)
  elseif v == 5 then
    print("5000", x, y, c)
  else
    print("1up", x, y, c)
  end
end

function draw_wipe()
  if tstate < 0 then
    return
  end
  -- the cart's po1tri wipe: a diagonal edge (20px lean) sweeping right
  local xd = tpos + 20.0
  if tstate == 0 then
    for y = 0, 127 do
      if (xd >= 0) rectfill(0, y, flr(xd), y, 0)
      xd -= 0.15748
    end
    if tpos > 148 then
      tstate = 1
      tpos = -20
    end
  else
    for y = 0, 127 do
      if (xd <= 127) rectfill(flr(xd), y, 127, y, 0)
      xd -= 0.15748
    end
    if tpos > 148 then
      tstate = -1
      tpos = -20
    end
  end
  tpos += 14
end

function _draw()
  if freeze > 0 then
    return
  end

  -- camera position (+ shake)
  draw_x = flr(cam_x + 0.5) - 64
  draw_y = flr(cam_y + 0.5) - 64
  if shake > 0 then
    shake -= 1
    if screenshake == 1 then
      draw_x += flr(-2 + rnd(5))
      draw_y += flr(-2 + rnd(5))
    end
  end

  -- bg clouds (screen space)
  camera()
  for i = 1, 17 do
    clx[i] += clspd[i] - cam_spdx
    local x = flr(clx[i])
    rectfill(x, cly[i], x + clw[i], cly[i] + clh[i], 1)
    if clx[i] > 128 then
      clx[i] = -clw[i]
      cly[i] = flr(rnd(120))
    end
  end

  camera(draw_x, draw_y)

  -- map: blit the visible window from the pre-composed GRAM canvas (see
  -- compose_level). Two x-pieces (the 256px canvas strip boundary) x two
  -- 64-tall halves (the blitter's W/H are 7-bit): 4 blits total, colorkey-
  -- transparent over the clouds exactly like the old per-tile spr() pass.
  local coff = draw_x & 255
  local crow = (draw_x \ 256) * 128 + draw_y
  local w0 = 256 - coff
  if (w0 > 127) w0 = 127
  gt.gspr(coff, crow, w0, 64, draw_x, draw_y)
  gt.gspr(coff, crow + 64, w0, 64, draw_x, draw_y + 64)
  local wx1 = draw_x + w0
  local coff1 = wx1 & 255
  local crow1 = (wx1 \ 256) * 128 + draw_y
  gt.gspr(coff1, crow1, 128 - w0, 64, wx1, draw_y)
  gt.gspr(coff1, crow1 + 64, 128 - w0, 64, wx1, draw_y + 64)

  -- layer 1: level entities
  for i = 1, ffn do
    if ffstate[i] == 0 then
      spr(23, ffx[i], ffy[i])
    elseif ffstate[i] == 1 then
      spr(flr(25.8 - ffdelay[i]), ffx[i], ffy[i])
    end
  end
  for i = 1, spgn do
    local d = flr(spgdelta[i])
    if spgdir[i] == 0 then
      local cell = 9
      if (d > 0) cell = 91 + min(d, 4)
      spr(cell, spgx[i], spgy[i])
    else
      -- wall spring: mirrored cell for dir==1; squash approximated by a
      -- 1px lean toward the wall (no partial-width blits on the blitter)
      local cell = 8
      if (spgdir[i] == 1) cell = 91
      local x = spgx[i]
      if (spgdir[i] == -1 and d > 0) x += 1
      spr(cell, x, spgy[i])
    end
  end
  for i = 1, rfn do
    if rftimer[i] == 0 then
      spr(15, rfx[i], rfy[i] + flr(sin(rfoff[i]) + 0.5))
    else
      local x = rfx[i]
      local y = rfy[i]
      line(x, y + 4, x + 3, y + 7, 7)
      line(x + 4, y + 7, x + 7, y + 4, 7)
      line(x + 7, y + 3, x + 4, y, 7)
      line(x + 3, y, x, y + 3, 7)
    end
  end
  for i = 1, 4 do
    if fract[i] == 1 then
      spr(frspr[i], flr(frx[i]), flr(frdy[i]))
    end
  end
  if flyact == 1 then
    local fy = flr(fly)
    spr(10, flx, fy)
    local wing = 13
    if (fly > flstart) wing = 14
    if (has_dashed == 1 or sin(flstep) >= 0) wing = 12
    spr(wing + 76, flx - 6, fy - 2)   -- mirrored copy (cells 88-90)
    spr(wing, flx + 6, fy - 2)
  end
  for i = 1, 3 do
    if (ludur[i] > 0) draw_lifeup(i)
  end

  -- layer 2: player / spawn
  if (pmode > 0) draw_player()

  -- layer 3: smoke
  for i = 1, 12 do
    if smspr[i] >= 0 then
      spr(flr(smspr[i]), flr(smfx[i]), flr(smfy[i]))
    end
  end

  -- one-way platforms draw over everything, like the cart
  for i = 1, platn do
    spr(plats[i], platx[i], platy[i])
  end

  -- snow particles (screen space)
  camera()
  for i = 1, 25 do
    pax[i] += paspd[i] - cam_spdx
    pay[i] += sin(paoff[i]) - cam_spdy
    pay[i] %= 128
    paoff[i] += min(0.05, paspd[i] / 32)
    local x = flr(pax[i])
    local y = flr(pay[i])
    rectfill(x, y, x + pas[i], y + pas[i], pac[i])
    if pax[i] > 132 then
      pax[i] = -4
      pay[i] = rnd(128)
    elseif pax[i] < -4 then
      pax[i] = 128
      pay[i] = rnd(128)
    end
  end

  -- dead particles (world space)
  camera(draw_x, draw_y)
  for i = 1, 8 do
    if dpt[i] > 0 then
      dpx[i] += dpdx[i]
      dpy[i] += dpdy[i]
      dpt[i] -= 0.2
      local t2 = dpt[i]
      rectfill(flr(dpx[i] - t2), flr(dpy[i] - t2),
               flr(dpx[i] + t2), flr(dpy[i] + t2), 14 + flr(5 * t2 % 2))
    end
  end

  -- level-start timer HUD
  camera()
  if ui_timer >= -30 then
    if (ui_timer < 0) draw_time(4, 4)
    ui_timer -= 1
  end

  -- transition wipe
  draw_wipe()
end
