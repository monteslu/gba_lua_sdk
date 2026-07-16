-- hello: the smallest real GBA game - no assets, just code.
-- The screen is 240x160. cls clears it; the shapes draw a smiley on top.
-- Colors are PICO-8-style indices 0-15 (0 black, 1 dark-blue, 10 yellow, 14 pink).

function _draw()
  cls(1)                                -- dark blue background

  -- a smiley face, drawn entirely with shapes (no sprite sheet needed)
  circfill(120, 88, 38, 10)             -- head: a big yellow circle
  rectfill(106, 78, 113, 88, 0)         -- left eye: a black square
  rectfill(127, 78, 134, 88, 0)         -- right eye
  circfill(120, 100, 12, 0)             -- mouth: a black circle
end
