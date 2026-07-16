-- showcase: a scene-cycling tour of the gbalua feature set.
-- Press L / R (shoulder buttons) to change scenes. The scene name is at the top.

local scene = 0
local nscenes = 6
local t2 = 0

-- data used by some scenes (arrays are 1-indexed: index 1..N)
local plasma_started = 0
local abg_started = 0
local m7_started = 0
local last_switch = 0
local tiles = array8(2 * 64)   -- 2 affine-BG tiles (8bpp, 64 bytes each)
local amap  = array8(16 * 16)  -- 16x16 affine map
local apal  = array(256)       -- affine-BG palette (BGR555)

function _init()
  -- build the affine-BG assets once: two solid tiles + a checker map + palette.
  for i = 1, 64   do tiles[i] = 1 end
  for i = 65, 128 do tiles[i] = 2 end
  apal[2] = rgb15(255, 70, 70)     -- palette index 1
  apal[3] = rgb15(70, 130, 255)    -- palette index 2
  for r = 0, 15 do
    for c = 0, 15 do
      amap[r * 16 + c + 1] = (r + c) % 2
    end
  end
end

function _update60()
  t2 = t2 + 1
  -- auto-advance every ~4 real seconds (realframes ticks at a true 60 Hz in a
  -- VCOUNT IRQ, so the pace is steady even in the slow 16-bit plasma scene where
  -- the game loop itself runs below 60 fps). L / R also step manually.
  if realframes() - last_switch > 240 then next_scene() end
  if btnp(6) then scene = (scene + nscenes - 1) % nscenes  changed() end   -- L
  if btnp(7) then next_scene() end                                        -- R
end

function next_scene()
  scene = (scene + 1) % nscenes
  changed()
end

-- on a scene change, clear every mode's "entered" flag so the new scene re-inits
-- its display (each special scene sets up its mode once on entry).
function changed()
  last_switch = realframes()
  m7_started = 0
  abg_started = 0
  plasma_started = 0
end

function _draw()
  -- scenes that use non-bitmap modes (mode7/affine-bg/16-bit) manage the display
  -- themselves; the bitmap scenes cls() first.
  if scene == 0 then s_shapes()
  elseif scene == 1 then s_sprites()
  elseif scene == 2 then s_effects()
  elseif scene == 3 then s_mode7()
  elseif scene == 4 then s_abg()
  elseif scene == 5 then s_plasma()
  end
  hud()
end

function hud()
  -- a small label per scene (bitmap/tile scenes only; 16-bit scene draws its own)
  if scene == 5 then return end
  print("L/R:", 4, 4, 6)
  print(scene, 34, 4, 10)
end

-- 0: bitmap shapes + clip + a pulsing whole-screen fade -----------------------
function s_shapes()
  reset_display()
  cls(1)
  circfill(48, 88, 20, 8)
  circ(48, 88, 26, 10)
  rectfill(88, 68, 140, 108, 12)
  rect(88, 68, 140, 108, 7)
  line(16, 30, 224, 40, 11)
  -- clip a region and flood it with rings (proves clipping)
  clip(150, 58, 60, 60)
  for i = 0, 30 do circ(180, 88, i * 2, 9) end
  clip()
  rect(150, 58, 209, 117, 14)
  print("shapes+clip+fade", 60, 140, 7)
  -- gentle fade pulse
  local f = (sin(t2 / 130) + 1) / 5
  fade(f, 0)
end

-- 1: hardware sprites — affine rotate/scale, mosaic, flip -----------------------
function s_sprites()
  reset_display()
  cls(0)
  print("affine sprites", 66, 140, 7)
  -- a spinning + pulsing rotated sprite (sprr)
  local ang = t2 / 200
  local sc  = 1 + sin(t2 / 90) * 0.5
  sprr(0, 70, 74, ang, sc)
  -- a squash/stretch sprite (sprr2)
  sprr2(0, 170, 74, -ang, 1 + sin(t2 / 60) * 0.6, 1 - sin(t2 / 60) * 0.4)
  -- a mosaic'd plain sprite in the middle
  mosaic(flr((sin(t2 / 100) + 1) * 4))
  spr_mosaic(1)
  spr(0, 112, 60, 2, 2)
  spr_mosaic(0)
  mosaic(0)
end

-- 2: color effects — blend + fade to white + backdrop --------------------------
function s_effects()
  reset_display()
  cls(2)
  circfill(120, 80, 50, 12)
  rectfill(40, 50, 90, 110, 8)
  rectfill(150, 50, 200, 110, 11)
  print("blend + fade", 72, 140, 7)
  -- a couple of translucent sprites over the shapes
  spr_blend()
  sprr(0, 80 + sin(t2 / 70) * 40, 80, t2 / 300, 1.5)
  spr_blend()
  sprr(0, 160 + cos(t2 / 70) * 40, 80, -t2 / 300, 1.5)
  spr_blend_off()
  -- flash to white now and then
  local s = sin(t2 / 40)
  local f = 0
  if s > 0.7 then f = s - 0.7 end
  fade(f, 1)
end

-- 3: Mode 7 affine plane (bundled --mode7 asset) -------------------------------
function s_mode7()
  if m7_started == 0 then
    blend_off()
    if abg_started == 1 then abg_off() abg_started = 0 end
    mode7()                        -- once, on entry
    m7_started = 1
  end
  mode7_cam(t2 * 2, t2, t2 / 400, 1 + sin(t2 / 120) * 0.4)
end

-- 4: a second affine BG of our own tiles (spinning checkerboard) ---------------
function s_abg()
  if abg_started == 0 then
    blend_off()
    mode7_off()                    -- once, on entry (it clears BG2 — don't repeat)
    abg_setup(tiles, 2, amap, 16, apal)
    abg_started = 1
  end
  abg_cam(64, 64, t2 / 300, 1 + sin(t2 / 100) * 0.5)
end

-- 5: 16-bit true-color plasma --------------------------------------------------
function s_plasma()
  if plasma_started == 0 then
    blend_off()
    mode7_off()
    abg_off()                      -- unconditional: BG2 affine must be off in Mode 5
    mode15()
    plasma_started = 1
  end
  -- a cheap animated plasma: one color per 8x8 block via fillrect15 (the fast
  -- 16-bit fill), fully redrawn each frame. Coarse blocks keep it near 60fps so
  -- the scene stays responsive — a fine plasma from Lua would blow the budget.
  local ph = t2 * 3
  local y = 0
  while y < 128 do
    local x = 0
    while x < 160 do
      local r = 128 + sin((x + ph) / 40) * 127
      local g = 128 + sin((y - ph) / 50) * 127
      local b = 128 + sin((x + y) / 60) * 127
      fillrect15(x, y, 8, 8, rgb15(r, g, b))
      x = x + 8
    end
    y = y + 8
  end
  flip15()
end

-- return from a non-bitmap mode (mode7/abg/16-bit) back to the Mode-4 bitmap.
-- cls() (called next by every bitmap scene) restores Mode 4 + clears the 16-bit
-- flag; here we just disable the extra affine layers and any lingering blend/fade.
function reset_display()
  abg_off()
  mode7_off()
  blend_off()
end
