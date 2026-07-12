-- mathcheck: computes known 16.16 fixed-point results at runtime into
-- module variables; the test harness reads them back out of RAM.
-- Inputs live in variables so the compiler can't constant-fold the math.

local in3 = 3
local in2 = 2
local inm9 = -9
local inm23 = -2.3
local quarter = 0.25
local in16 = 16
local none = 1
local ntwo = 1

local r_div = 0.0      -- 3/2          -> 1.5      (0x00018000)
local r_flr = 0        -- flr(-2.3)    -> -3
local r_sin = 0.0      -- sin(0.25)    -> -1.0     (0xFFFF0000)
local r_bslash = 0     -- -9 \ 2       -> -5
local r_mod = 0        -- -9 % 2       -> 1  (floored, sign of divisor)
local r_mid = 0        -- mid(0,200,127) -> 127
local r_sqrt = 0.0     -- sqrt(16)     -> 4.0
local r_atan = 0.0     -- atan2(1,1)   -> 0.875    (0x0000E000)
local r_cos = 0.0      -- cos(0.5)     -> -1.0
local r_div0 = 0.0     -- 1/0          -> 32767.99998 (0x7FFFFFFF)
local r_wrap = 0       -- 300*300      -> 24464 (16-bit wrap, P8-identical)

function _init()
  none = 1
  ntwo = 0
  r_div = in3 / in2
  r_flr = flr(inm23)
  r_sin = sin(quarter)
  r_bslash = inm9 \ in2
  r_mod = inm9 % in2
  r_mid = mid(0, 200, 127)
  r_sqrt = sqrt(in16)
  r_atan = atan2(none, none)
  r_cos = cos(quarter * in2)
  r_div0 = none / ntwo
  r_wrap = in3 * 100 * in3 * 100
end

function _update60()
end

function _draw()
  cls(3)
end
