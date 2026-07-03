-- >>>>>> src/game.lua <<<<<<
-- just one boss — gametank port
-- Hand-translated from "Just One Boss" by bridgs (ayla nonsense)
-- (lexaloffle.com/bbs/?tid=30767), original licensed CC-BY-NC-SA 4.0.
-- This adaptation (real game logic + the real sprite sheet) is released
-- under the same license: CC-BY-NC-SA 4.0 — see LICENSE in this
-- directory. This cart ships the largest slice that fits the 3-bank
-- FLASH2M budget: title + a two-phase card-dodging boss fight. Every
-- divergence from the original cart (extra attacks, phases 3-4, sound,
-- ...) is listed in PORT_NOTES.md.
--
-- d-pad: hop tile to tile. Step on the sparkling tiles to fill the
-- boss bar; dodge the boss's thrown cards. ➡️ advances menus
-- (🅾️/GT A works too).
--
-- Build:  node ports/just-one-boss/tools/mkgfx.mjs
--         node ports/just-one-boss/tools/mkmusic.mjs
--         node ports/just-one-boss/tools/assemble.mjs
--         node bin/gtlua.js build ports/just-one-boss/main.lua \
--           --sheet ports/just-one-boss/sheet.bin
--
-- Architecture note: the original is built on closures, per-entity
-- method tables and a promise/timeline library. gtlua has none of
-- those (by design), so this port re-expresses every promise chain as
-- flat (action, step, wait) state machines: one rotation machine per
-- mirror, one sub-action machine per mirror, one machine per hand,
-- plus standalone machines for the intro/victory/death cinematics.
-- Frame counts and easings are copied from the cart, so the fight's
-- timing matches the original at 30 fps.

-- ======================================================================
-- constants
-- ======================================================================

local E_LIN = 0
local E_IN = 1
local E_OUT = 2
local E_OUTIN = 3

-- actor indices (parallel arrays)
local BB = 1   -- boss (magic mirror)
local LH = 2
local RH = 3
local GB = 4   -- boss reflection (green mirror)
local GLH = 5
local GRH = 6

-- rotation-machine actions (index 1 = boss, 2 = green mirror)
local R_NONE = 0
local R_P1 = 1
local R_P23 = 2
local R_P4 = 3
local R_REEL = 4
local R_INTRO = 5
local R_CHG1 = 6
local R_CHG2 = 7
local R_CHG3 = 8
-- green-mirror schedule actions
local R_GCONJ = 20
local R_GCARDS = 21
local R_GLASERS = 22
local R_GCOINS = 23

-- sub-action machine
local S_NONE = 0
local S_READY = 1
local S_CONJ = 2
local S_LASERS = 3
local S_COINS = 4
local S_CARDS = 5
local S_CARDS_L = 6
local S_CARDS_R = 7
local S_DESPAWN = 8
local S_REEL = 9
local S_POUND = 10
local S_CAST = 11

-- hand machine
local H_NONE = 0
local H_CARDS = 1
local H_POUND = 2
local H_TEMPLE = 3
local H_FLOURISH = 4
local H_CASTR = 5

-- ======================================================================
-- global state
-- ======================================================================

local scene_frame = 0
local freeze_frames = 0
local shake_frames = 0
local is_paused = 0
local timer_seconds = 0
local rainbow_color = 8    -- p8 colour
local rainbow_idx = 0      -- 0..5 (for baked tile shimmer)

local score = 0
local score_mult = 0
local boss_phase = 0
local best_score = 0
local best_time = 0
local new_best_score = 0
local new_best_time = 0

local conjure_counter = 1
local game_on = 0          -- gameplay entities exist

-- player -------------------------------------------------------------
local palive = 0
local px = 45
local py = 20
local pvx = 0
local pvy = 0
local pfacing = 0
local pstep_dir = 4        -- 4 = none
local pnext_dir = 4
local pstep_frames = 0
local pteeter = 0
local pbump = 0            -- original default_counter (bump anim)
local pstun = 0
local pinvinc = 0
local pprev_col = 0
local pprev_row = 0
local pfa = 0              -- frames alive (teeter flash)

-- player reflection --------------------------------------------------
local ref_on = 0
local rprev_col = 0
local rprev_row = 0

-- player health UI (a sliding entity in the original) -----------------
local ph_hearts = 4
local ph_x = 63.0
local ph_y = 122
local ph_anim = 0          -- 0 none, 1 lose, 2 gain
local ph_dc = 0
local ph_vis = 0
local ph_slide = 0         -- -1/1 sliding off, 0 none
local ph_sf = 0            -- slide frame
local ph_sx = 0.0          -- slide origin
local ph_move = 0          -- death drift to centre
local ph_mf = 0

-- boss health bar ------------------------------------------------------
local bh_health = 0
local bh_vis = 0
local bh_dc = 0            -- drain counter after a phase fills the bar
local bh_rainbow = 0

-- boss actors ----------------------------------------------------------
local ax = array(6, 0.0)
local ay = array(6, 0.0)
local adox = array(6, 0.0)  -- idle bob draw offsets
local adoy = array(6, 0.0)
local aim = array(6, 0.0)   -- idle mult
local aidle = array(6)
local avis = array(6)
local apose = array(6)
-- movement (cubic bezier + easing)
local mvon = array(6)
local mvf = array(6)
local mvdur = array(6)
local mvez = array(6)
local mx0 = array(6, 0.0)
local my0 = array(6, 0.0)
local mx1 = array(6, 0.0)
local my1 = array(6, 0.0)
local mx2 = array(6, 0.0)
local my2 = array(6, 0.0)
local mx3 = array(6, 0.0)
local my3 = array(6, 0.0)

local boss_on = 0          -- boss entity exists
local green_on = 0         -- boss reflection exists
local bfa = 0              -- boss frames alive (idle bob phase)
local bexpr = 4
local gexpr = 1
local bhat = 0
local ghat = 1
local bdc = 0              -- laser-charge flicker counter
local gdc = 0
local bcracked = 0
local bwand_l = 0
local bwand_r = 0
local bbouq = 0
local bhome_x = 40
local bhome_y = -28
local ghome_x = 20

-- script machines: index 1 = boss, 2 = green mirror
local rA = array(2)
local rS = array(2)
local rW = array(2)
local rN = array(2)
local sA = array(2)
local sS = array(2)
local sW = array(2)
local sN = array(2)
local sCol = array(2)
local sSweep = array(2)
local sCount = array(2)
local sTgt = array(2)
local sXtra = array(2)
local sUpg = array(2)
-- hands (indexed by actor)
local hA = array(6)
local hS = array(6)
local hW = array(6)
local hRow = array(6)
local hFirst = array(6)

-- cinematic machines
local vA = 0               -- victory step (0 = off)
local vW = 0
local dA = 0               -- death step
local dW = 0
local trans_lock = 0       -- a phase transition/cinematic is running

-- start_game staging
local sg_step = 0
local sg_wait = 0
local sg_phase = 0

-- figment (game-over ghost)
local fg_on = 0
local fg_x = 0.0
local fg_y = 0.0
local fg_sx = 0.0
local fg_sy = 0.0
local fg_f = 0
local fg_mf = 0            -- move frames (to screen centre)
local fg_slide = 0
local fg_ssx = 0.0
local fg_fa = 0

-- curtains
local cur_anim = 0         -- 1 = open
local cur_dc = 0
local cur_amount = 62.0
local cur_vis = 1          -- panels drawn this frame

-- screens: 1 title, 2 credit, 3 victory, 4 gameover
local scr_on = array(4)
local scr_x = array(4, 0.0)
local scr_fa = array(4)
local scr_fua = array(4)
local scr_act = array(4)
local scr_slide = array(4)  -- sliding dir (0 none)
local scr_sf = array(4)
local scr_ssx = array(4, 0.0)

-- audio ----------------------------------------------------------------
local mrow = -1            -- music row (-1 = off)
local macc = 0
local mlen = 512
local mc_sfx = array(4)
local mc_step = array(4)
local mc_acc = array(4)
local gs_sfx = array(4)    -- one-shot sfx overlay per channel
local gs_step = array(4)
local gs_acc = array(4)
local ch_note = array(4)   -- last note value sent (0 = off)
local ch_cut = array(4)    -- frames until forced noteoff (drum thump)

-- pools ------------------------------------------------------------------
local cards = pool(12)
-- (coins pool deferred with the coin attack; see PORT_NOTES.md)
-- (flowers pool deferred; see PORT_NOTES.md)
local parts = pool(24)
local streaks = pool(12)
local tiles = pool(12)
local poofs = pool(8)
-- (bunnies pool deferred with the victory flourish; see PORT_NOTES.md)
-- (points pool deferred; see PORT_NOTES.md)
-- (hearts pool deferred; see PORT_NOTES.md)
-- (lasers pool deferred; see PORT_NOTES.md)

-- misc scratch
-- (flowseq deferred with the conjure attack)
-- block-letter title glyphs: 8 letters x 5 rows, 3-bit masks (see draw.lua).
-- filled in _init (arrays are RAM; can't ROM-init with data).
local glyph = array(40)
local hat_on = 0
local hat_x = 0
local hat_y = 0
local hat_f = 0

-- ======================================================================
-- small helpers
-- ======================================================================

function rnd_int(lo, hi)
  return flr(lo + rnd(1 + hi - lo))
end


function freeze_shake(f, s)
  freeze_frames = max(f, freeze_frames)
  shake_frames = max(s, shake_frames)
end

function ease(kind, p)
  if (kind == E_IN) return 1 - (1 - p) * (1 - p)
  if (kind == E_OUT) return p * p
  if kind == E_OUTIN then
    if (p < 0.5) return p * p * 2
    local q = 2 * p - 1
    return (1 + 1 - (1 - q) * (1 - q)) / 2
  end
  return p
end

-- cubic bezier component
function bez(p0, p1, p2, p3, t)
  local u = 1 - t
  return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
end

-- ======================================================================
-- audio: 4-channel sequencer over gt.note (see PORT_NOTES.md)
-- ======================================================================

-- SLICE: sound is FULLY DEFERRED (see PORT_NOTES.md "code budget"). The port
-- had a working gt.note 4-channel sequencer (interactive one-shots + an
-- optional music track), but the sequencer + its transcribed sfx note tables
-- were ~2.5 KB of 65C02 that the 3-bank FLASH2M budget could not fit alongside
-- the fight logic. The ~30 jb_sfx()/music_play()/music_stop() call sites are
-- LEFT IN PLACE at their original beats and these four helpers are no-ops, so
-- the audio layer is restored by simply un-stubbing them (and restoring the
-- sfx tables via GAME_SFX/USED_ROWS in tools/mkmusic.mjs). As shipped the
-- game is silent and the whole gt.note path drops out of the update bank.
function jb_sfx(id, ch)
end

function music_play(row)
end

function music_stop()
end

function update_audio()
end

-- ======================================================================
-- actor movement (the original's move()/apply_velocity bezier system)
-- ======================================================================

function mv_to(i, tx, ty, dur, ez, a1x, a1y, a2x, a2y)
  local sx = ax[i]
  local sy = ay[i]
  mx0[i] = sx
  my0[i] = sy
  mx1[i] = sx + a1x
  my1[i] = sy + a1y
  mx2[i] = tx + a2x
  my2[i] = ty + a2y
  mx3[i] = tx
  my3[i] = ty
  mvf[i] = 0
  mvdur[i] = dur
  mvez[i] = ez
  mvon[i] = 1
end

-- default anchors = {dx/4, dy/4, -dx/4, -dy/4}
function mv_to_d(i, tx, ty, dur, ez)
  local dx = tx - ax[i]
  local dy = ty - ay[i]
  mv_to(i, tx, ty, dur, ez, dx / 4, dy / 4, -dx / 4, -dy / 4)
end

function mv_step(i)
  if (mvon[i] == 0) return
  mvf[i] += 1
  if mvf[i] >= mvdur[i] then
    ax[i] = mx3[i]
    ay[i] = my3[i]
    mvon[i] = 0
    return
  end
  local t = ease(mvez[i], mvf[i] / mvdur[i])
  ax[i] = bez(mx0[i], mx1[i], mx2[i], mx3[i], t)
  ay[i] = bez(my0[i], my1[i], my2[i], my3[i], t)
end

function mv_cancel(i)
  mvon[i] = 0
end

-- calc_idle_mult: idle bobbing (n = 2 for mirrors, 4 for hands)
function idle_step(i, f, n)
  local m = aim[i]
  if aidle[i] == 1 then
    m += 0.05
  else
    m -= 0.05
  end
  aim[i] = mid(0, m, 1)
  adox[i] = aim[i] * 3 * sin(f / 64)
  adoy[i] = aim[i] * n * sin(f / 32)
end

-- ======================================================================
-- effects
-- ======================================================================

function spawn_poof(x, y)
  add(poofs, { x = x, y = y, f = 0 })
end

-- poof with sound (the original's entity poof() helper)
function poof_at(x, y, forceful)
  if forceful == 1 then
  else
  end
  spawn_poof(x, y)
end

function spawn_burst(x, y, dy, num, col, speed)
  local i = 1
  while i <= num do
    local angle = (i + rnd(0.7)) / num
    local ps = speed * (0.5 + rnd(0.7))
    add(parts, {
      x = x, y = y - dy, px = x, py = y - dy,
      vx = ps * cos(angle), vy = ps * sin(angle) - speed / 2,
      fric = 0.75, grav = 0.1, col = col, ftd = rnd_int(13, 19),
    })
    i += 1
  end
end


function spawn_pain(x, y)
  -- original entity 28 (baked art cut for sheet space): prim starburst
  add(parts, {
    x = x, y = y - 8, px = x, py = y - 16,
    vx = 0, vy = 0, fric = 1, grav = 0, col = 7, ftd = 3,
  })
end

function update_parts()
  for p in all(parts) do
    p.vy += p.grav
    p.vx *= p.fric
    p.vy *= p.fric
    p.px = p.x
    p.py = p.y
    p.x += p.vx
    p.y += p.vy
    p.ftd -= 1
    if (p.ftd <= 0) del(parts, p)
  end
  -- health streaks: SLICE simplifies the cart's two-phase (drift-then-fly)
  -- comet into a single staggered ease toward the boss bar. The stagger
  -- (s.dl countdown) still spreads arrivals out so the bar fills smoothly.
  for s in all(streaks) do
    if s.dl > 0 then
      s.dl -= 1
      if s.dl == 0 then
        s.sx = s.x
        s.sy = s.y
        s.f = 0
      end
    else
      s.f += 1
      local t = ease(E_OUT, s.f / 8)
      s.px = s.x
      s.py = s.y
      s.x = s.sx + (s.tx - s.sx) * t
      s.y = s.sy + (-58 - s.sy) * t
      if s.f >= 8 then
        del(streaks, s)
        health_arrive()
      end
    end
  end
end

-- ======================================================================
-- player
-- ======================================================================

function pcol()
  return 1 + px \ 10
end

function prow()
  return 1 + py \ 8
end

-- (coin attack + its helpers deferred in this slice; see PORT_NOTES.md.)

function undo_step()
  px = 10 * pprev_col - 5
  py = 8 * pprev_row - 4
  pstep_frames = 0
  pstep_dir = 4
  pnext_dir = 4
end


-- returns 1 if the step started, 0 if it couldn't (gtlua: no bool returns)
function try_step(dir)
  if pstep_dir == 4 and pteeter <= 0 and pbump <= 0 and pstun <= 0 then
    if bh_health <= 0 and boss_phase <= 0 and boss_on == 0 then
    end
    pfacing = dir
    pstep_dir = dir
    pstep_frames = 4
    pnext_dir = 4
    return 1
  end
  return 0
end

function queue_step(dir)
  if try_step(dir) == 0 then
    pnext_dir = dir
  end
end

function check_inputs()
  if (btnp(0)) queue_step(0)
  if (btnp(1)) queue_step(1)
  if (btnp(2)) queue_step(2)
  if (btnp(3)) queue_step(3)
end

function apply_step()
  local dir = pstep_dir
  local dist = pstep_frames
  if dir ~= 4 then
    if dir > 1 then
      local d2 = dist
      if (dist > 2) d2 = dist - 1
      pvy += (2 * dir - 5) * d2
    else
      pvx += 2 * dir * dist - dist
    end
    pstep_frames -= 1
    if pstep_frames <= 0 then
      pstep_dir = 4
      if pnext_dir ~= 4 then
        try_step(pnext_dir)
        apply_step()
      end
    end
  end
end

function update_player()
  if (pstun > 0) pstun -= 1
  if (pteeter > 0) pteeter -= 1
  if (pbump > 0) pbump -= 1
  check_inputs()
  if pnext_dir ~= 4 and pstep_dir == 4 then
    try_step(pnext_dir)
  end
  pprev_col = pcol()
  pprev_row = prow()
  if pstun <= 0 then
    pvx = 0
    pvy = 0
    apply_step()
    px += pvx
    py += pvy
    local c = pcol()
    local r = prow()
    if pprev_col ~= c or pprev_row ~= r then
      if c ~= mid(1, c, 8) or r ~= mid(1, r, 5) then
        undo_step()
        pteeter = 11
      end
      -- (coin-square bump removed with the coin attack; see PORT_NOTES.md)
    end
  end
  if (pinvinc > 0) pinvinc -= 1
end

-- (player reflection deferred in this slice; see PORT_NOTES.md.)

function player_hurt(hx, hy)
  if (pinvinc > 0 or palive == 0) return
  spawn_pain(hx, hy)
  freeze_shake(6, 10)
  ph_anim = 1
  ph_dc = 20
  pinvinc = 60
  pstun = 19
  score_mult = 0
  ph_hearts -= 1
  if ph_hearts <= 0 then
    start_death()
  end
end

-- ======================================================================
-- magic tiles + score/health economy
-- ======================================================================

function spawn_magic_tile(delay)
  if bh_health >= 60 then
    bh_dc = 61
  end
  local d = delay
  if (d < 1) d = 1
  add(tiles, {
    x = 10 * rnd_int(1, 8) - 5,
    y = 8 * rnd_int(1, 5) - 4,
    st = 0, t = d, f = 0,
  })
end

function update_tiles()
  for tl in all(tiles) do
    tl.f += 1
    if tl.st == 0 then
      tl.t -= 1
      if tl.t == 10 then
      end
      if tl.t <= 0 then
        tl.st = 1
        tl.f = 0
        freeze_shake(0, 1)
        spawn_burst(tl.x, tl.y, 0, 4, 16, 4)
      end
    elseif tl.st == 2 then
      tl.t -= 1
      if (tl.t <= 0) del(tiles, tl)
    else
      -- active: collected by the player or the reflection
      local c = 1 + tl.x \ 10
      local r = 1 + tl.y \ 8
      local got = 0
      if (palive == 1 and pcol() == c and prow() == r) got = 1
      if got == 1 then
        tl.st = 2
        tl.t = 6
        collect_tile(tl.x, tl.y, tl.f)
      end
    end
  end
end

function collect_tile(x, y, fa)
  freeze_shake(2, 2)
  score_mult = min(score_mult + 1, 8)
  score += score_mult
  local health_change = 6
  if (boss_phase == 0) health_change = 12
  spawn_burst(x, y, 0, 25, 16, 10)
  local i = 1
  while i <= health_change do
    -- streak flies from the tile to the boss bar after a stagger (dl); the
    -- cart's initial burst velocity is dropped with the drift phase.
    add(streaks, {
      x = x + 0.0, y = y + 0.0, px = x + 0.0, py = y + 0.0,
      sx = x + 0.0, sy = y + 0.0, tx = 8 + min(bh_health + i, 60),
      dl = 7 + 2 * i, f = 0,
    })
    i += 1
  end
  if health_change + bh_health < 60 then
    local base = 120
    if (boss_phase < 1) base = 100
    spawn_magic_tile(base - min(fa, 20))
  end
end

-- a health streak reached the bar (the original's per-particle promise)
function health_arrive()
  if bh_health < 60 then
    bh_health = mid(0, bh_health + 1, 60)
    bh_vis = 1
    bh_rainbow = 15
    local h = bh_health
    if boss_phase == 0 then
      if h == 25 then
        spawn_boss()
      elseif h == 37 then
        avis[BB] = 1
      elseif h == 60 then
        boss_intro()
      end
    elseif h >= 60 then
      -- SLICE: phase 2 is the final phase (phases 3-4 + the player-reflection
      -- and green-mirror mechanics are deferred to fit the 3-bank FLASH2M
      -- budget; see PORT_NOTES.md). Victory triggers after clearing phase 2.
      if boss_phase >= 2 then
        start_victory()
      else
        start_phase_transition()
      end
    end
  end
end

-- (floating score popups deferred in this slice.)


-- ======================================================================
-- hazards
-- ======================================================================

function spawn_card(x, y, vx)
  local red = 0
  if (rnd(1) < 0.5) red = 1
  add(cards, { x = x + 0.0, y = y, vx = vx, red = red, f = 0 })
end

function update_cards()
  for cd in all(cards) do
    cd.x += cd.vx
    cd.f += 1
    if palive == 1 and pinvinc <= 0 then
      local c = 1 + flr(cd.x) \ 10
      local r = 1 + cd.y \ 8
      if c == pcol() and r == prow() then
        player_hurt(px, py)
      end
    end
    if (cd.f >= 100 or cd.x < -20 or cd.x > 100) del(cards, cd)
  end
end

-- (throw_coin_at / update_coins / despawn_coins_of deferred in this slice.)

-- conjure pattern: the original's do_a_math hole sequence


-- spawn the flower field for boss b (1 = holes pattern, 2 = complement)


-- (flower attack + its update/render deferred in this slice.)


-- (laser attack deferred in this slice; see PORT_NOTES.md.)

-- (heart pickup deferred in this slice; see PORT_NOTES.md.)


-- (victory top-hat + bunnies flourish deferred in this slice.)

function update_poofs()
  for p in all(poofs) do
    p.f += 1
    if (p.f >= 12) del(poofs, p)
  end
end

-- cancel_everything: clears boss-generated entities on phase changes
function clear_boss_spawns()
  for cd in all(cards) do
    del(cards, cd)
  end
  for tl in all(tiles) do
    if (tl.st > 0) del(tiles, tl)
  end
end

-- ======================================================================
-- boss: spawn / helpers
-- ======================================================================

function hand_dir(i)
  if (i == LH or i == GLH) return -1
  return 1
end

function boss_base(b)
  if (b == 2) return GB
  return BB
end

function set_idle(b, on)
  local i = boss_base(b)
  aidle[i] = on
  aidle[i + 1] = on
  aidle[i + 2] = on
end

-- SLICE: only the main boss (b=1) exists, so expression/home always map
-- to its state (the green mirror's gexpr/ghome_x are deferred).
function set_expr(b, e)
  bexpr = e
end

function home_x_of(b)
  return bhome_x
end

function spawn_boss()
  boss_on = 1
  bfa = 0
  bexpr = 4
  bhat = 0
  ax[BB] = 40
  ay[BB] = -28
  avis[BB] = 0
  ax[LH] = 40 - 18
  ay[LH] = -23
  avis[LH] = 0
  apose[LH] = 3
  ax[RH] = 40 + 18
  ay[RH] = -23
  avis[RH] = 0
  apose[RH] = 3
end

-- (spawn_green + the green-mirror phase-4 schedule are deferred in this
-- slice; see PORT_NOTES.md.)

function hand_appear(i)
  if avis[i] == 0 then
    avis[i] = 1
    poof_at(flr(ax[i]), flr(ay[i]), 0)
  end
end


-- return_to_ready_position (instant part; the 25-frame wait is scripted)
function start_ready(b, expr)
  local i = boss_base(b)
  local hx = home_x_of(b)
  bwand_l = 0
  bwand_r = 0
  apose[i + 1] = 3
  apose[i + 2] = 3
  set_idle(b, 1)
  set_expr(b, expr)
  mv_to_d(i, hx, bhome_y, 15, E_IN)
  mv_to(i + 1, hx - 18, bhome_y + 5, 15, E_IN, -10, -10, -20, 0)
  hand_appear(i + 1)
  mv_to(i + 2, hx + 18, bhome_y + 5, 15, E_IN, 10, -10, 20, 0)
  hand_appear(i + 2)
end

-- ======================================================================
-- hand machine
-- ======================================================================

function hand_start_cards(i, first, delay)
  hA[i] = H_CARDS
  hS[i] = 0
  hFirst[i] = first
  if first == 1 then
    hRow[i] = 0
    hW[i] = delay
  else
    hRow[i] = 1
    hW[i] = delay + 19
  end
  aidle[i] = 0
end



function hand_step(i)
  if (hA[i] == H_NONE) return
  if hW[i] > 0 then
    hW[i] -= 1
    return
  end
  -- SLICE: only the main mirror's hands run (green deferred), so base=BB.
  local d = hand_dir(i)
  local base = BB
  if hA[i] == H_CARDS then
    if hS[i] == 0 then
      apose[i] = 3
      mv_to(i, 40 + 52 * d, 8 * (hRow[i] % 5) + 4, 18, E_OUTIN, 10 * d, -10, 10 * d, 10)
      hS[i] = 1
      hW[i] = 18
    elseif hS[i] == 1 then
      apose[i] = 2
      hS[i] = 2
      hW[i] = 12
    else
      apose[i] = 1
      spawn_card(flr(ax[i]) - 7 * d, flr(ay[i]), -1.5 * d)
      hRow[i] += 2
      hW[i] = 10
      if hRow[i] > 4 then
        hA[i] = H_NONE
      else
        hS[i] = 0
      end
    end
  elseif hA[i] == H_TEMPLE then
    if hS[i] == 0 then
      apose[i] = 1
      mv_to_d(i, ax[base] + 13 * d, ay[base], 20, E_LIN)
      hS[i] = 1
      hW[i] = 20
    else
      hA[i] = H_NONE
    end
  elseif hA[i] == H_FLOURISH then
    if hS[i] == 0 then
      mv_to(i, 40 + 20 * d, -30, 12, E_OUT, -20, 20, 0, 20)
      hS[i] = 1
      hW[i] = 12
    else
      apose[i] = 6
      spawn_burst(flr(ax[i]), flr(ay[i]), 20, 20, 3, 10)
      freeze_shake(0, 20)
      hA[i] = H_NONE
    end
  end
  -- (H_CASTR upgraded-cast for the green mirror is deferred in this slice.)
end

-- returns 1 if either hand of mirror b is running an action, else 0
function hands_busy(b)
  local i = boss_base(b)
  if (hA[i + 1] ~= H_NONE) return 1
  if (hA[i + 2] ~= H_NONE) return 1
  return 0
end

-- ======================================================================
-- sub-action machine (conjure / lasers / coins / cards / ready / ...)
-- ======================================================================

function sub_start(b, act)
  sA[b] = act
  sS[b] = 0
  sW[b] = 0
end

function sub_step(b)
  if (sA[b] == S_NONE) return
  if sW[b] > 0 then
    sW[b] -= 1
    return
  end
  local base = boss_base(b)
  local lh = base + 1
  local rh = base + 2
  if sA[b] == S_READY then
    if sS[b] == 0 then
      start_ready(b, sN[b])
      sS[b] = 1
      sW[b] = 25
    else
      sA[b] = S_NONE
    end
  elseif sA[b] == S_CARDS then
    if sS[b] == 0 then
      -- both hands, staggered: right first (or left for the reflection)
      if b == 1 then
        hand_start_cards(rh, 1, 0)
        hand_start_cards(lh, 0, 0)
      else
        hand_start_cards(lh, 1, 0)
        hand_start_cards(rh, 0, 0)
      end
      sS[b] = 1
    elseif hands_busy(b) == 0 then
      sA[b] = S_NONE
    end
  elseif sA[b] == S_CARDS_L then
    if sS[b] == 0 then
      hand_start_cards(lh, 0, 0)
      sS[b] = 1
    elseif hA[lh] == H_NONE then
      sA[b] = S_NONE
    end
  elseif sA[b] == S_CARDS_R then
    if sS[b] == 0 then
      hand_start_cards(rh, 1, 0)
      sS[b] = 1
    elseif hA[rh] == H_NONE then
      sA[b] = S_NONE
    end
  elseif sA[b] == S_REEL then
    if sS[b] == 0 then
      hand_appear(lh)
      apose[lh] = 3
      hand_appear(rh)
      apose[rh] = 3
      set_expr(b, 8)
      set_idle(b, 0)
      sS[b] = 1
    elseif sN[b] > 0 then
      -- shake all three actors
      local k = base
      while k <= rh do
        freeze_shake(0, 2)
        ax[k] = mid(10, ax[k], 70)
        ay[k] = mid(-40, ay[k], -20)
        poof_at(flr(ax[k]) + rnd_int(-10, 10), flr(ay[k]) + rnd_int(-10, 10), 1)
        mv_to_d(k, ax[k] + rnd_int(-7, 7), ay[k] + rnd_int(-7, 7), 6, E_OUT)
        k += 1
      end
      sN[b] -= 1
      sW[b] = 5
    else
      sA[b] = S_NONE
    end
  end
  -- (S_CAST — the reflection/green-mirror summon — is deferred in this slice.)
end

-- extracted sub-action branches (split out of the monolithic sub_step so
-- the FLASH2M bank solver can distribute them across banks; behaviour is
-- byte-for-byte identical to the inlined machine).


-- (sub_coins deferred in this slice.)


-- returns 1 if mirror b's sub-action machine is running, else 0
function sub_busy(b)
  if (sA[b] ~= S_NONE) return 1
  return 0
end

-- ======================================================================
-- rotation machine (per-phase attack loops + phase-change cinematics)
-- ======================================================================

function rot_start(b, act)
  rA[b] = act
  rS[b] = 0
  rW[b] = 0
end

-- advance helper: start sub and move to the given step
function rot_sub(b, act, stp)
  sub_start(b, act)
  rS[b] = stp
end

function decide_next_action()
  trans_lock = 0
  if boss_phase == 1 then
    rot_start(1, R_P1)
  elseif boss_phase == 2 then
    rot_start(1, R_P23)
  else
    rA[1] = R_NONE
  end
end

function rot_step_main()
  local b = 1
  if (rA[b] == R_NONE) return
  if rW[b] > 0 then
    rW[b] -= 1
    return
  end
  if (sub_busy(b) == 1) return
  if rA[b] == R_P1 then
    local s = rS[b]
    if s == 0 then
      rot_sub(b, S_READY, 1)
      sN[b] = 1
    elseif s == 1 then
      rW[b] = 15
      rS[b] = 2
    elseif s == 2 then
      rot_sub(b, S_CARDS_L, 3)
    elseif s == 3 then
      rot_sub(b, S_READY, 4)
      sN[b] = 1
    elseif s == 4 then
      rW[b] = 10
      rS[b] = 5
    elseif s == 5 then
      rot_sub(b, S_CARDS_R, 6)
    elseif s == 6 then
      rot_sub(b, S_READY, 7)
      sN[b] = 1
    elseif s == 7 then
      rW[b] = 20
      rS[b] = 0        -- loop: left-hand cards, right-hand cards, repeat
    else
      rS[b] = 0
    end
  elseif rA[b] == R_P23 then
    -- SLICE phase 2: a faster double-handed card barrage (the conjure,
    -- laser and coin attacks are deferred; see PORT_NOTES.md).
    local s = rS[b]
    if s == 0 then
      rW[b] = 10
      rS[b] = 1
    elseif s == 1 then
      rot_sub(b, S_CARDS, 2)
    elseif s == 2 then
      rot_sub(b, S_READY, 3)
      sN[b] = 1
    elseif s == 3 then
      rW[b] = 12
      rS[b] = 4
    elseif s == 4 then
      rot_sub(b, S_CARDS, 5)
    elseif s == 5 then
      rot_sub(b, S_READY, 6)
      sN[b] = 1
    else
      rS[b] = 0
    end
  elseif rA[b] == R_REEL then
    local s = rS[b]
    if s == 0 then
      -- cancel everything, appear, reel 10
      cancel_boss(1)
      avis[BB] = 1
      hand_appear(LH)
      hand_appear(RH)
      sN[b] = 10
      rot_sub(b, S_REEL, 1)
    elseif s == 1 then
      rW[b] = 10
      rS[b] = 2
    elseif s == 2 then
      set_expr(b, 5)
      rW[b] = 20
      rS[b] = 3
    elseif s == 3 then
      -- SLICE: only the phase 1->2 change exists (R_CHG1, the bouquet
      -- cinematic); the cast/reflection changes (CHG2/CHG3) are deferred.
      rot_start(b, R_CHG1)
    end
  elseif rA[b] == R_CHG1 then
    -- SLICE: the phase 1->2 change is a short reel + angry-expression beat
    -- (the cart's bouquet-offering + fist-pound cinematic is deferred).
    local s = rS[b]
    if s == 0 then
      rot_sub(b, S_READY, 1)
      sN[b] = 2
    elseif s == 1 then
      set_expr(b, 6)
      rW[b] = 30
      rS[b] = 2
    elseif s == 2 then
      set_expr(b, 3)
      rW[b] = 25
      rS[b] = 3
    else
      finish_phase_change()
    end
  elseif rA[b] == R_INTRO then
    local s = rS[b]
    if s == 0 then
      hand_appear(LH)
      hand_appear(RH)
      rW[b] = 25
      rS[b] = 1
    elseif s == 1 then
      set_expr(b, 5)
      rW[b] = 33
      rS[b] = 2
    elseif s == 2 then
      set_expr(b, 6)
      rW[b] = 28
      rS[b] = 3
    elseif s == 3 then
      set_expr(b, 1)
      bhat = 1
      poof_at(flr(ax[BB]), flr(ay[BB]) - 10, 0)
      rW[b] = 35
      rS[b] = 4
    else
      finish_phase_change()
    end
  end
end





-- SLICE: the boss reveal is compressed from the cart's 15-beat cinematic to
-- its essentials — hands appear, the boss cycles a few expressions, then the
-- top hat pops on. Same actors, same expression set, fewer in-between beats.

-- (green-mirror phase-4 schedule deferred; see PORT_NOTES.md.)

-- cancel_everything for boss b (+ boss-generated entities when main)
function cancel_boss(b)
  local base = boss_base(b)
  sA[b] = S_NONE
  hA[base + 1] = H_NONE
  hA[base + 2] = H_NONE
  mv_cancel(base)
  mv_cancel(base + 1)
  mv_cancel(base + 2)
  if b == 1 then
    bwand_l = 0
    bwand_r = 0
    bbouq = 0
    bdc = 0
    clear_boss_spawns()
    if green_on == 1 then
      green_on = 0
      rA[2] = R_NONE
      sA[2] = S_NONE
      hA[GLH] = H_NONE
      hA[GRH] = H_NONE
    end
  end
end

-- ======================================================================
-- phase transitions / cinematics
-- ======================================================================

function boss_intro()
  if (boss_phase >= 1) then
  else
  end
  trans_lock = 1
  rot_start(1, R_INTRO)
end

function start_phase_transition()
  trans_lock = 1
  rot_start(1, R_REEL)
end

function finish_phase_change()
  spawn_magic_tile(100)
  if boss_phase == 0 then
    scene_frame = 0
    ph_vis = 1
  end
  boss_phase += 1
  decide_next_action()
end

-- SLICE victory (compact): the mirror poofs away, the curtain draws, the
-- score banks, and the victory screen slides in. The original's bonus-tile
-- shower + top-hat/bunny flourish are deferred (see PORT_NOTES.md).
function start_victory()
  trans_lock = 1
  rA[1] = R_NONE
  cancel_boss(1)
  poof_at(40, -20, 1)
  boss_on = 0
  avis[BB] = 0
  avis[LH] = 0
  avis[RH] = 0
  vA = 1
  vW = 30
end

function victory_step()
  if (vA == 0) return
  if vW > 0 then
    vW -= 1
    return
  end
  if vA == 1 then
    cur_anim = 0
    cur_dc = 100
    is_paused = 1
    vA = 2
    vW = 75
  elseif vA == 2 then
    score += max(0, 380 - timer_seconds)
    scr_spawn(3, 63, 90)
    vA = 0
  end
end

-- SLICE death (compact): pause, close the curtain, slide in the game-over
-- screen. The original's drifting "figment" ghost is deferred.
function start_death()
  is_paused = 1
  trans_lock = 1
  cur_anim = 0
  cur_dc = 100
  scr_spawn(4, 63, 60)
  palive = 0
  dA = 0
  dW = 0
end

-- (death_step + the figment ghost drift are folded into start_death above.)

-- ======================================================================
-- screens (title / credit / victory / game over)
-- ======================================================================

function scr_spawn(i, x, fua)
  scr_on[i] = 1
  scr_x[i] = x
  scr_fa[i] = 0
  scr_fua[i] = fua
  scr_act[i] = 0
  scr_slide[i] = 0
end

-- mark a screen as leaving (hidden next update). dir kept for call-site
-- compatibility; screens no longer bezier-slide (see PORT_NOTES.md).
function scr_slide_off(i, dir)
  scr_slide[i] = -1
end

function show_title_screen(dir)
  scr_spawn(1, 63, 115)
end

function update_screens()
  -- SLICE: screens appear/leave in place (the cart's 100-frame bezier slide
  -- is deferred to save the update-bank budget). scr_slide<0 = leaving.
  local i = 1
  while i <= 4 do
    if scr_on[i] == 1 then
      scr_fa[i] += 1
      if scr_slide[i] < 0 then
        scr_on[i] = 0
        scr_slide[i] = 0
      elseif scr_fua[i] > 0 then
        scr_fua[i] -= 1
        if (scr_fua[i] == 0) scr_act[i] = 1
      end
    end
    i += 1
  end
  -- title screen activation
  if scr_on[1] == 1 and scr_act[1] == 1 and (btnp(1) or btnp(4)) then
    scr_act[1] = 0
    scr_slide_off(1, 1)
    title_activated()
  end
  -- victory screen -> back to the title (credits screen deferred)
  if scr_on[3] == 1 and scr_act[3] == 1 and (btnp(1) or btnp(4)) then
    scr_act[3] = 0
    scr_slide_off(3, 1)
    is_paused = 0
    wipe_gameplay()
    show_title_screen(1)
  end
  -- game over: A/right = retry this phase, left = back to title
  if scr_on[4] == 1 and scr_act[4] == 1 then
    if btnp(1) or btnp(4) then
      scr_act[4] = 0
      scr_slide_off(4, 1)
      retry_game()
    elseif btnp(0) then
      scr_act[4] = 0
      scr_slide_off(4, -1)
      wipe_gameplay()
      show_title_screen(-1)
    end
  end
end

function title_activated()
  score = 0
  timer_seconds = 0
  wipe_gameplay()
  start_game(0)
end

function retry_game()
  local ph = boss_phase
  score = 0
  if (ph <= 1) score = 40
  if (ph <= 1) timer_seconds = 0
  wipe_gameplay()
  start_game(ph)
end

-- remove every gameplay entity (the original resets its entities list)
function wipe_gameplay()
  palive = 0
  boss_on = 0
  is_paused = 0
  trans_lock = 0
  rA[1] = R_NONE
  sA[1] = S_NONE
  vA = 0
  local i = 1
  while i <= 6 do
    hA[i] = H_NONE
    mvon[i] = 0
    i += 1
  end
  clear_boss_spawns()
  for tl in all(tiles) do
    del(tiles, tl)
  end
  for p in all(parts) do
    del(parts, p)
  end
  for s in all(streaks) do
    del(streaks, s)
  end
  for p in all(poofs) do
    del(poofs, p)
  end
  bh_health = 0
  bh_vis = 0
  bh_rainbow = 0
  bdc = 0
end

-- start_game(phase): curtain opening + spawn staging
function start_game(phase)
  sg_phase = phase
  sg_step = 1
  sg_wait = 35
  game_on = 0
end

function start_game_step()
  if (sg_step == 0) return
  if sg_wait > 0 then
    sg_wait -= 1
    return
  end
  if sg_step == 1 then
    cur_anim = 1
    cur_dc = 100
    sg_step = 2
    sg_wait = 0
  elseif sg_step == 2 then
    score_mult = 0
    boss_phase = max(0, sg_phase - 1)
    is_paused = 0
    -- spawn player + UI
    palive = 1
    px = 45
    py = 20
    pvx = 0
    pvy = 0
    pfacing = 0
    pstep_dir = 4
    pnext_dir = 4
    pstep_frames = 0
    pteeter = 0
    pbump = 0
    pstun = 0
    pinvinc = 0
    pfa = 0
    ph_hearts = 4
    ph_x = 63
    ph_y = 122
    ph_anim = 0
    ph_dc = 0
    ph_vis = 0
    ph_slide = 0
    ph_move = 0
    bh_health = 0
    bh_vis = 0
    if sg_phase > 0 then
      spawn_boss()
      avis[BB] = 1
      bh_vis = 1
      ph_vis = 1
      bhat = 0
      if (sg_phase > 1) bhat = 1
      sg_step = 3
      sg_wait = 30
    else
      spawn_magic_tile(150 + 30)
      sg_step = 0
      game_on = 1
    end
  elseif sg_step == 3 then
    boss_intro()
    sg_step = 0
    game_on = 1
  end
end

-- >>>>>> gen/music_gen.lua <<<<<<
-- music_gen.lua — GENERATED by tools/mkmusic.mjs; do not hand-edit.
-- Tracker data from the cart, re-encoded for the gt.note sequencer.









-- >>>>>> gen/gfx_gen.lua <<<<<<
-- gfx_gen.lua — GENERATED by tools/mkgfx.mjs; do not hand-edit.
-- Sprite dispatch: each g_* draws with the source-rect top-left at (x,y).

function g_pl(f, fc, gr, x, y)
  if f == 7 then
    spr(4, x, y, 2, 2)
    return
  end
  if gr == 0 then
    if fc == 0 then
      if f == 0 then spr(216, x + 4, y, 1, 1)
      elseif f == 1 then spr(154, x, y, 2, 1)
      elseif f == 2 then spr(158, x + 2, y, 2, 1)
      elseif f == 3 then spr(220, x + 3, y, 1, 1)
      elseif f == 4 then spr(162, x + 2, y, 2, 1)
      elseif f == 5 then spr(170, x, y + 2, 2, 1)
      elseif f == 6 then spr(224, x + 3, y, 1, 1)
      end
    end
    if fc == 1 then
      if f == 0 then spr(215, x + 4, y, 1, 1)
      elseif f == 1 then spr(142, x, y, 2, 1)
      elseif f == 2 then spr(156, x + 2, y, 2, 1)
      elseif f == 3 then spr(219, x + 3, y, 1, 1)
      elseif f == 4 then spr(160, x + 2, y, 2, 1)
      elseif f == 5 then spr(168, x, y + 2, 2, 1)
      elseif f == 6 then spr(223, x + 3, y, 1, 1)
      end
    end
    if fc == 2 then
      if f == 0 then spr(217, x + 2, y, 1, 1)
      elseif f == 1 then spr(100, x + 2, y, 1, 2)
      elseif f == 2 then spr(102, x + 2, y, 1, 2)
      elseif f == 3 then spr(221, x + 2, y, 1, 1)
      elseif f == 4 then spr(164, x + 1, y, 2, 1)
      elseif f == 5 then spr(172, x + 1, y + 2, 2, 1)
      elseif f == 6 then spr(176, x + 1, y + 2, 2, 1)
      end
    end
    if fc == 3 then
      if f == 0 then spr(218, x + 2, y + 3, 1, 1)
      elseif f == 1 then spr(101, x + 2, y, 1, 2)
      elseif f == 2 then spr(103, x + 2, y + 1, 1, 2)
      elseif f == 3 then spr(222, x + 2, y + 3, 1, 1)
      elseif f == 4 then spr(166, x + 1, y + 4, 2, 1)
      elseif f == 5 then spr(174, x + 1, y + 3, 2, 1)
      elseif f == 6 then spr(178, x, y + 6, 2, 1)
      end
    end
  end
end

function g_face(e, gr, x, y)
  if e == 1 then spr(8, x, y, 2, 2)
  elseif e == 2 then spr(10, x, y, 2, 2)
  elseif e == 3 then spr(12, x, y, 2, 2)
  elseif e == 4 then spr(8, x, y, 2, 2)
  elseif e == 5 then spr(14, x, y, 2, 2)
  elseif e == 6 then spr(12, x, y, 2, 2)
  elseif e == 7 then spr(36, x, y, 2, 2)
  elseif e == 8 then spr(38, x, y, 2, 2)
  end
end

function g_hand(p, right, gr, x, y)
  if gr == 0 then
    if right == 0 then
      if p == 1 then spr(188, x + 2, y + 4, 2, 1)
      elseif p == 2 then spr(233, x + 2, y + 4, 1, 1)
      elseif p == 3 then spr(40, x, y + 1, 2, 2)
      elseif p == 4 then spr(40, x, y + 1, 2, 2)
      elseif p == 5 then spr(108, x + 2, y, 1, 2)
      elseif p == 6 then spr(110, x + 1, y, 1, 2)
      end
    end
    if right == 1 then
      if p == 1 then spr(190, x + 2, y + 4, 2, 1)
      elseif p == 2 then spr(234, x + 2, y + 4, 1, 1)
      elseif p == 3 then spr(42, x, y + 1, 2, 2)
      elseif p == 4 then spr(42, x, y + 1, 2, 2)
      elseif p == 5 then spr(109, x + 2, y, 1, 2)
      elseif p == 6 then spr(111, x + 1, y, 1, 2)
      end
    end
  end
end

function g_body(x, y)
  spr(0, x, y, 2, 4)
end


function g_hatworn(x, y)
  spr(6, x, y, 2, 2)
end





function g_iconheart(x, y)
  spr(247, x, y + 1, 1, 1)
end

function g_iconclock(x, y)
  spr(248, x + 1, y, 1, 1)
end





function g_poof(f, x, y)
  if f == 0 then spr(72, x + 3, y + 4, 2, 2)
  elseif f == 1 then spr(74, x, y + 1, 2, 2)
  elseif f == 2 then spr(76, x, y, 2, 2)
  elseif f == 3 then spr(78, x, y, 2, 2)
  end
end



function g_card(f, red, x, y)
  if red == 1 then
    if f == 0 then spr(68, x, y, 2, 2)
    elseif f == 1 then spr(235, x + 1, y + 2, 1, 1)
    elseif f == 2 then spr(70, x, y, 2, 2)
    elseif f == 3 then spr(236, x + 2, y + 1, 1, 1)
    end
    return
  end
  if f == 0 then spr(68, x, y, 2, 2)
  elseif f == 1 then spr(235, x + 1, y + 2, 1, 1)
  elseif f == 2 then spr(70, x, y, 2, 2)
  elseif f == 3 then spr(236, x + 2, y + 1, 1, 1)
  end
end

function g_mtile(rc, x, y)
  if rc == 0 then spr(196, x, y, 2, 1)
  elseif rc == 1 then spr(249, x, y, 2, 1)
  elseif rc == 2 then spr(198, x, y, 2, 1)
  elseif rc == 3 then spr(251, x, y, 2, 1)
  elseif rc == 4 then spr(200, x, y, 2, 1)
  elseif rc == 5 then spr(253, x, y, 2, 1)
  end
end


function g_btnicon(fl, x, y)
  if fl == 1 then spr(246, x, y, 1, 1) else spr(245, x, y, 1, 1) end
end

function g_bg()
  -- stars are single pixels in the cart tiles: pset is cheaper
  pset(96, 15, 1)
  pset(80, 23, 1)
  pset(48, 31, 1)
  pset(88, 31, 1)
  pset(40, 55, 1)
  pset(96, 55, 1)
  pset(8, 87, 1)
  pset(112, 95, 1)
  spr(213, 16, 48, 1, 1)
  spr(213, 112, 72, 1, 1)
  spr(214, 16, 56, 1, 1)
  spr(146, 24, 56, 4, 1)
  spr(146, 56, 56, 4, 1)
  spr(146, 88, 56, 2, 1)
  spr(210, 16, 64, 1, 1)
  spr(131, 24, 64, 4, 1)
  spr(130, 56, 64, 1, 1)
  spr(131, 64, 64, 5, 1)
  spr(210, 16, 80, 1, 1)
  spr(131, 24, 80, 4, 1)
  spr(130, 56, 80, 1, 1)
  spr(131, 64, 80, 5, 1)
  spr(210, 16, 96, 1, 1)
  spr(131, 24, 96, 4, 1)
  spr(130, 56, 96, 1, 1)
  spr(131, 64, 96, 5, 1)
  spr(210, 16, 72, 1, 1)
  spr(136, 24, 72, 4, 1)
  spr(211, 56, 72, 1, 1)
  spr(136, 64, 72, 5, 1)
  spr(210, 16, 88, 1, 1)
  spr(136, 24, 88, 4, 1)
  spr(211, 56, 88, 1, 1)
  spr(136, 64, 88, 5, 1)
  spr(212, 16, 104, 1, 1)
  spr(150, 24, 104, 4, 1)
  spr(150, 56, 104, 4, 1)
  spr(150, 88, 104, 2, 1)
end

-- >>>>>> src/draw.lua <<<<<<
-- ======================================================================
-- part 4: drawing, HUD, block-letter title, curtains, main callbacks
-- ----------------------------------------------------------------------
-- The original PICO-8 cart drew every entity through one draw_sprite
-- method + a render_layer sort. gtlua has no closures/method tables, so
-- draw order here is a fixed back-to-front sequence (background, boss,
-- hazards, player, HUD, screens, curtains) that reproduces the cart's
-- layering. Sprite dispatch lives in gfx_gen.lua (the g_* functions);
-- this file decides WHAT to draw and WHERE, from the numeric state.
-- ======================================================================

-- baked rainbow tile index (magic tiles + rainbow-flash boss): the cart
-- cycles p8 colours 8..14; here we pick one of the six baked mtile art
-- variants by scene_frame (see g_mtile in gfx_gen.lua).
function rainbow_row()
  return (scene_frame \ 4) % 6
end

-- ---- boss actor draw --------------------------------------------------
-- one mirror = body + face + hat + two hands, drawn from actor slots.
-- b: 1 = main boss (blue), 2 = green reflection.
function draw_hand(i, gr)
  if avis[i] == 0 then
    return
  end
  local x = flr(ax[i] + adox[i])
  local y = flr(ay[i] + adoy[i])
  local right = 0
  if (i == RH or i == GRH) then right = 1 end
  g_hand(apose[i], right, gr, x + 4, y + 8)
  -- wand overlay (thin stick + bright tip): the left hand holds the wand
  -- during the cast/flourish. Drawn as primitives (right-hand upgrade cut).
  if i == LH and bwand_l == 1 then
    local wx = x + 6
    line(wx, y + 4, wx + 3, y + 14, 4)
    pset(wx, y + 3, 10)
    pset(wx, y + 2, 7)
  end
end

-- SLICE: only the main (blue) mirror; the green reflection is deferred.
function draw_mirror(b)
  -- draw hands behind the body first (both hands, then body on top)
  draw_hand(LH, 0)
  draw_hand(RH, 0)
  if avis[BB] == 1 then
    local x = flr(ax[BB] + adox[BB])
    local y = flr(ay[BB] + adoy[BB])
    g_body(x + 6, y + 12)
    -- rainbow shimmer face substitute when the health bar just filled
    local e = bexpr
    if bh_rainbow > 0 then
      e = 8
    end
    if e > 0 then
      g_face(e, 0, x + 5, y + 7)
    end
    if bhat == 1 then
      g_hatworn(x + 6, y + 15)
    end
    -- laser charge line: a thin column from the boss down to row bottom
    if bdc % 2 > 0 then
      line(x + 6, y + 19, x + 6, 60, 14)
    end
  end
end

-- ---- player + reflection ---------------------------------------------
function draw_player()
  if (palive == 0) return
  -- invincibility flicker
  if pinvinc > 0 and pinvinc % 4 >= 2 then
    return
  end
  -- walk frame: 7 = bump/stun pose, else derive from step/teeter
  local f = 0
  local fc = pfacing
  local sp = pstep_frames
  if sp > 0 then
    f = 4 - sp
    if (f < 1) f = 1
  end
  if pteeter > 0 or pbump > 0 then
    f = 7
  end
  if pstun > 0 then
    f = 7
  end
  g_pl(f, fc, 0, px - 5, py - 6)
  -- (player reflection deferred in this slice.)
end

-- ---- pooled hazards + effects ----------------------------------------
function draw_entities()
  -- magic tiles (behind everything gameplay)
  local mr = rainbow_row()
  for tl in all(tiles) do
    if tl.st == 0 then
      circ(tl.x, tl.y - 1, min(tl.f \ 4, 4), 2)   -- pending target ring
    else
      g_mtile(mr, tl.x - 4, tl.y - 4)              -- active / collected flash
    end
  end
  -- (landed coins + flower field deferred in this slice; see PORT_NOTES.md)
end

function draw_hazards_top()
  -- cards
  for cd in all(cards) do
    local f = (cd.f \ 4) % 4
    g_card(f, cd.red, flr(cd.x) - 5, cd.y - 5)
  end
  -- (in-flight coins, heart pickups + laser beams deferred in this slice)
  -- (floating score popups deferred in this slice)
  -- particles (bursts / petals)
  for p in all(parts) do
    local c = p.col
    if (c == 16) c = rainbow_color
    pset(flr(p.x), flr(p.y), c)
  end
  -- health streaks (comet trails to the boss bar)
  for s in all(streaks) do
    local c = 11
    if (s.dl > 0) c = 16
    if (c == 16) c = rainbow_color
    line(flr(s.px), flr(s.py), flr(s.x), flr(s.y), c)
  end
  -- poofs
  for p2 in all(poofs) do
    local f = min(p2.f \ 3, 3)
    g_poof(f, flr(p2.x) - 8, flr(p2.y) - 8)
  end
  -- (victory bunnies/hat + game-over figment ghost deferred in this slice.)
end

-- a small 2-digit "x00" score popup rendered with print_num
-- (print_pts deferred with score popups.)


-- ---- HUD --------------------------------------------------------------
function draw_hud()
  -- boss health bar (top)
  if bh_vis == 1 then
    local w = bh_health
    if (w > 60) w = 60
    rectfill(33, 2, 94, 6, 1)
    local c = 8
    if (bh_rainbow > 0) c = rainbow_color
    if w > 0 then
      rectfill(34, 3, 34 + w, 5, c)
    end
    rect(33, 2, 94, 6, 5)
  end
  -- player hearts (bottom)
  if ph_vis == 1 then
    local hx = flr(ph_x)
    local i = 1
    while i <= 4 do
      local sx = hx - 18 + (i - 1) * 9
      if ph_hearts >= i then
        g_iconheart(sx, flr(ph_y))
      end
      i += 1
    end
  end
  -- score + timer while a boss is active
  if boss_phase > 0 and ph_vis == 1 then
    print(score, 2, 2, 7)
    g_iconclock(2, 120)
    print(timer_seconds, 10, 121, 7)
  end
end

-- ======================================================================
-- block-letter title (spr/rectfill — no font). "JUST ONE BOSS" in fat
-- 3x5-cell glyphs stamped as rectfills, centred on scr_x[1].
-- ======================================================================

-- one filled block-letter glyph from a 3-wide x 5-tall bit mask stored in
-- the top-level `glyph` array (5 rows per letter, code ch = 1..8). Rows are
-- packed MSB-first (bit 2,1,0 = left,mid,right of the 3-cell grid).
function draw_letter(ch, x, y, col)
  local base = (ch - 1) * 5
  local ry = 0
  while ry < 5 do
    local bits = glyph[base + ry + 1]
    local oy = y + ry * 2
    if (bits \ 4 % 2 == 1) rectfill(x, oy, x + 1, oy + 1, col)
    if (bits \ 2 % 2 == 1) rectfill(x + 2, oy, x + 3, oy + 1, col)
    if (bits % 2 == 1) rectfill(x + 4, oy, x + 5, oy + 1, col)
    ry += 1
  end
end

-- "JUST ONE" on one line, "BOSS" big on the next.
function draw_title_logo(cx, y)
  -- line 1: JUST ONE (8 glyphs incl. gap), each glyph 6px + 1 gap
  local w = 7
  local x = cx - (4 * w) - 4 - (2 * w)
  draw_letter(1, x, y, 7)          x += w   -- J
  draw_letter(2, x, y, 7)          x += w   -- U
  draw_letter(3, x, y, 7)          x += w   -- S
  draw_letter(4, x, y, 7)          x += w + 4 -- T + gap
  draw_letter(5, x, y, 7)          x += w   -- O
  draw_letter(6, x, y, 7)          x += w   -- N
  draw_letter(7, x, y, 7)                    -- E
  -- line 2: BOSS in the rainbow colour, bigger baseline gap
  local y2 = y + 16
  local bw = 8
  local bx = cx - 2 * bw
  local rc = rainbow_color
  draw_letter(8, bx, y2, rc)       bx += bw   -- B
  draw_letter(5, bx, y2, rc)       bx += bw   -- O
  draw_letter(3, bx, y2, rc)       bx += bw   -- S
  draw_letter(3, bx, y2, rc)                  -- S
end

-- ---- screens ----------------------------------------------------------
function draw_screens()
  -- title
  if scr_on[1] == 1 then
    local cx = flr(scr_x[1])
    draw_title_logo(cx, 28)
    if scr_act[1] == 1 and scr_fa[1] % 30 < 22 then
      g_btnicon(1, cx - 20, 98)
      print("start", cx - 8, 99, 13)
    end
  end
  -- victory
  if scr_on[3] == 1 then
    local cx = flr(scr_x[3])
    print("you win!", cx - 16, 44, 15)
    print(score, cx - 6, 71, 7)
    if scr_act[3] == 1 and scr_fa[3] % 30 < 22 then
      print("press A", cx - 14, 99, 13)
    end
  end
  -- (credits screen deferred in this slice.)
  -- game over
  if scr_on[4] == 1 then
    local cx = flr(scr_x[4])
    print("defeated", cx - 16, 40, 8)
    if scr_act[4] == 1 and scr_fa[4] % 30 < 22 then
      print("A retry", cx - 14, 99, 13)
    end
  end
end

-- ---- curtains (the stage cloth that wipes scenes) --------------------
function draw_curtains()
  if (cur_vis == 0) return
  local amt = flr(cur_amount)
  -- left + right panels close toward the centre
  draw_curtain_panel(1, 1, amt)
  draw_curtain_panel(125, -1, amt)
end

function draw_curtain_panel(x, dir, amt)
  rectfill(x - 10 * dir, 0, x + dir * amt, 127, 0)
  local x2 = 10
  while x2 <= 63 do
    local x3 = x + dir * x2 * (62 + amt) / 124
    line(x3, 11, x3, 60 + flr(40 * cos(x2 / 90)), 2)
    x2 += 14
  end
end

-- ======================================================================
-- background: static starfield + stage floor (from gfx_gen g_bg)
-- ======================================================================
function draw_background()
  g_bg()
end

-- ======================================================================
-- curtain state machine (open/close) — driven by cur_anim + cur_dc
-- ======================================================================
function update_curtains()
  if cur_dc > 0 then
    cur_dc -= 1
    local p = ease(E_OUTIN, cur_dc / 100.0)
    cur_amount = 62 * p
    if cur_anim ~= 1 then
      cur_amount = 62 - cur_amount
    end
    cur_vis = 1
  else
    if cur_anim == 1 then
      cur_amount = 0
      cur_vis = 0
    else
      cur_amount = 62
      cur_vis = 1
    end
  end
end

-- ======================================================================
-- main callbacks
-- ======================================================================
function _init()
  -- baked-in bests (no cartdata persistence yet — see PORT_NOTES.md)
  best_score = 0
  best_time = 0
  cur_anim = 0
  cur_amount = 62.0
  cur_vis = 1
  cur_dc = 0
  fill_glyphs()
  show_title_screen(1)
  scr_x[1] = 63
  scr_slide[1] = 0
  scr_act[1] = 0
  scr_fua[1] = 60
end

-- title glyph masks: J U S T O N E B (5 rows each, 3-bit L/M/R)
function fill_glyphs()
  set_glyph(1, 1, 1, 1, 5, 7)   -- J
  set_glyph(2, 5, 5, 5, 5, 7)   -- U
  set_glyph(3, 7, 4, 7, 1, 7)   -- S
  set_glyph(4, 7, 2, 2, 2, 2)   -- T
  set_glyph(5, 7, 5, 5, 5, 7)   -- O
  set_glyph(6, 5, 7, 7, 7, 5)   -- N
  set_glyph(7, 7, 4, 7, 4, 7)   -- E
  set_glyph(8, 7, 5, 7, 5, 7)   -- B
end

function set_glyph(ch, a, b, c, d, e)
  local i = (ch - 1) * 5
  glyph[i + 1] = a
  glyph[i + 2] = b
  glyph[i + 3] = c
  glyph[i + 4] = d
  glyph[i + 5] = e
end

function _update()
  -- cls first: its DMA overlaps the frame's logic (per SDK guidance)
  cls(0)

  update_audio()

  if freeze_frames > 0 then
    freeze_frames -= 1
    if (palive == 1) check_inputs()
    return
  end

  if scene_frame % 30 == 0 and is_paused == 0 and boss_phase > 0 then
    timer_seconds = min(5999, timer_seconds + 1)
  end
  if (shake_frames > 0) shake_frames -= 1
  scene_frame += 1
  rainbow_color = (scene_frame \ 4) % 6 + 8
  if (rainbow_color == 13) rainbow_color = 14
  if (bh_rainbow > 0) bh_rainbow -= 1
  if (bdc > 0) bdc -= 1

  -- staging / cinematics
  start_game_step()
  update_curtains()
  update_screens()

  if is_paused == 0 then
    -- boss scripts (green mirror / mirror 2 deferred in this slice)
    rot_step_main()
    sub_step(1)
    hand_step(LH)
    hand_step(RH)
    -- actor movement + idle bob (main mirror actors 1..3 only in this slice)
    local i = 1
    while i <= 3 do
      mv_step(i)
      if avis[i] == 1 then
        local nn = 2
        if (i ~= BB) nn = 4
        idle_step(i, bfa, nn)
      end
      i += 1
    end
    bfa += 1

    if palive == 1 then
      update_player()
    end
    update_tiles()
    update_cards()
  end

  -- always-on effects + cinematics
  update_parts()
  update_poofs()
  victory_step()
  update_health_ui()
end

-- player-health UI hurt/gain flash (slide/figment drift deferred)
function update_health_ui()
  if ph_dc > 0 then
    ph_dc -= 1
    if (ph_dc <= 0) ph_anim = 0
  end
end

function _draw()
  -- screen shake via camera offset (deterministic jitter from scene_frame so
  -- the only rnd_int caller stays the update path — keeps it out of the
  -- shared/fixed bank; see PORT_NOTES.md "bank budget").
  if shake_frames > 0 then
    camera(scene_frame % 5 - 2, (scene_frame \ 2) % 5 - 2)
  else
    camera(0, 0)
  end

  draw_background()

  if game_on == 1 or boss_on == 1 then
    draw_entities()
    -- boss behind hazards (green mirror deferred in this slice)
    if boss_on == 1 then
      draw_mirror(1)
    end
    draw_player()
    draw_hazards_top()
    draw_hud()
  end

  draw_screens()
  draw_curtains()
  camera(0, 0)
end

