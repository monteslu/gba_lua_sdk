-- hwtest: exercise the new hardware verbs (save/load, timer, hgradient).
local sky = array(160)   -- per-scanline backdrop colors
local st  = array8(8)    -- persisted game state
local hi  = 0
local lastticks = 0

function _init()
  -- build a top->bottom blue gradient into the backdrop table (raw BGR555).
  for y=0,159 do
    local b = flr(8 + y/8)          -- blue ramp
    if b > 31 then b = 31 end
    sky[y] = b * 1024               -- BGR555: blue is bits 10..14
  end
  hgradient(sky)                    -- install the per-line gradient

  -- restore persisted hi-score if present, else start fresh.
  -- (gba-lua arrays are 1-indexed, PICO-8 style: st[1] is the first byte.)
  if load(0, st, 8) > 0 then
    hi = st[1] + st[2]*256
  else
    hi = 0
  end
end

local frames = 0
function _update()
  frames = frames + 1
  -- profile a trivial loop with the free timer (sub-frame).
  timer_start()
  local s = 0
  for i=0,3999 do s = s + i*3 end   -- enough work to move the ~16 kHz timer
  lastticks = timer_read()          -- ticks the loop took (global so it's "used")

  -- bump + persist a running counter every 60 frames.
  if frames % 60 == 0 then
    hi = hi + 1
    st[1] = hi % 256
    st[2] = (hi \ 256) % 256         -- integer divide (\) — plain byte, no fixed-point
    save(0, st, 8)
  end

  if frames > 300 then run() end    -- restart to prove load() reads back
end

function _draw()
  cls(0)
  print("hwtest", 8, 8, 7)
  print("hi", 8, 20, 11)
  print(hi, 40, 20, 11)
  print("f", 8, 32, 6)
  print(frames, 40, 32, 6)
  print("t", 8, 44, 9)
  print(lastticks, 40, 44, 9)
end
