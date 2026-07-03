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
