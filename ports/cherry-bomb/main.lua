-- cherry bomb — gametank port
-- Adapted from "Cherry Bomb" by Krystman / Lazy Devs Academy
-- (lexaloffle.com/bbs/?tid=48986), licensed CC-BY-NC-SA 4.0.
-- This hand-translation to gtlua (real logic, real sprite sheet) is
-- released under the same license: CC-BY-NC-SA 4.0.
-- See PORT_NOTES.md for every divergence from the original cart.
--
-- d-pad move, ❎ (GT B) shoot, 🅾️ (GT A) cherry bomb.
-- Build: node bin/gtlua.js build ports/cherry-bomb/main.lua \
--          --sheet carts/cherrybomb-extract/gfx.bin
--
-- Positions/velocities live in 1/16-pixel ints (v\16 = pixel): the
-- 65C02 does 16-bit int math ~4x cheaper (cycles AND code bytes) than
-- 16.16 fixed, and 1/16 px is below anything visible on a 128x128
-- screen. Trig stays real 16.16 (sin/cos/atan2), floored into 16ths.

-- PERF: the enemy sway sines (green sin(t/45), red sin(t/20)) used to run
-- gt_fsin + a fixed multiply PER ENEMY PER FRAME (~4k cycles each). The
-- outputs are floored to 1/16-px ints, so a per-period lookup table built at
-- init with the SAME formula is value-identical; swayg/swayr are wrap
-- counters advanced once per tick (no modulo). See docs/performance.md.
local sway45 = array(45)
local sway20 = array(20)
local swayg = 0
local swayr = 0

-- modes (original uses strings)
local MSTART = 0
local MGAME = 1
local MWAVETEXT = 2
local MOVER = 3
local MWIN = 4
local MLOGO = 5

-- enemy missions (original uses strings)
local MI_FLYIN = 0
local MI_PROTEC = 1
local MI_ATTAC = 2
local MI_B1 = 3
local MI_B2 = 4
local MI_B3 = 5
local MI_B4 = 6
local MI_B5 = 7

local mode = 5            -- boot into the logo intro
local logot = 0
local tick = 0            -- original's global t
local blinkt = 1
local lockout = 0
local shake = 0
local flash = 0
local peekerx = 64
local highscore = 0       -- TODO cartdata("cherrybomb") / dget(0)

local wave = 0
local lastwave = 9
local wavetime = 0

local shipx = 60          -- ship position in whole pixels
local shipy = 90
local shipsx = 0
local shipsy = 0
local shipspr = 2
local flamespr = 5
local bultimer = 0
local muzzle = 0
local score = 0
local cher = 0
local lives = 4
local invul = 0
local attacfreq = 60
local firefreq = 20
local nextfire = 0
local btnreleased = 0

-- boss scratch registers (bossrun works on the one boss via globals,
-- since pool fields are only reachable through the all() loop variable)
local eb_x = 0
local eb_y = 0
local eb_sx = 0
local eb_sy = 0
local eb_sub = 0
local eb_phb = 0
local eb_mission = 0
local eb_shake = 0
local eb_flash = 0
local eb_die = 0

-- The 100-star parallax field lives in the SDK (gt.starfield_*): moving and
-- drawing the whole field in one tight C loop each, instead of ~1000 cycles
-- of cc65 call overhead PER star from here every frame. That single change is
-- what makes this bullet-hell port hit its frame budget.

local banim = array(18)   -- blink() color ramp
local bossoff = array(4)  -- boss ani frame offsets {0,4,8,4}

-- entity pools (original uses unbounded tables; capacities documented
-- in PORT_NOTES.md — overflowing add()s drop silently)
local enemies = pool(40, "type,wait,anispd,mission,flash,shake,subphase,cel,cw,ch")
local buls = pool(28, "spr,dmg,colw")
local ebuls = pool(48, "af")
local parts = pool(56, "age,size2,maxage,blue,spark")
local shwaves = pool(12, "r,tr,col,speed")
local pickups = pool(8)
local floats = pool(8)
local hpairs = array8(64)   -- enemy x bullet overlap pairs (asm hit scan)

-->8
-- tools


function blink()
 if blinkt>18 then
  blinkt=1
 end
 return banim[blinkt]
end

-- aabb overlap in whole pixels (the original col(a,b)); returns 0/1
function col(ax,ay,aw,ah,bx,by,bw,bh)
 if ay>by+bh-1 then return 0 end
 if by>ay+ah-1 then return 0 end
 if ax>bx+bw-1 then return 0 end
 if bx>ax+aw-1 then return 0 end
 return 1
end

-- enemy hitbox from type
function ecw(tp)
 if tp==4 then return 16 end
 if tp==5 then return 32 end
 return 8
end

function ech(tp)
 if tp==4 then return 16 end
 if tp==5 then return 24 end
 return 8
end

-- one particle. px/py pixels; vx/vy 16ths; size2 half-pixels
function addpart(px,py,vx,vy,age,size2,maxage,blue,spark)
 add(parts,{x=px*16,y=py*16,sx=vx,sy=vy,age=age,size2=size2,maxage=maxage,blue=blue,spark=spark})
end

-- Explosion spawn budget: a multi-kill volley used to fire up to 4
-- explosions in ONE frame = ~1000 random rolls + pool adds = the measured
-- kill hitch. The flash blob and shockwave land instantly; the particle
-- swarm drains from a pending queue at PEX_BUDGET particles per frame, so
-- a cloud builds over 2-3 frames — invisible at 30fps, and the effect
-- parameters are unchanged per particle.
local pend = pool(6, "blue,big,fleft,sleft")   -- x, y, blue, big, fleft, sleft

function pump_explosions()
 -- the original spawned a whole burst instantly into the 56-slot pool, so
 -- overlapping explosions DROPPED most of their particles. Match that:
 -- once the pool is crowded, pending bursts forfeit their remainder —
 -- same look, and the alive-particle ceiling stays where it always was.
 if #parts >= 44 then
  for q in all(pend) do del(pend,q) end
  return
 end
 local budget = 16
 for q in all(pend) do
  if budget <= 0 then return end
  -- one spawn body; ranges depend on big/spark phase (same values the
  -- original immediate loops used)
  local ab = 10
  if (q.big == 1) ab = 20
  while budget > 0 and (q.fleft > 0 or q.sleft > 0) do
   local vs = 96
   local sz = 8
   local sp = 0
   if q.fleft > 0 then
    if (q.big == 1) vs = 192
    if (q.big == 1) sz = 12
    q.fleft -= 1
   else
    vs = 160
    if (q.big == 1) vs = 480
    sp = 1
    q.sleft -= 1
   end
   addpart(q.x,q.y,flr(rnd(vs))-vs\2,flr(rnd(vs))-vs\2,flr(rnd(2)),2+flr(rnd(sz)),ab+flr(rnd(ab)),q.blue,sp)
   budget -= 1
  end
  if q.fleft <= 0 and q.sleft <= 0 then del(pend,q) end
 end
end

function explode(expx,expy,isblue)
 addpart(expx,expy,0,0,0,20,0,isblue,0)
 big_shwave(expx,expy)
 add(pend,{x=expx,y=expy,blue=isblue,big=0,fleft=30,sleft=20})
end

function bigexplode(expx,expy)
 addpart(expx,expy,0,0,0,50,0,0,0)
 big_shwave(expx,expy)
 add(pend,{x=expx,y=expy,blue=0,big=1,fleft=60,sleft=100})
end

function smol_spark(sx2,sy2)
 -- original: sx=(rnd()-0.5)*8, sy=(rnd()-1)*3
 addpart(sx2,sy2,flr(rnd(128))-64,flr(rnd(48))-48,flr(rnd(2)),2+flr(rnd(8)),10+flr(rnd(10)),0,1)
end

-- Particle discs baked into free sheet cells: a circfill per fireball
-- particle per frame is ~9 queue entries + Bresenham each, and an
-- explosion keeps ~30 alive for 150 frames (the measured 8-9 vsync
-- plateau). A baked disc blits as ONE sprite. r0..3 covers explode()'s
-- whole swarm; r>=4 (bigexplode tails, central blobs) keeps circfill.
-- Ramp indices 1..6 = red ramp {7,10,9,8,2,5}, 7..10 = blue-only {6,12,13,1}
-- (age<=5 is white=index 1 in both ramps).
local dcell = array(40)
local rampc = array(10)

function bake_disc(cell, r, c)
 local bx=(cell%16)*8
 local by=(cell\16)*8
 local yy=0
 while yy<8 do
  local xx=0
  while xx<8 do
   sset(bx+xx,by+yy,0)
   xx+=1
  end
  yy+=1
 end
 local dy=-r
 while dy<=r do
  local w=flr(sqrt(r*r-dy*dy))
  local xx=-w
  while xx<=w do
   sset(bx+3+xx,by+3+dy,c)
   xx+=1
  end
  dy+=1
 end
end

function bake_particle_discs()
 -- 40 verified-empty cells of gfx.bin (kept away from 250/251, the
 -- pickup outline cells)
 dcell[1]=49 dcell[2]=50 dcell[3]=51 dcell[4]=52
 dcell[5]=53 dcell[6]=54 dcell[7]=55 dcell[8]=56
 dcell[9]=57 dcell[10]=64 dcell[11]=65 dcell[12]=66
 dcell[13]=67 dcell[14]=68 dcell[15]=69 dcell[16]=70
 dcell[17]=71 dcell[18]=72 dcell[19]=73 dcell[20]=199
 dcell[21]=200 dcell[22]=201 dcell[23]=202 dcell[24]=203
 dcell[25]=204 dcell[26]=205 dcell[27]=206 dcell[28]=207
 dcell[29]=18 dcell[30]=19 dcell[31]=20 dcell[32]=25
 dcell[33]=35 dcell[34]=36 dcell[35]=39 dcell[36]=40
 dcell[37]=41 dcell[38]=146 dcell[39]=147 dcell[40]=150
 rampc[1]=7 rampc[2]=10 rampc[3]=9 rampc[4]=8 rampc[5]=2 rampc[6]=5
 rampc[7]=6 rampc[8]=12 rampc[9]=13 rampc[10]=1
 local n=1
 for ci=1,10 do
  for r=0,3 do
   bake_disc(dcell[n], r, rampc[ci])
   n+=1
  end
 end
end

-- sfx gates: a multi-kill retriggers the explosion voice mid-envelope
-- (audible clicks) and held fire chatters the hit blip nonstop. One boom
-- per 5 ticks, one hit blip per 6, is what the ear resolves anyway.
local boom_t = 0
-- converted PICO-8 sfx (bin/p8sfx.mjs from carts/cherrybomb-extract):
-- the cart's real __sfx__ pitches/timing, triggered by ORIGINAL ids
-- (+ every effect the __music__ patterns reference)
local p8sfx = hexdata("33670080009100a400a700d400ff00320165019601b301d001e101f20103021c02310240024f027802bb02c002e90214033f036803ab03b603df0320042d043e0455045a0481048804c304ce04d90412051f052a05370544054f055c0567057e05c10504062d06000b2454014f01490144013c01370125012e012a01280125010307292b01250120011d011b011801170103083356011b0119011702000115020002150100000000155b25023a033d033a033d0325023a033d033a033d033f08000b25033a033d033a033d0225033a033d033f1400144144024103440341034403410244034103460e000b490346034903460349024103490346033d034b1104183d3d02440346033f0344033d02440346033f0344034608000b3a03440349033f0349023d03490346033f034b0246034b0c00185b430f3f07410f4408430f3f073e083f074108430f3f07410f440843073f083e073f08410743084b0f4907470f4608440f00175a330f2e0733083f073a083f0f3a07330f2e08330f2e0729082e073208330f3a073f0f3a083b0f3607330f3608340f000d5b4207400f3b0842073f0844074108460742084707440840074a0f000d5b3b07380f34083b072f083d0731083f0733084007340828073a0f00073600183f0600063f0641064206441300073100184306000643064506460648130007360018460600064606480649064b13000b294f434d084f0750084f164a174b164f174e164b17440f00093644074c0f50084e164b1750074e084d07520f00066242070007420741073f073e150006533f0700073f073e073c073b1500135b4d05000b4d0c00054b0600114b0500114b0600064e05000b4e0c00054d0600114d050011480607201b38053d06440538063d06440538063d06440538063d05440638063d05440638063d05440638053d06440638053d06440638053d06440538063d06440538063c0604015b25b400135b3d05000b3d0c00053c0600113c0500113c0600063f05000b3f0c00053d0600113d0500113c060014534d05000b4d0c00054b06001c480649054b0600064e05000b5106500600054d06001c480649054d060014533d05000b3d0c00053c06001c38063a053c0600063f05000b4206410600053d06001c38063a053d0600135b5005000b4e064d060005520600114b050011520600065405000b520651060005540600114d0507201b38053d06440538063d0644053a063d063a053c063d053a063c063d053a063c063f0542063c053f0642063c053f0642063c053f0641053c063f0641053c063f0604045b252d272d2a2d292d00135b4105000b3f063d060005420600113a050011420600064205000b41063f060005410600113c05001f435c02590257035502530251034f024d024b034a02470246034502420241033e023c023b033902380236033402320231032f022d022b03290227022503240507053c000135012d012c012b0200075837053b064005440646064d055506000a5e2b04300533053a043c05430546044b05570960050701302b0503124c2c012d0230012e022a0129012701260124011f0122012001190117011b011702160315080402582c013601031c4d32012a0232022502300229022d0228022b012a02280227022602250223022202210120041f021e021d021b041a0119021802170416021504070424302533263425382607042429252c262d253126031b232f0429052a050004230a2a04000529092a05000523092a0528052f0429052a050004230a2a04000529052f042a05000523092a052805070524262a0004261d27252b2607042426252e26292527260505242d2532262e2524132513050524292532262e2524132513050424312529263525272605052439383709390a3a253d260504243e2541263d253a26050a243d25352641253c053d043e054105450449054a0a05201241043e05450546044d054a055104520541053e04450546053504320539053a0541043e05450546044d054a055104520541053e04450546053504320539053a050520124d044a0551055204590556055d045e054d054a045105520541043e05450546053504320539053a0441053e05450446053505320439053a05290426052d052e05031324001229050009280500092a050005290423052a050005240e0004240e00181d04230529052e05041d3a3701490155025c013f025f0260023a014d025d015901560251014c02460140013a0237014102320131012e022d012c022a012901280227042502")
local p8music = hexdata("1704040506ff000708ffff04090affff040b0c0dff000e08ffff040f0affff041011ffff011213141500161314170218191a1b002425ffff01262728ff00262829ff0026272aff00262a2bff0026272cff0026292dff0026272cff00262a2eff0028292fff00282930ff00272b2fff02252431ff")

local hitsfx_t = 0

function boom_sfx()
 if tick - boom_t >= 5 then
  boom_t = tick
  sfx(2, 1)                       -- boss death-throes rumble
 end
end

function hit_sfx()
 if tick - hitsfx_t >= 6 then
  hitsfx_t = tick
  sfx(34, 3)                      -- enemy hit tick
 end
end

function page_red(page)
 local c=7
 if page>5 then c=10 end
 if page>7 then c=9 end
 if page>10 then c=8 end
 if page>12 then c=2 end
 if page>15 then c=5 end
 return c
end

function page_blue(page)
 local c=7
 if page>5 then c=6 end
 if page>7 then c=12 end
 if page>10 then c=13 end
 if page>12 then c=1 end
 return c
end

-- shockwaves: x/y pixels, radius in half-pixels
function smol_shwave(shx,shy,shcol)
 add(shwaves,{x=shx,y=shy,r=6,tr=12,col=shcol,speed=2})
end

function big_shwave(shx,shy)
 add(shwaves,{x=shx,y=shy,r=6,tr=50,col=7,speed=7})
end

function doshake()
 local sk=flr(shake)
 camera(flr(rnd(sk))-sk\2,flr(rnd(sk))-sk\2)
 if shake>10 then
  shake=(shake*9)\10
 else
  shake-=1
  if shake<1 then
   shake=0
  end
 end
end

-- kind 0: score float (val followed by "00"); kind 1: "1up!"
function popfloat(val,kind,flx,fly)
 add(floats,{x=flx,y=fly*16,val=val,kind=kind,age=0})
end

-- digit count, for centering printed numbers
function ndig(v)
 if v<10 then return 1 end
 if v<100 then return 2 end
 if v<1000 then return 3 end
 if v<10000 then return 4 end
 return 5
end

-- print "<v>00" (the original's makescore(v)) at x, returns right edge
function pscore(v,x,y,c)
 if v==0 then
  return print(0,x,y,c)
 end
 local rx=print(v,x,y,c)
 return print("00",rx,y,c)
end

-- centered "<v>00"
function cscore(v,cx,y,c)
 local w=ndig(v)+2
 if v==0 then w=1 end
 return pscore(v,cx-w*2,y,c)
end

function etscore(tp)
 if tp==2 then return 2 end
 if tp==3 then return 3 end
 if tp==4 then return 5 end
 return 1
end

-->8
-- silhouettes: the original flashes enemies/pickup outlines white via
-- pal() sprite tinting, which the blitter can't do (framebuffer bytes
-- ARE colors). At boot we stamp white/pink silhouette copies of the
-- real art into free sheet cells (240+ / 49+) and blit those instead.
-- Masks generated from gfx.bin, two rows packed per int.

function silrow(x,y,bits,c)
 local i=0
 while i<8 do
  if (bits & 1)!=0 then
   sset(x+i,y,c)
  end
  bits=bits>>1
  i+=1
 end
end

function silcell(dx,dy,m01,m23,m45,m67,c)
 silrow(dx,dy,(m01>>>8)&255,c)
 silrow(dx,dy+1,m01&255,c)
 silrow(dx,dy+2,(m23>>>8)&255,c)
 silrow(dx,dy+3,m23&255,c)
 silrow(dx,dy+4,(m45>>>8)&255,c)
 silrow(dx,dy+5,m45&255,c)
 silrow(dx,dy+6,(m67>>>8)&255,c)
 silrow(dx,dy+7,m67&255,c)
end

function makesil()
 -- green alien frames 21-24 -> 240-243
 silcell(0,120,26367,-1,32316,23106,7)
 silcell(8,120,26367,-1,32316,23169,7)
 silcell(16,120,26367,-1,32316,23106,7)
 silcell(24,120,26367,-1,32316,23142,7)
 -- red flame guy 148-149 -> 244-245
 silcell(32,120,-32317,-1,-1,-190,7)
 silcell(40,120,17091,-1,-1,16896,7)
 -- spinner 184-187 -> 246-249
 silcell(48,120,15486,-1,-6297,26148,7)
 silcell(56,120,15420,32382,26220,11304,7)
 silcell(64,120,15420,15420,15420,6168,7)
 silcell(72,120,15420,32382,26166,13332,7)
 -- cherry pickup 48 -> white 250, pink 251
 silcell(80,120,30824,9316,-2321,28422,7)
 silcell(88,120,30824,9316,-2321,28422,14)
 -- yellow ship frame a (208,209/224,225) -> 49,50/65,66 (2x2)
 silcell(8,24,0,-3848,-1282,-258,7)
 silcell(16,24,0,3871,24447,32639,7)
 silcell(8,32,-258,-260,-6976,0,7)
 silcell(16,32,32639,32575,10019,0,7)
 -- yellow ship frame b (210,211/226,227) -> 51,52/67,68 (2x2)
 silcell(24,24,0,-7952,-1282,-258,7)
 silcell(32,24,0,1807,24447,32639,7)
 silcell(24,32,-258,-258,-7164,0,7)
 silcell(32,32,32639,32639,10016,8192,7)
end

-->8
-- bullets (enemy fire: positions in 16ths, spd16 = speed*16)

function fire(fx,fy,ang,spd16)
 sfx(29, 3)                     -- enemy shot
 add(ebuls,{x=fx,y=fy,sx=flr(sin(ang)*spd16),sy=flr(cos(ang)*spd16),af=0})
end

function firespread(fx,fy,num,spd16,base)
 local spc=1/num
 for i=1,num do
  fire(fx,fy,spc*i+base,spd16)
 end
end

function aimedfire(fx,fy,spd16)
 local ang=atan2((shipy+4)-fy\16,(shipx+4)-fx\16)
 fire(fx,fy,ang,spd16)
end

function cherbomb()
 local n2=cher*2
 local spc=0.25/n2
 for i=0,n2 do
  local ang=0.375+spc*i
  add(buls,{x=shipx*16,y=(shipy-3)*16,sx=flr(sin(ang)*64),sy=flr(cos(ang)*64),spr=17,dmg=3,colw=8})
 end
 big_shwave(shipx+3,shipy+3)
 shake=5
 muzzle=5
 invul=30
 flash=3
 sfx(33, 1)                     -- cherry bomb blast
end

-->8
-- pickups

function plogic(px2,py2)
 cher+=1
 smol_shwave(px2+4,py2+4,14)
 if cher>=10 then
  if lives<4 then
   lives+=1
   sfx(31, 2)                    -- extra life
   cher=0
   popfloat(0,1,px2+4,py2+4)
  else
   score+=50
   popfloat(50,0,px2+4,py2+4)
   sfx(30, 2)                    -- cherries banked for score
   cher=0
  end
 else
  -- TODO sfx(30)
 end
end

-- ship got hit (shared by enemy-contact and bullet-contact)
function hitship()
 explode(shipx+4,shipy+4,1)
 lives-=1
 sfx(1, 1)                      -- ship hit
 shake=12
 invul=60
 shipx=60
 shipy=100
 flash=3
end

-->8
-- waves and enemies

function spawnen(entype,enx,eny,enwait)
 -- original: x=enx*1.25-16, y=eny-66 (16ths: *20-256 is exact)
 local ex2=enx*20-256
 local ey2=(eny-66)*16
 local px4=enx
 local py4=eny
 local hp=3
 if entype==2 then
  hp=2
 elseif entype==3 then
  hp=4
 elseif entype==4 then
  hp=20
 elseif entype==5 then
  hp=130
  ex2=768
  ey2=-384
  px4=48
  py4=25
 end
 add(enemies,{x=ex2,y=ey2,sx=0,sy=0,posx=px4,posy=py4,type=entype,wait=enwait,anispd=6,aniframe=16,mission=MI_FLYIN,hp=hp,flash=0,shake=0,subphase=0,phbegin=0,cel=0,cw=ecw(entype),ch=ech(entype)})
end

-- one layout row (original placens()): hi/lo pack 5 cells each, base 6.
-- column k: x=k*12-6, wait=k*3
function prow(ry,hi,lo)
 local ey=4+ry*12
 local k=5
 while k>=1 do
  local c=hi%6
  hi\=6
  if c!=0 then spawnen(c,k*12-6,ey,k*3) end
  k-=1
 end
 k=10
 while k>=6 do
  local c=lo%6
  lo\=6
  if c!=0 then spawnen(c,k*12-6,ey,k*3) end
  k-=1
 end
end

function spawnwave()
 if wave<lastwave then
  sfx(28, 2)                    -- wave incoming
 else
  music(10)                     -- final-wave medley
 end
 if wave==1 then
  --space invaders
  attacfreq=60
  firefreq=20
  prow(1,259,1554)
  prow(2,259,1554)
  prow(3,259,1554)
  prow(4,259,1554)
 elseif wave==2 then
  --red tutorial
  attacfreq=60
  firefreq=20
  prow(1,1597,1807)
  prow(2,1597,1807)
  prow(3,1598,3103)
  prow(4,1598,3103)
 elseif wave==3 then
  --wall of red
  attacfreq=50
  firefreq=20
  prow(1,1597,1807)
  prow(2,1598,3103)
  prow(3,3110,3110)
  prow(4,3110,3110)
 elseif wave==4 then
  --spin tutorial
  attacfreq=50
  firefreq=15
  prow(1,4543,1533)
  prow(2,4543,1533)
  prow(3,4543,1533)
  prow(4,4543,1533)
 elseif wave==5 then
  --chess
  attacfreq=50
  firefreq=15
  prow(1,4220,2925)
  prow(2,1993,1783)
  prow(3,4220,2925)
  prow(4,1993,1783)
 elseif wave==6 then
  --yellow tutorial
  attacfreq=40
  firefreq=10
  prow(1,3100,86)
  prow(2,3024,14)
  prow(3,1519,1519)
  prow(4,1519,1519)
 elseif wave==7 then
  --double yellow
  attacfreq=40
  firefreq=10
  prow(1,4543,1533)
  prow(2,5198,3048)
  prow(3,13,1728)
  prow(4,1519,1519)
 elseif wave==8 then
  --hell
  attacfreq=30
  firefreq=10
  prow(1,43,1548)
  prow(2,4579,1569)
  prow(3,4622,3117)
  prow(4,4622,3117)
 elseif wave==9 then
  --boss
  attacfreq=60
  firefreq=20
  prow(1,5,0)
 end
end

function nextwave()
 wave+=1
 if wave>lastwave then
  mode=MWIN
  lockout=tick+30
  music(4)
 else
  if wave==1 then
   music(0)
  else
   music(3)
  end
  mode=MWAVETEXT
  wavetime=80
 end
end

-->8
-- behavior

function pickattac()
 local maxnum=min(10,#enemies)
 if maxnum<=0 then return end
 local target=#enemies-flr(rnd(maxnum))
 local i=0
 for e in all(enemies) do
  i+=1
  if i==target then
   if e.mission==MI_PROTEC then
    e.mission=MI_ATTAC
    e.anispd*=3
    e.wait=60
    e.shake=60
   end
  end
 end
end

function pickfire()
 local maxnum=min(10,#enemies)
 if maxnum<=0 then return end
 for e in all(enemies) do
  if e.type==4 and e.mission==MI_PROTEC then
   if rnd()<0.5 then
    firespread(e.x+112,e.y+208,12,21,rnd())
    e.flash=4
    return
   end
  end
 end
 local target=#enemies-flr(rnd(maxnum))
 local i=0
 for e in all(enemies) do
  i+=1
  if i==target then
   if e.mission==MI_PROTEC then
    if e.type==4 then
     firespread(e.x+112,e.y+208,12,21,rnd())
    elseif e.type==2 then
     aimedfire(e.x+48,e.y+96,32)
    else
     fire(e.x+48,e.y+96,0,32)
    end
    e.flash=4
   end
  end
 end
end

function picktimer()
 if mode!=MGAME then return end
 if tick>nextfire then
  pickfire()
  nextfire=tick+firefreq+flr(rnd(firefreq))
 end
 if tick%attacfreq==0 then
  pickattac()
 end
end

-->8
-- boss phases (on the eb_* scratch globals, 16ths)

function bossfire(ang,spd16)
 fire(eb_x+240,eb_y+368,ang,spd16)   -- muzzle at +15,+23 px
end

function bossrun()
 if eb_mission==MI_B1 then
  if eb_sx==0 or eb_x>=1488 then eb_sx=-32 end
  if eb_x<=48 then eb_sx=32 end
  if tick%30>3 then
   if tick%3==0 then bossfire(0,32) end
  end
  if eb_phb+240<tick then
   eb_mission=MI_B2
   eb_phb=tick
   eb_sub=1
  end
  eb_x+=eb_sx
  eb_y+=eb_sy
 elseif eb_mission==MI_B2 then
  if eb_sub==1 then
   eb_sx=-24
   if eb_x<=64 then eb_sub=2 end
  elseif eb_sub==2 then
   eb_sx=0
   eb_sy=24
   if eb_y>=1600 then eb_sub=3 end
  elseif eb_sub==3 then
   eb_sx=24
   eb_sy=0
   if eb_x>=1456 then eb_sub=4 end
  elseif eb_sub==4 then
   eb_sx=0
   eb_sy=-24
   if eb_y<=400 then
    eb_mission=MI_B3
    eb_phb=tick
    eb_sy=0
   end
  end
  if tick%15==0 then
   aimedfire(eb_x+240,eb_y+368,24)
  end
  eb_x+=eb_sx
  eb_y+=eb_sy
 elseif eb_mission==MI_B3 then
  if eb_sx==0 or eb_x>=1488 then eb_sx=-8 end
  if eb_x<=48 then eb_sx=8 end
  if tick%10==0 then
   firespread(eb_x+240,eb_y+368,8,32,time()/2)
  end
  if eb_phb+240<tick then
   eb_mission=MI_B4
   eb_sub=1
   eb_phb=tick
  end
  eb_x+=eb_sx
  eb_y+=eb_sy
 elseif eb_mission==MI_B4 then
  if eb_sub==1 then
   eb_sx=24
   if eb_x>=1456 then eb_sub=2 end
  elseif eb_sub==2 then
   eb_sx=0
   eb_sy=24
   if eb_y>=1600 then eb_sub=3 end
  elseif eb_sub==3 then
   eb_sx=-24
   eb_sy=0
   if eb_x<=64 then eb_sub=4 end
  elseif eb_sub==4 then
   eb_sx=0
   eb_sy=-24
   if eb_y<=400 then
    eb_mission=MI_B1
    eb_phb=tick
    eb_sy=0
   end
  end
  if tick%12==0 then
   if eb_sub==1 then bossfire(0,32)
   elseif eb_sub==2 then bossfire(0.25,32)
   elseif eb_sub==3 then bossfire(0.5,32)
   elseif eb_sub==4 then bossfire(0.75,32)
   end
  end
  eb_x+=eb_sx
  eb_y+=eb_sy
 elseif eb_mission==MI_B5 then
  -- dying
  eb_shake=10
  eb_flash=10
  if tick%8==0 then
   explode(eb_x\16+flr(rnd(32)),eb_y\16+flr(rnd(24)),0)
   boom_sfx()                    -- boss death throes (orig sfx 2)
   shake=2
  end
  if eb_phb+90<tick then
   if tick%4==2 then
    explode(eb_x\16+flr(rnd(32)),eb_y\16+flr(rnd(24)),0)
    -- TODO sfx(2)
    shake=2
   end
  end
  if eb_phb+180<tick then
   flash=3
   score+=100
   popfloat(100,0,eb_x\16+16,eb_y\16+6)
   bigexplode(eb_x\16+16,eb_y\16+12)
   shake=15
   eb_die=1
   boom_sfx()                    -- boss final blast (orig sfx 35)
  end
 end
end

-->8
-- game flow

function startscreen()
 gt.starfield_init(100)
 mode=MSTART
 music(7)
end

function startgame()
 tick=0
 wave=0
 nextwave()
 shipx=60
 shipy=90
 shipsx=0
 shipsy=0
 shipspr=2
 flamespr=5
 bultimer=0
 muzzle=0
 score=0
 cher=0
 lives=4
 invul=0
 attacfreq=60
 firefreq=20
 nextfire=0
 gt.starfield_init(100)
 for b in all(buls) do del(buls,b) end
 for eb in all(ebuls) do del(ebuls,eb) end
 for e in all(enemies) do del(enemies,e) end
 for p in all(parts) do del(parts,p) end
 for w in all(shwaves) do del(shwaves,w) end
 for p2 in all(pickups) do del(pickups,p2) end
 for f in all(floats) do del(floats,f) end
end

-->8
-- update

function update_game()
 pump_explosions()
 -- controls
 shipsx=0
 shipsy=0
 shipspr=2
 if btn(0) then
  shipsx=-2
  shipspr=1
 end
 if btn(1) then
  shipsx=2
  shipspr=3
 end
 if btn(2) then shipsy=-2 end
 if btn(3) then shipsy=2 end

 if btnp(4) then
  if cher>0 then
   cherbomb()
   cher=0
  else
   sfx(32, 2)                    -- empty-bomb click
  end
 end

 if btn(5) then
  if bultimer<=0 then
   add(buls,{x=(shipx+1)*16,y=(shipy-3)*16,sx=0,sy=-64,spr=16,dmg=1,colw=6})
   sfx(0, 0)                     -- player shot
   muzzle=5
   bultimer=4
  end
 end
 bultimer-=1

 -- moving the ship
 shipx+=shipsx
 shipy+=shipsy
 if shipx>120 then shipx=120 end
 if shipx<0 then shipx=0 end
 if shipy<0 then shipy=0 end
 if shipy>120 then shipy=120 end

 -- move the bullets/ebuls in bulk (asm pool integrate); the loops keep
 -- only their lifetime checks
 gt.pool_move(buls, 0)
 for b in all(buls) do
  if b.y<-128 then del(buls,b) end
 end

 gt.pool_move(ebuls, 0)
 for eb in all(ebuls) do
  eb.af+=1
  if eb.y>2048 or eb.x<-128 or eb.x>2048 or eb.y<-128 then
   del(ebuls,eb)
  end
 end

 -- move the pickups
 for p in all(pickups) do
  p.y+=12   -- 0.75 px
  if p.y>2048 then del(pickups,p) end
 end

 -- moving enemies (original doenemy(), inlined: pool fields are only
 -- reachable through the loop variable)
 for e in all(enemies) do
  if e.wait>0 then
   e.wait-=1
  else
   if e.mission==MI_FLYIN then
    -- easing: original /7; (d>>3)+(d>>6) = d*0.1406 ~ d/7.1
    local dx=e.posx*16-e.x
    local dy=e.posy*16-e.y
    dx=(dx>>3)+(dx>>6)
    dy=(dy>>3)+(dy>>6)
    if e.type==5 then dy=min(dy,16) end
    e.x+=dx
    e.y+=dy
    if abs(e.y-e.posy*16)<11 then   -- original tolerance 0.7 px
     e.y=e.posy*16
     e.x=e.posx*16
     if e.type==5 then
      sfx(50, 1)                 -- boss slam-in
      e.shake=20
      e.wait=28
      e.mission=MI_B1
      e.phbegin=tick
     else
      e.mission=MI_PROTEC
     end
    end
   elseif e.mission==MI_ATTAC then
    if e.type==1 then
     --green guy: sy=1.7, sway sin(t/45)
     e.sy=27
     e.sx=sway45[swayg+1]
     if e.x<512 then e.sx+=16-e.x\32 end
     if e.x>1408 then e.sx-=(e.x-1408)\32 end
    elseif e.type==2 then
     --red guy: sy=2.5, sway sin(t/20)
     e.sy=40
     e.sx=sway20[swayr+1]
     if e.x<512 then e.sx+=16-e.x\32 end
     if e.x>1408 then e.sx-=(e.x-1408)\32 end
    elseif e.type==3 then
     --spinny ship
     if e.sx==0 then
      e.sy=32
      if shipy*16<=e.y then
       e.sy=0
       if shipx*16<e.x then e.sx=-32 else e.sx=32 end
      end
     end
    elseif e.type==4 then
     --yellow ship: sy=0.35
     e.sy=6
     if e.y>1760 then
      e.sy=16
     else
      if tick%25==0 then
       firespread(e.x+112,e.y+208,8,21,rnd())
       e.flash=4
      end
     end
    end
    e.x+=e.sx
    e.y+=e.sy
   elseif e.mission>=MI_B1 then
    -- boss: run the phase machine on scratch globals, copy back
    eb_x=e.x
    eb_y=e.y
    eb_sx=e.sx
    eb_sy=e.sy
    eb_sub=e.subphase
    eb_phb=e.phbegin
    eb_mission=e.mission
    eb_shake=e.shake
    eb_flash=e.flash
    eb_die=0
    bossrun()
    e.x=eb_x
    e.y=eb_y
    e.sx=eb_sx
    e.sy=eb_sy
    e.subphase=eb_sub
    e.phbegin=eb_phb
    e.mission=eb_mission
    e.shake=eb_shake
    e.flash=eb_flash
    if eb_die==1 then del(enemies,e) end
   end
   -- MI_PROTEC: staying put
  end

  -- enemy animation (original animate(); frames in 16ths)
  e.aniframe+=e.anispd
  local alen=4
  if e.type==2 or e.type==4 then alen=2 end
  if e.aniframe\16>alen then e.aniframe=16 end

  -- enemy leaving screen
  if e.mission!=MI_FLYIN then
   if e.y>2048 or e.x<-128 or e.x>2048 then
    del(enemies,e)
   end
  end
 end

 -- collision enemy x bullets: geometry in asm (gt.hit_scan), the rare
 -- hit resolution here. Pairs are (enemy_ord, bullet_ord) live ordinals in
 -- all() order; only the first pair per enemy applies (the cart broke out
 -- of the bullet loop after a hit).
 gt.hit_scan(enemies, "cw", "ch", buls, "colw", 8, 4, hpairs)
 if hpairs[1] > 0 then
  local k = 1
  local si = 0
  for e in all(enemies) do
   si += 1
   if hpairs[k] == si then
    if e.mission != MI_B5 then
     local exp = e.x\16
     local eyp = e.y\16
     local bi = hpairs[k + 1]
     local bj = 0
     for b in all(buls) do
      bj += 1
      if bj == bi then
       smol_shwave(b.x\16 + 4, b.y\16 + 4, 9)
       del(buls, b)
       smol_spark(exp + 4, eyp + 4)
       if e.mission != MI_FLYIN then
        e.hp -= b.dmg
       end
       hit_sfx()
       if e.type == 5 then e.flash = 5 else e.flash = 2 end
       if e.hp <= 0 then
        -- killen(), inlined
        if e.type == 5 then
         e.mission = MI_B5
         e.phbegin = tick
         for eb in all(ebuls) do del(ebuls, eb) end
         boom_sfx()
        else
         del(enemies, e)
         boom_sfx()
         explode(exp + 4, eyp + 4, 0)
         local cherchance = 13
         local scoremult = 1
         if e.mission == MI_ATTAC then
          scoremult = 2
          if rnd() < 0.5 then pickattac() end
          cherchance = 26
         end
         score += etscore(e.type) * scoremult
         if scoremult != 1 then
          popfloat(etscore(e.type) * scoremult, 0, exp + 4, eyp + 4)
         end
         if flr(rnd(128)) < cherchance then
          add(pickups, {x = e.x, y = e.y})
         end
        end
       end
       break
      end
     end
    end
    -- consume every pair for this enemy (first applies, rest skip)
    k += 2
    while hpairs[k] == si do k += 2 end
    if (hpairs[k] == 0) break
   end
  end
 end

 -- collision ebuls x cherry-bomb bullets
 for b in all(buls) do
  if b.spr==17 then
   for eb in all(ebuls) do
    if col(eb.x\16,eb.y\16,2,2,b.x\16,b.y\16,b.colw,8)==1 then
     smol_shwave(eb.x\16,eb.y\16,8)
     del(ebuls,eb)
     score+=5
    end
   end
  end
 end

 -- collision ship x enemies (inlined: the 8-arg col() call was ~1200
 -- cycles per enemy per frame through the stack path)
 if invul<=0 then
  for e in all(enemies) do
   if e.mission!=MI_B5 then
    local exp=e.x\16
    local eyp=e.y\16
    if eyp<=shipy+7 and shipy<=eyp+e.ch-1 and exp<=shipx+7 and shipx<=exp+e.cw-1 then
     hitship()
    end
   end
  end
 else
  invul-=1
 end

 -- collision ship x ebuls
 if invul<=0 then
  for eb in all(ebuls) do
   local ebx2=eb.x\16
   local eby2=eb.y\16
   if eby2<=shipy+7 and shipy<=eby2+1 and ebx2<=shipx+7 and shipx<=ebx2+1 then
    hitship()
   end
  end
 end

 -- collision pickup x ship
 for p in all(pickups) do
  if col(p.x\16,p.y\16,8,8,shipx,shipy,8,8)==1 then
   plogic(p.x\16,p.y\16)
   del(pickups,p)
  end
 end

 if lives<=0 then
  mode=MOVER
  lockout=tick+30
  music(6)
  return
 end

 -- picking
 picktimer()

 -- animate flame
 flamespr+=1
 if flamespr>9 then flamespr=5 end

 -- animate muzzle flash
 if muzzle>0 then muzzle-=1 end

 if mode==MWAVETEXT then
  gt.starfield_move(2)
 else
  gt.starfield_move(1)
 end

 -- check if wave over
 if mode==MGAME and #enemies==0 then
  for eb in all(ebuls) do del(ebuls,eb) end
  nextwave()
 end
end

function update_start()
 gt.starfield_move(0)  -- title drift
 if not btn(4) and not btn(5) then
  btnreleased=1
 end
 if btnreleased==1 then
  if btnp(4) or btnp(5) then
   startgame()
   btnreleased=0
  end
 end
end

function update_over()
 if tick<lockout then return end
 if not btn(4) and not btn(5) then
  btnreleased=1
 end
 if btnreleased==1 then
  if btnp(4) or btnp(5) then
   if score>highscore then
    highscore=score
    -- TODO dset(0,score) (no cartdata yet: highscore is per-session)
   end
   startscreen()
   btnreleased=0
  end
 end
end

function update_win()
 if tick<lockout then return end
 if not btn(4) and not btn(5) then
  btnreleased=1
 end
 if btnreleased==1 then
  if btnp(4) or btnp(5) then
   if score>highscore then
    highscore=score
    -- TODO dset(0,score)
   end
   startscreen()
   btnreleased=0
  end
 end
end

function update_wavetext()
 update_game()
 wavetime-=1
 if wavetime<=0 then
  mode=MGAME
  spawnwave()
 end
end

function update_logo()
 logot+=1
 if logot>75 then
  startscreen()
 end
end

-->8
-- draw

function draw_game()
 gt.starfield_draw()

 if lives>0 then
  local vis=1
  if invul>0 then
   -- invul flicker (original: sin(t/5)<0.1)
   if sin(tick*0.2)>=0.1 then vis=0 end
  end
  if vis==1 then
   spr(shipspr,shipx,shipy)
   spr(flamespr,shipx,shipy+8)
  end
 end

 -- drawing pickups: flashing silhouette outline + cherry on top
 for p in all(pickups) do
  local oc=250
  if tick%4<2 then oc=251 end
  local px3=p.x\16
  local py3=p.y\16
  spr(oc,px3+1,py3)
  spr(oc,px3-1,py3)
  spr(oc,px3,py3+1)
  spr(oc,px3,py3-1)
  spr(48,px3,py3)
 end

 -- drawing enemies
 for e in all(enemies) do
  local f=e.aniframe\16
  local shaken=0
  local ex3=e.x\16
  if e.shake>0 then
   e.shake-=1
   if tick%4<2 then
    ex3+=1
    shaken=1
   end
  end
  local w=1
  local h=1
  local sn=21+f-1
  if e.type==2 then
   sn=148+f-1
  elseif e.type==3 then
   sn=184+f-1
  elseif e.type==4 then
   sn=208+(f-1)*2
   w=2
   h=2
  elseif e.type==5 then
   sn=84+bossoff[f]
   w=4
   h=3
  end
  if e.flash>0 then
   e.flash-=1
   if e.type==5 then
    sn=80   -- boss flash frame from the sheet
   elseif e.type==1 then
    sn=240+f-1
   elseif e.type==2 then
    sn=244+f-1
   elseif e.type==3 then
    sn=246+f-1
   else
    sn=49+(f-1)*2
   end
  end
  -- plain 8x8 enemies ride the bulk asm pass; multicell (type 4/5) and
  -- shake-nudged frames keep the direct call
  e.cel=0
  if w==1 and h==1 and sn<=255 and shaken==0 then
   e.cel=sn
  else
   spr(sn,ex3,e.y\16,w,h)
  end
 end
 gt.pool_sprs(enemies, "cel")

 -- drawing bullets
 for b in all(buls) do
  spr(b.spr,b.x\16,b.y\16)
 end

 if muzzle>0 then
  circfill(shipx+3,shipy-2,muzzle,7)
  circfill(shipx+4,shipy-2,muzzle,7)
 end

 -- drawing shwaves
 for w in all(shwaves) do
  circ(w.x,w.y,w.r\2,w.col)
  w.r+=w.speed
  if w.r>w.tr then del(shwaves,w) end
 end

 -- drawing particles (they animate in draw, like the original)
 for p2 in all(parts) do
  if p2.spark==1 then
   -- sparks are always white; skip the page_* color ramp entirely
   pset(p2.x\16,p2.y\16,7)
  else
   -- ramp index (1..10) instead of a color: picks the baked disc row
   local ci=1
   local a2=p2.age
   if p2.blue==1 then
    if a2>5 then ci=7 end
    if a2>7 then ci=8 end
    if a2>10 then ci=9 end
    if a2>12 then ci=10 end
   else
    if a2>5 then ci=2 end
    if a2>7 then ci=3 end
    if a2>10 then ci=4 end
    if a2>12 then ci=5 end
    if a2>15 then ci=6 end
   end
   local r2=p2.size2\2
   if r2<=3 then
    spr(dcell[(ci-1)*4+r2+1],p2.x\16-3,p2.y\16-3)
   else
    circfill(p2.x\16,p2.y\16,r2,rampc[ci])
   end
  end
  p2.age+=1
  if p2.age>p2.maxage then
   -- size2 is byte-wide: guard the decrement instead of testing <0
   if p2.size2>0 then p2.size2-=1 else del(parts,p2) end
  end
 end
 -- bulk move + damp AFTER the draw (original order: draw old pos, then
 -- integrate) — the asm pass replaces the per-particle x/y/damp lines
 gt.pool_move(parts, 1)

 -- drawing ebuls
 for eb in all(ebuls) do
  local f2=(eb.af\2)%4
  if f2==3 then f2=1 end
  spr(32+f2,eb.x\16-2,eb.y\16-2)
 end

 -- floats
 for fl in all(floats) do
  local fc=7
  if tick%4<2 then fc=8 end
  if fl.kind==1 then
   print("1up!",fl.x-8,fl.y\16,fc)
  else
   cscore(fl.val,fl.x,fl.y\16,fc)
  end
  fl.y-=8   -- 0.5 px
  fl.age+=1
  if fl.age>60 then del(floats,fl) end
 end

 -- hud
 local rx=print("score:",40,2,12)
 pscore(score,rx,2,12)
 for i=1,4 do
  if lives>=i then
   spr(37,i*9-8,1)
  else
   spr(38,i*9-8,1)
  end
 end
 spr(48,108,1)
 print(cher,118,2,14)
end

function draw_start()
 gt.starfield_draw()
 print("v1",1,1,1)

 -- the peeker alien bobbing behind the logo
 spr(21,peekerx,28+sin(time()*0.2857)*4)
 if sin(time()*0.2857)>0.5 then
  peekerx=30+flr(rnd(60))
 end

 spr(212,17,30,12,2)
 print("short shwave shmup",28,45,6)

 if highscore>0 then
  print("highscore:",44,63,12)
  cscore(highscore,64,69,12)
 end

 print("press any key to start",20,90,blink())

 rectfill(0,115,127,127,1)
 print("learn how to make this game!",8,116,12)
 print("bit.ly/shmupme",36,122,12)
end

-- kind 1: game over, kind 0: win
function draw_endcard(kind)
 draw_game()
 if kind==1 then
  print("game over",46,40,8)
 else
  print("congratulations",34,40,12)
 end
 local sx2=64-(8+ndig(score))*2
 local rx=print("score:",sx2,60,12)
 pscore(score,rx,60,12)
 if score>highscore then
  local c=7
  if tick%4<2 then c=10 end
  print("new highscore!",36,66,c)
 end
 print("press any key to continue",14,90,blink())
end

function draw_wavetext()
 draw_game()
 if wave==lastwave then
  print("final wave!",42,40,blink())
 else
  local c=blink()
  local rx=print("wave ",42,40,c)
  rx=print(wave,rx,40,c)
  rx=print(" of ",rx,40,c)
  print(lastwave,rx,40,c)
 end
end

function draw_logo()
 if logot<60 then
  spr(10,40,34,6,5)
  print("a lazy devs game",32,80,7)
  print("by krystian majewski",24,86,7)
 end
end

-->8
-- callbacks

function _init()
  sfx_bank(p8sfx)
  music_bank(p8music)
 bake_particle_discs()
 for i=1,11 do banim[i]=5 end
 banim[12]=6
 banim[13]=6
 banim[14]=7
 banim[15]=7
 banim[16]=6
 banim[17]=6
 banim[18]=5
 bossoff[1]=0
 bossoff[2]=4
 bossoff[3]=8
 bossoff[4]=4
 for i=1,45 do sway45[i]=flr(sin((i-1)*0.022222)*16) end
 for i=1,20 do sway20[i]=flr(sin((i-1)*0.05)*16) end
 makesil()
 gt.starfield_init(100)
end

function _update()
 -- autocls: the clear drains inside the post-flip vsync wait, off-budget
 if mode==MLOGO then
  if logot<60 then gt.autocls(12) else gt.autocls(0) end
 elseif mode==MSTART then
  gt.autocls(0)
 else
  if flash>0 then
   flash-=1
   gt.autocls(2)
  else
   gt.autocls(0)
  end
 end

 tick+=1
 blinkt+=1
 swayg+=1
 if (swayg>=45) swayg=0
 swayr+=1
 if (swayr>=20) swayr=0

 if mode==MGAME then
  update_game()
 elseif mode==MSTART then
  update_start()
 elseif mode==MWAVETEXT then
  update_wavetext()
 elseif mode==MOVER then
  update_over()
 elseif mode==MWIN then
  update_win()
 elseif mode==MLOGO then
  update_logo()
 end
end

function _draw()
 doshake()
 if mode==MGAME then
  draw_game()
 elseif mode==MSTART then
  draw_start()
 elseif mode==MWAVETEXT then
  draw_wavetext()
 elseif mode==MOVER then
  draw_endcard(1)
 elseif mode==MWIN then
  draw_endcard(0)
 elseif mode==MLOGO then
  draw_logo()
 end
 camera()
end
