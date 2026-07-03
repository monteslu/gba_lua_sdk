--just one boss
--by bridgs

--[[
hello there! happy to see you
crack open this cart. my name
is bridgs, and i made this game
in early 2018.

in order to meet compression
size restrictions, i had to
remove all of the tabs and
comments of this cart. it was
the simplest and least-
destructive way of meeting
size limitations.

if you'd like to hack on this
cart, i'd highly recommend
checking out the github repo,
which has the original cart,
tabs and all:

https://github.com/bridgs/just-one-boss

thanks for playing!
]]

-->8

cartdata("bridgs_justoneboss")

function noop() end

local starting_phase,skip_phase_change_animations,skip_title_screen,start_on_hard_mode=0,false,false,false

local conjure_flowers_counter,next_reflection_color,scene_frame,freeze_frames,screen_shake_frames,timer_seconds,score_data_index,time_data_index,rainbow_color,boss_phase,score,score_mult,promises,entities,title_screen,player,player_health,player_reflection,player_figment,boss,boss_health,boss_reflection,curtains,is_paused,hard_mode=1,1,0,0,0,0,0,1,8,0,0,0,{}

-->8
local entity_classes={
{
function(self)
self:draw_sprite(7,1,100,9,15,12)
end,
function(self)
if self.frames_alive%15==0 then
spawn_entity(3,self,nil,{vx=rnd_dir()*(1+rnd(2)),vy=-1-rnd(2)}):poof()
sfx(25,2)
end
end
},
{
function(self)
color_wash(self.parent.dark_color)
pal(8,self.parent.light_color)
pal(1,self.parent.light_color)
self:draw_sprite(7,10,100,9,15,12)
end,
function(self)
self.x+=2*cos(self.frames_alive/50)
end,
vy=1
},
{
function(self)
self:draw_sprite(7,7,91,45,14,12,self.vx>0)
end,
function(self)
self.vy+=0.1
end
},
{
function(self)
self:draw_curtain(1,1)
self:draw_curtain(125,-1)
end,
function(self)
self.amount_closed=62*ease_out_in(self.default_counter/100)
if self.anim!="open" then
self.amount_closed=62-self.amount_closed
end
end,
is_curtains=true,
draw_curtain=function(self,x,dir)
rectfill(x-10*dir,0,x+dir*self.amount_closed,127,0)
local x2
for x2=10,63,14 do
local x3=x+0.5+dir*x2*(1+self.amount_closed/62)/2
line(x3,11,x3,60+40*cos(x2/90-0.02),2)
end
end,
set_anim=function(self,anim)
self.anim,self.default_counter=anim,100
end
},
{
noop,
function(self)
self:check_for_activation()
end,
x=63,
check_for_activation=function(self)
if decrement_counter_prop(self,"frames_until_active") then
self.is_active=true
end
if self.is_active and btnp(1) then
sfx(24,3)
self.is_active=slide(self):on_activated()
end
end,
draw_prompt=function(self,text)
if self.frames_alive%30<22 and self.is_active then
print_centered("press    to "..text,63,99,13)
spr(190,63-2*#text,98)
return true
end
end
},
{
function(self)
self:draw_sprite(23,-29,0,71,47,16)
self:draw_sprite(23,-47,0,88,47,40)
if self:draw_prompt("start") and dget(0)>0 then
pal(13,8)
print_centered("or    for hard mode",63,108)
spr(190,36,107,1,1,true)
end
end,
function(self)
if self.is_active then
hard_mode=false
end
self:check_for_activation()
if self.is_active and btnp(0) and dget(0)>0 then
hard_mode,score_data_index,time_data_index,self.is_active=true,2,3
slide(self,-1):on_activated()
end
end,
frames_until_active=5,
on_activated=function()
music(0)
sfx(9,3)
score,timer_seconds,entities=ternary(starting_phase>0,40,0),0,{title_screen,curtains}
start_game(starting_phase)
end
},
{
function(self,x)
print_centered("thank you for playing!",x+0.5,26,rainbow_color)
print_centered("created (with love) by bridgs",x+0.5,66,6)
print("https://brid.gs",x-24.5,75,12)
print("bridgs_dev",x-24.5,84)
spr(155,x-35.5,82)
self:draw_sprite(11,-41,ternary_hard_mode(69,47),79,22,16)
self:draw_prompt("continue")
end,
x=192,
frames_until_active=130,
on_activated=function(self)
show_title_screen()
end
},
{
function(self,x,y,f)
self:draw_sprite(39,-15,48,95,79,25)
if f>=25 then
print_centered(ternary_hard_mode("you really did it!!","you did it!"),x+0.5,51,15)
end
if f>=135 then
self.draw_score(x,71,"score:",score.."00",format_timer(timer_seconds))
end
if f>=170 then
self.draw_score(x,79,"best:",dget(score_data_index).."00",format_timer(dget(time_data_index)))
end
if self:draw_prompt("continue") then
if dget(score_data_index)==score then
print("!",x+9.5,79,9)
end
if dget(time_data_index)==timer_seconds then
print("!",x+45.5,79,9)
end
end
end,
frames_until_active=215,
on_activated=function(self)
slide(spawn_entity(7))
end,
draw_score=function(x,y,label_text,score_text,time_text)
print(label_text,x-42.5,y,7)
print(score_text,x+9.5-4*#score_text,y)
print(time_text,x+45.5-4*#time_text,y)
spr(173,x+18.5,y)
end
},
{
function(self)
if self:draw_prompt("retry") then
pal(13,5)
print_centered("or    to return to menu",63,108)
spr(190,28,107,1,1,true)
end
end,
function(self)
self:check_for_activation()
if self.is_active and btnp(0) then
self.is_active=music(37)
slide(self,-1)
slide(player_health,-1)
slide(player_figment,-1)
show_title_screen(-1)
end
end,
frames_until_active=220,
on_activated=function(self)
slide(player_health)
slide(player_figment)
score,entities=ternary(boss_phase<=1,40,0),{title_screen,curtains,self,player_health,player_figment}
self.frames_to_death,player_health.frames_to_death,player_figment.frames_to_death=100,100,100
if boss_phase<=1 then
timer_seconds=0
end
sfx(9,3)
start_game(boss_phase)
end
},
{
function(self)
self:draw_sprite(5,6,89,ternary(self.frames_alive<190,13,5),11,8)
end
},
{
function(self)
if self.invincibility_frames%4<2 or self.stun_frames>0 then
local facing=self.facing
local sx,sy,sh,dx,dy,flipped,c=0,0,8,3+4*facing,6,facing==0,ternary(self.teeter_frames%4<2,8,9)
if facing==2 then
sy,sh,dx=8,11,5
elseif facing==3 then
sy,sh,dx,dy=19,11,5,9
end
if self.step_frames>0 then
sx=44-11*self.step_frames
end
if self.teeter_frames>0 or self.default_counter>0 then
sx=66
if self.default_counter<=0 then
palt(c,true)
pal(17-c,self.secondary_color)
sx=44
end
if facing>1 then
dy+=13-5*facing
else
dx+=4-facing*8
end
if self.teeter_frames<3 and self.default_counter<3 then
sx=55
end
end
if self.stun_frames>0 then
sx,sy,sh,dx,dy,flipped=78,11,10,5,8,self.stun_frames%6>2
end
pal(12,self.primary_color)
pal(13,self.secondary_color)
pal(1,self.tertiary_color)
self:draw_sprite(dx,dy,sx,sy,11,sh,flipped)
end
end,
function(self)
decrement_counter_prop(self,"stun_frames")
decrement_counter_prop(self,"teeter_frames")
if self.stun_frames<0 then
self.render_layer=5
end
self:check_inputs()
if self.next_step_dir and not self.step_dir then
self:step(self.next_step_dir)
end
self.prev_col,self.prev_row=self:col(),self:row()
if self.stun_frames<=0 then
self.vx,self.vy=0,0
self:apply_step()
self:apply_velocity()
local col,row,occupant=self:col(),self:row(),get_tile_occupant(self)
if self.prev_col!=col or self.prev_row!=row then
if col!=mid(1,col,8) or row!=mid(1,row,5) then
sfx(19,3)
self:undo_step()
self.teeter_frames=11
end
if occupant or (player_reflection and (self.prev_col<5)!=(col<5)) then
if player_reflection then
player_reflection:copy_player()
if get_tile_occupant(player_reflection) then
get_tile_occupant(player_reflection):get_bumped()
end
end
self:bump()
if occupant then
occupant:get_bumped()
end
if player_reflection then
player_reflection:copy_player()
end
end
end
end
return true
end,
hurtbox_channel=1,
facing=0,
step_frames=0,
teeter_frames=0,
stun_frames=0,
primary_color=12,
secondary_color=13,
tertiary_color=0,
x=45,
y=20,
check_inputs=function(self)
for_each_dir(function(dir)
if btnp(dir) then
self:queue_step(dir)
end
end)
end,
bump=function(self)
sfx(20,2)
self:undo_step()
self.default_counter=11
freeze_and_shake_screen(0,5)
end,
undo_step=function(self)
self.x,self.y,self.step_frames,self.step_dir,self.next_step_dir=10*self.prev_col-5,8*self.prev_row-4,0
end,
queue_step=function(self,dir)
if not self:step(dir) then
self.next_step_dir=dir
end
end,
step=function(self,dir)
if not self.step_dir and self.teeter_frames<=0 and self.default_counter<=0 and self.stun_frames<=0 then
if boss_health.health<=0 and boss_phase<=0 and not boss then
sfx(29,1)
end
self.facing,self.step_dir,self.step_frames,self.next_step_dir=dir,dir,4
return true
end
end,
apply_step=function(self)
local dir,dist=self.step_dir,self.step_frames
if dir then
if dir>1 then
self.vy+=(2*dir-5)*ternary(dist>2,dist-1,dist)
else
self.vx+=2*dir*dist-dist
end
if decrement_counter_prop(self,"step_frames") then
self.step_dir=nil
if self.next_step_dir then
self:step(self.next_step_dir)
self:apply_step()
end
end
end
end,
on_hurt=function(self)
spawn_entity(28,self)
self:get_hurt()
end,
get_hurt=function(self)
if self.invincibility_frames<=0 then
sfx(17,0)
self.render_layer=11
freeze_and_shake_screen(6,10)
player_health.anim,player_health.default_counter,self.invincibility_frames,self.stun_frames,score_mult="lose",20,60,19,0
if decrement_counter_prop(player_health,"hearts") then
promises,is_paused,player_health.render_layer,player_figment={},true,16,spawn_entity(10,player.x+23,player.y+65)
music(-1)
spawn_entity(9)
player_figment:promise_sequence(
35,
{"move",63,72,60})
curtains:set_anim()
player_health:promise_sequence(
35,
function()
music(35)
end,
30,
{"move",62.5,45,60,linear,{-60,10,-40,10}})
player:die()
end
end
end
},
{
function(self)
if self.visible then
local i
for i=1,4 do
local sprite=0
if self.anim=="gain" and i==self.hearts then
sprite=mid(1,5-flr(self.default_counter/2),3)
elseif self.anim=="lose" and i==self.hearts+1 then
if self.default_counter>=15 or (self.default_counter+1)%4<2 then
sprite=6
end
elseif i<=self.hearts then
sprite=4
end
self:draw_sprite(24-8*i,3,9*sprite,30,9,7)
end
end
end,
function(self,counter_reached_zero)
if counter_reached_zero then
self.anim=nil
end
end,
x=63,
y=122,
hearts=4
},
{
function(self)
if self.visible then
rect(33,2,93,8,ternary(self.rainbow_frames>0,rainbow_color,ternary_hard_mode(8,5)))
rectfill(33,2,mid(33,32+self.health,92),8)
end
end,
function(self)
decrement_counter_prop(self,"rainbow_frames")
if self.default_counter>0 then
self.health-=1
end
end,
health=0,
rainbow_frames=0
},
{
function(self,x,y,f,f2)
if f2==10 then
sfx(8,3)
end
if f2<=10 then
f2+=3
rect(x-f2-1,y-f2,x+f2+1,y+f2,ternary(f<4,5,6))
end
end,
on_death=function(self)
freeze_and_shake_screen(0,1)
spawn_entity(15,self)
spawn_particle_burst(self,0,4,16,4)
end
},
{
function(self)
pal(7,rainbow_color)
self:draw_sprite(4,3,55,38,9,7)
end,
function(self)
if get_tile_occupant(self) then
self:die()
spawn_magic_tile(10)
end
end,
hurtbox_channel=2,
on_hurt=function(self)
freeze_and_shake_screen(2,2)
self.hurtbox_channel,self.frames_to_death,score_mult=0,6,min(score_mult+1,8)
sfx(9,3)
score+=score_mult
spawn_entity(29,self.x,self.y-7,{points=score_mult})
local health_change=ternary(boss_phase==0,12,6)
local particles=spawn_particle_burst(self,0,ternary(boss_phase>=5,15,25),16,10)
local i
for i=1,health_change do
local j=rnd_int(i,#particles)
local p=particles[j]
particles[i],particles[j],p.frames_to_death=p,particles[i],300
p:promise_sequence(
7+2*i,
{"move",8+min(boss_health.health+i,60),-58,8,ease_out},
1,
"die",
function()
sfx(10,3)
if boss_health.health<60 then
boss_health.health,boss_health.visible,boss_health.rainbow_frames=mid(0,boss_health.health+1,60),true,15
local health=boss_health.health
if boss_phase==0 then
if health==25 then
boss=spawn_entity(22)
elseif health==37 then
boss.visible=true
elseif health==60 then
boss:intro()
end
elseif health>=60 then
if boss_phase>=5 then
boss_health.health=0
elseif boss_phase==4 then
music(-1)
promises,boss_phase,boss_reflection={},5
local i
for i=1,10 do
spawn_magic_tile(20+13*i)
end
boss:promise_sequence(
"cancel_everything",
"appear",
{"reel",40},
"cancel_everything",
{"move",40,-20,15,ease_in},
20,
function()
player_reflection:poof()
player_reflection=player_reflection:die()

spawn_entity(1,40,-20):poof()
end,
"die",
120,
{curtains,"set_anim"},
90,
function()
music(47)
is_paused=true
end,
75,
function()
score+=max(0,380-timer_seconds)
dset(score_data_index,max(score,dget(score_data_index)))
if timer_seconds<=dget(time_data_index) or dget(time_data_index)==0 then
dset(time_data_index,timer_seconds)
end
spawn_entity(8):promise_sequence(
135,
function()
sfx(24,3)
end,
35,
function()
sfx(24,3)
end,
45,
function()
if score>=dget(score_data_index) or timer_seconds<=dget(time_data_index) then
sfx(9,3)
end
end)
end)
else
boss:promise_sequence(
"cancel_everything",
"appear",
{"reel",10},
10,
"set_expression",
20,
"phase_change",
spawn_magic_tile,
function()
boss_phase+=1
end,
"decide_next_action")
end
end
end
end)
end
if health_change+boss_health.health<60 and boss_phase<5 then
spawn_magic_tile(ternary(boss_phase<1,100,120)-min(self.frames_alive,20))
end
end
},
{
nil,
function(self)
local prev_col,prev_row=self:col(),self:row()
self:copy_player()
if (prev_col!=self:col() or prev_row!=self:row()) and get_tile_occupant(self) then
get_tile_occupant(self):get_bumped()
if get_tile_occupant(player) then
get_tile_occupant(player):get_bumped()
end
player:bump()
self:copy_player()
end
return true
end,
primary_color=11,
secondary_color=3,
tertiary_color=3,
init=function(self)
self:copy_player()
self:poof()
end,
on_hurt=function(self,entity)
player:get_hurt(entity)
self:copy_player()
spawn_entity(28,self)
end,
copy_player=function(self)
self.x,self.facing=80-player.x,({1,0,2,3})[player.facing+1]
copy_props(player,self,{"y","step_frames","stun_frames","teeter_frames","default_counter","invincibility_frames","frames_alive"})
end
},
{
function(self)
local sprite=flr(self.frames_alive/4)%4
if self.vx<0 then
sprite=(6-sprite)%4
end
if self.is_red then
pal(5,8)
pal(6,15)
end
self:draw_sprite(5,7,10*sprite+77,21,10,10)
end
},
{
function(self)
if self.parent.is_reflection and hard_mode then
pal(8,self.parent.dark_color)
pal(14,self.parent.light_color)
end
self:draw_sprite(4,4,ternary(self.default_counter>0,119,ternary(self.frames_to_death>0,110,101)),71,9,8)
end,
function(self,counter_reached_zero)
if counter_reached_zero then
self.hitbox_channel=0
end
end,
bloom=function(self)
self.frames_to_death,self.default_counter,self.hitbox_channel=15,4,1
local i
for i=1,2 do
spawn_entity(21,self.x,self.y-2,{
vx=i-1.5,
vy=-1-rnd(),
friction=0.9,
gravity=0.06,
frames_to_death=10+rnd(7),
color=ternary(self.parent.is_reflection and hard_mode,self.parent.light_color,8)
})
end
end
},
{
function(self,x,y,f)
circfill(self.target_x,self.target_y-1,min(flr(f/7),4),2)
self:draw_sprite(4,5,9*ternary(f>=26,ternary(self.health<3,5,4),ternary(f>10,2,0)+flr(f/3)%2),37,9,9)
end,
health=3,
get_bumped=function(self)
if decrement_counter_prop(self,"health") then
self:die()
end
end,
on_death=function(self)
spawn_particle_burst(self,0,6,6,4)
sfx(21,1)
end
},
{
function(self)
self:draw_sprite(5,3,ternary(self.dir>1,47,58),71,11,7,self.dir==0,self.dir==2)
end,
function(self)
if self.frames_alive>1 then
self.hitbox_channel=0
end
end
},
{
function(self,x,y)
line(x,y,self.prev_x,self.prev_y,ternary(self.color==16,rainbow_color,self.color))
end,
function(self)
self.vy+=self.gravity
self.vx*=self.friction
self.vy*=self.friction
self.prev_x,self.prev_y=self.x,self.y
end,
friction=1,
gravity=0,
init=function(self)
self:update()
self:apply_velocity()
end
},
{
function(self,x,y,f)
if self.really_visible then
local expression=self.expression
self:apply_colors()
if self.visible then
self:draw_sprite(6,12,115,0,13,30)
end
if self.visible or boss_health.rainbow_frames>0 then
if boss_health.rainbow_frames>0 then
color_wash(rainbow_color)
if expression>0 and expression!=5 and boss_phase>0 then
pal(13,5)
end
expression=8
end
if expression>0 then
self:draw_sprite(5,7,11*expression-11,57,11,14,false,expression==5 and f%4<2)
end
end
pal()
self:apply_colors()
if self.visible then
if self.is_wearing_top_hat then
self:draw_sprite(6,15,102,0,13,9)
end
if self.default_counter%2>0 then
line(x,y+7,x,60,14)
end
end
end
end,
function(self)
local x,y=self.x,self.y
calc_idle_mult(self,self.frames_alive,2)
if boss_health.rainbow_frames>12 then
self.draw_offset_x+=scene_frame%2*2-1
end
end,
x=40,
y=-28,
really_visible=true,
home_x=40,
home_y=-28,
expression=4,
dark_color=14,
light_color=15,
idle_mult=0,
init=function(self)
local props,y={mirror=self,is_reflection=self.is_reflection,dark_color=self.dark_color,light_color=self.light_color,is_boss_generated=self.is_boss_generated},self.y+5
self.left_hand=spawn_entity(24,self.x-18,y,props)
self.coins,props.is_right_hand,props.dir={},true,1
self.right_hand=spawn_entity(24,self.x+18,y,props)
end,
on_death=function(self)
self.left_hand:die()
self.right_hand:die()
end,
apply_colors=function(self)
pal(2,ternary(self.is_cracked,6,7))
if self.is_reflection then
color_wash(self.dark_color)
local c
for c in all({8,7,6,2}) do
pal(c,self.light_color)
end
end
end,
intro=function(self)
music(ternary(boss_phase>=1 or skip_phase_change_animations,25,8))
self:promise_sequence(
"phase_change",
function()
spawn_magic_tile(130)
scene_frame,player_health.visible=0,true
boss_phase+=1
end,
"decide_next_action")
end,
decide_next_action=function(self)
return self:promise_sequence(
function()
if boss_phase==1 then
if hard_mode then
return self:promise_sequence(
"return_to_ready_position",
"throw_cards",
"return_to_ready_position",
"shoot_lasers",
10,
"return_to_ready_position",
"despawn_coins",
"throw_coins")
else
return self:promise_sequence(
"return_to_ready_position",
15,
{self.left_hand,"throw_cards"},
{self,"return_to_ready_position"},
10,
{self.right_hand,"throw_cards"},
{self,"return_to_ready_position"},
25,
"shoot_lasers")
end
elseif boss_phase==2 or boss_phase==3 then
return self:promise_sequence(
function()
if hard_mode then
spawn_reflection(nil,
{"conjure_flowers",40},
"die")
end
end,
15,
{"conjure_flowers",10},
30,
"return_to_ready_position",
"throw_cards",
function()
if hard_mode then
local reflection=spawn_entity(23)
reflection:move(20,0,15,ease_in,nil,true)
reflection:promise_sequence(
"throw_cards",
13,
"die")
sfx(30,2)
end
end,
"return_to_ready_position",
ternary_hard_mode(70,0),
{"shoot_lasers",not hard_mode},
"return_to_ready_position",
"despawn_coins",
function()
if hard_mode then
spawn_reflection(ternary(player and player.x<40,20,-20),
10,
"throw_hat",
30,
"die")
end
end,
"throw_coins",
"return_to_ready_position")
elseif boss_phase==4 then
if hard_mode then
local n,m=0,0
return self:promise_sequence(
"return_to_ready_position",
10,
{self.left_hand,"disappear"},
{self.right_hand,"disappear"})
:and_then_repeat(5,
function()
spawn_reflection(40-20*n,
8*n,
{"throw_hat",nil,1},
32-8*n,
"reform")
n=(n+1)%5
end)
:and_then_sequence(
{self,"disappear"},
145,
"appear",
30)
:and_then_repeat(4,
10,
"disappear",
{"set_expression",5},
function()
m=m%4+1
local col=rnd_int(0,7)
local i
for i=1,3 do
col=(col+2)%8
spawn_reflection(10*col-35,
7,
{"shoot_laser",m==4},
"reform")
end
if m==4 then
return self:promise_sequence(
40,
function()
spawn_reflection(-50,
{"set_expression",1},
"appear",
25,
"throw_cards",
60,
"reform")
end,
177)
else
return 66
end
end,
{"set_expression",1},
"appear")
else
return self:promise_sequence(
function()
boss_reflection:promise_sequence(
75,
"conjure_flowers",
"return_to_ready_position")
end,
"conjure_flowers",
"return_to_ready_position",
20,
"conjure_flowers",
"return_to_ready_position",
function()
boss_reflection:promise_sequence(
84,
"throw_cards",
20,
"return_to_ready_position")
end,
"throw_cards",
"return_to_ready_position",
100,
function()
boss_reflection:promise_sequence(
30,
"shoot_lasers",
"return_to_ready_position")
end,
"shoot_lasers",
"return_to_ready_position",
50,
function()
boss_reflection:promise_sequence(
"despawn_coins",
17,
{"throw_coins",player_reflection,3},
"return_to_ready_position")
end,
"despawn_coins",
{"throw_coins",nil,3},
"return_to_ready_position",
100)
end
end
end,
function()
self:decide_next_action()
end)
end,
appear=function(self)
self.really_visible=true
self.left_hand:appear()
self.right_hand:appear()
end,
disappear=function(self)
self.really_visible=false
self.left_hand:disappear()
self.right_hand:disappear()
end,
phase_change=function(self)
next_reflection_color=1
local lh,rh=self.left_hand,self.right_hand
if skip_phase_change_animations then
if boss_phase==0 then
self.is_wearing_top_hat=true
elseif boss_phase==2 then
player_reflection=spawn_entity(16)
elseif boss_phase==3 and not hard_mode then
boss_reflection=spawn_entity(23)
self.home_x+=20
end
return self:return_to_ready_position()
elseif boss_phase==0 then
return self:promise_sequence(
66,
{lh,"appear"},
20)
:and_then_repeat(2,
{"set_pose",5},
3,
{"set_pose",4},
3)
:and_then_sequence(
20,
{rh,"appear"},
10,
{"move",-16,8,10,ease_out,{10,0,10,5},true},
{"set_pose",2},
{self,"set_expression"},
33,
{"set_expression",6},
28,
"set_expression",
34,
{"set_expression",1},
5,
function()
lh:promise_sequence(
9,
{"set_pose",5},
4,
{"set_pose",4})
lh:promise_sequence(
{"move",self.x+5*lh.dir,self.y-3,10,ease_out,{0,-10,10*lh.dir,-2}},
2,
{"move",lh.x,lh.y,10,ease_in,{10*lh.dir,-2,0,-10}})
end,
10,
function()
self.is_wearing_top_hat=true
end,
{"poof",0,-10},
35)
elseif boss_phase==1 then
if hard_mode then
return self:promise_sequence(
{"return_to_ready_position",2},
30,
"set_all_idle",
10,
"pound",
"pound",
"pound",
function()
local i
for i=1,5 do
spawn_entity(23):promise_sequence(
{"move",0,0,40,linear,{40*cos(i/5),40*sin(i/5),40*cos((i+1)/5),40*sin((i+1)/5)},true},
2,
"die")
end
sfx(31,1)
end,
75)
else
return self:promise_sequence(
{"return_to_ready_position",2},
30,
"set_all_idle",
10,
"pound",
"pound",
"pound",
{"set_expression",1},
function()
sfx(16,3)
lh.is_holding_bouquet=true
end,
{rh,"set_pose"},
{"move",20,-10,15,ease_in,{-20,-10,-5,0},true},
35,
{lh,"move",2,-9,20,ease_in,nil,true},
{self,"set_expression",3},
30,
{"set_expression",1},
15,
function()
lh:promise_sequence(
10,
"set_pose",
function()
sfx(28,3)
lh.is_holding_bouquet=false
end,
{"move",-22,6,20,ease_in,nil,true})
end,
{rh,"move",0,7,20,ease_out_in,{-35,-20,-25,0},true},
15)
end
elseif boss_phase==2 then
return self:promise_sequence(
{"return_to_ready_position",2},
"cast_reflection",
"return_to_ready_position",
60)
elseif boss_phase==3 and not hard_mode then
return self:promise_sequence(
{"return_to_ready_position",2},
{"cast_reflection",true},
function()
boss_reflection:return_to_ready_position()
end,
"return_to_ready_position",
60)
end
end,
for_each=function(self,fn,skip_self)
fn(self.left_hand)
fn(self.right_hand)
if not skip_self then
fn(self)
end
end,
cancel_everything=function(self)
self:for_each(function(entity)
entity.is_holding_wand=entity:cancel_promises()
entity:cancel_move()
end)
self.default_counter=0
foreach(entities,function(entity)
if entity.is_boss_generated then
entity:cancel_promises()
entity.finished=true
end
end)
end,
pound=function(self)
self.left_hand:pound()
return self.right_hand:pound()
end,
reel=function(self,times)
self:for_each(function(entity)
entity:appear()
entity:set_pose()
end,spawn_entity(26,10*rnd_int(3,6)-5,4))
self.is_cracked=boss_phase>=3
return self:promise_sequence(
{"set_expression",8},
"set_all_idle")
:and_then_repeat(times,
{"for_each",function(entity)
freeze_and_shake_screen(0,2)
entity.x,entity.y=mid(10,entity.x,70),mid(-40,entity.y,-20)
entity:poof(rnd_int(-10,10),rnd_int(-10,10),12)
entity:move(rnd_int(-7,7),rnd_int(-7,7),6,ease_out,nil,true)
end},
5)
end,
throw_hat=function(self)
return self:promise_sequence(
"set_all_idle",
{self.left_hand,"disappear"},
{self.right_hand,"appear"},
{"move",self.x+5,self.y-6,15,linear},
{"set_pose",1},
30,
"set_pose",
function()
sfx(26,2)
self.is_wearing_top_hat=false
spawn_entity(2,self.x,-32,{parent=self})
end,
{"move",14,5,3,ease_in,nil,true},
{self,30})
end,
conjure_flowers=function(self,extra_delay)
if hard_mode or not self.is_reflection then
conjure_flowers_counter=1+(conjure_flowers_counter+rnd_int(0,2))%8
end
local flowers={}
self.left_hand:move_to_temple()
return self:promise_sequence(
"set_all_idle",
{self.right_hand,"move_to_temple"},
{self,"set_expression",2},
function()
local promise,locations,n,i=self:promise(),{},0
function do_a_math(m)
return ternary((n+({1,2,3,5,7,9,10,11})[conjure_flowers_counter])%m>0,1,0)
end
for i=0,39 do
if i==n then
n+=mid(1,do_a_math(2)+do_a_math(3)+do_a_math(5),3)
if not self.is_reflection then
add(locations,{x=i%8*10+5,y=8*flr(i/8)+4})
end
elseif self.is_reflection then
add(locations,{x=i%8*10+5,y=8*flr(i/8)+4})
end
end
for i=1,#locations do
local j=rnd_int(i,#locations)
locations[i],locations[j],promise=locations[j],locations[i],promise:and_then_sequence(
1,
function()
sfx(15,1)
add(flowers,spawn_entity(18,locations[i],nil,{parent=self}))
end)
end
end,
(extra_delay or 0)+ternary_hard_mode(50,65),
function()
sfx(16,1)
local flower
for flower in all(flowers) do
flower:bloom()
end
end,
{self.left_hand,"set_pose",5},
{self.right_hand,"set_pose",5},
{self,"set_expression",3},
31)
end,
cast_reflection=function(self,upgraded_version)
local lh,rh,i=self.left_hand,self.right_hand
return self:promise_sequence(
"set_all_idle",
{lh,"move",23,14,20,ease_in,nil,true},
{"set_pose",1})
:and_then_repeat(2,
{rh,"move",0,0,40,linear,{18,6,-18,6},true})
:and_then_sequence(
function()
if upgraded_version then
rh:promise_sequence(
{"set_pose",1},
function()
rh.is_holding_wand=true
end,
{"poof",-10},
30,
"flourish_wand")
end
end,
{self,"set_expression",1},
function()
lh.is_holding_wand=true
end,
{lh,"poof",10},
30,
{lh,"flourish_wand"},
{self,"set_expression",3},
5,
function()
if upgraded_version then
boss_reflection=spawn_entity(23)
self.home_x+=20
else
player_reflection=spawn_entity(16)
end
end,
55)
end,
throw_cards=function(self,hand)
self.left_hand:throw_cards()
return self.right_hand:throw_cards()
end,
throw_coins=function(self,target,num_coins)
target=target or player
return self:promise_sequence(
"set_all_idle",
{self.right_hand,"move_to_temple"})
:and_then_repeat(num_coins or 4,
{self,"set_expression",7},
{self.right_hand,"set_pose",1},
ternary_hard_mode(7,15),
function()
local target_x,target_y=10*target:col()-5,8*target:row()-4
sfx(21,1)
local coin=spawn_entity(19,self.x+13,self.y-6,{target_x=target_x,target_y=target_y})
add(self.coins,coin)
coin:promise_sequence(
{"move",target_x+2,target_y,25,ease_out,{20,-30,10,-60}},
2,
function()
sfx(22,1)
coin.occupies_tile,coin.hitbox_channel=true,5
freeze_and_shake_screen(2,2)
if hard_mode then
for_each_dir(function(dir,dx,dy)
spawn_entity(20,mid(5,target_x+10*dx,75),mid(4,target_y+8*dy,36),{dir=dir})
end)
end
end,
{"move",-2,0,8,linear,{0,-4,0,-4},true},
function()
coin.hitbox_channel,coin.hurtbox_channel=1,4
end)
end,
{"set_pose",4},
{self,"set_expression",3},
20)
end,
shoot_lasers=function(self,sweep)
self.left_hand:disappear()
self.right_hand:disappear()
local col,num_reflections=rnd_int(0,7),2
return self:promise_sequence(
"set_expression",
"set_all_idle"):and_then_repeat(3,
function()
col=(col+rnd_int(2,ternary_hard_mode(3,6)))%8
return self:promise_sequence(
{"move",10*col+5,-20,ternary_hard_mode(10,15),ease_in,{0,-10,0,-10}},
1,
function()
if sweep then
local dir=2
if col>5 or (rnd()<0.5 and col>1) then
dir=-2
end
col+=dir
self:move(10*dir,0,40,linear,nil,true)
end
end,
"shoot_laser",
function()
if hard_mode and boss_phase>1 and num_reflections>0 then
spawn_entity(23):promise():and_then_repeat(num_reflections,
10,
"shoot_laser")
:and_then(
"die")
num_reflections-=1
end
end)
end)
end,
shoot_laser=function(self,long_duration)
return self:promise_sequence(
ternary_hard_mode(2,12),
function()
sfx(ternary(long_duration,7,14),1)
self.default_counter=ternary(long_duration,173,31)
end,
12,
{"set_expression",0},
function()
freeze_and_shake_screen(0,4)
local laser=spawn_entity(25,self,nil,{parent=self})
if long_duration then
laser.frames_to_death=150
end
end,
ternary(long_duration,166,16),
"set_expression",
5)
end,
return_to_ready_position=function(self,expression)--,expression,held_hand)
local lh,rh,home_x,home_y=self.left_hand,self.right_hand,self.home_x,self.home_y
lh.is_holding_wand,rh.is_holding_wand=false
return self:promise_sequence(
{lh,"set_pose"},
{rh,"set_pose"},
{self,"set_all_idle",true},
{"set_expression",expression or 1},
function()
self:move(home_x,home_y,15,ease_in)
lh:move(home_x-18,home_y+5,15,ease_in,{-10,-10,-20,0})
lh:appear()
rh:move(home_x+18,home_y+5,15,ease_in,{10,-10,20,0})
rh:appear()
end,
ternary_hard_mode(15,25))
end,
despawn_coins=function(self)
local coin
for coin in all(self.coins) do
coin:die()
end
self.coins={}
return 10
end,
set_all_idle=function(self,idle)
self:for_each(function(entity)
entity.is_idle=idle
end)
end,
set_expression=function(self,expression)
self.expression=expression or 5
end
},
{
visible=true,
expression=1,
is_wearing_top_hat=true,
home_x=20,
is_reflection=true,
init=function(self)
local color_index=3
if hard_mode then
color_index,next_reflection_color=next_reflection_color,next_reflection_color%5+1
end
self.dark_color,self.light_color=({2,1,3,9,8})[color_index],({13,12,11,10,14})[color_index]
boss.init(self)
local props={"pose","x","y","visible"}
copy_props(boss,self,{"x","y","expression"})
copy_props(boss.left_hand,self.left_hand,props)
copy_props(boss.right_hand,self.right_hand,props)
end,
reform=function(self)
self:move(boss.x,boss.y,10,ease_out)
self.left_hand:move(boss.left_hand.x,boss.left_hand.y,10,ease_out)
self.right_hand:move(boss.right_hand.x,boss.right_hand.y,10,ease_out)
return self:promise_sequence(10,"die")
end
},
{
function(self)
if self.visible then
if self.is_holding_bouquet then
self:draw_sprite(1,12,110,71,9,16)
end
if self.is_reflection then
color_wash(self.dark_color)
pal(7,self.light_color)
pal(6,self.light_color)
end
local is_right_hand=self.is_right_hand
self:draw_sprite(ternary(is_right_hand,7,4),8,12*self.pose-12,46,12,11,is_right_hand)
if self.is_holding_wand then
if self.pose==1 then
self:draw_sprite(ternary(is_right_hand,10,-4),8,91,57,7,13,is_right_hand)
else
self:draw_sprite(ternary(is_right_hand,3,2),16,98,57,7,13,is_right_hand)
end
end
end
end,
function(self)
local m=self.mirror
self.render_layer=ternary(self.is_reflection,6,ternary(self.is_right_hand,9,8))
calc_idle_mult(self,boss.frames_alive+ternary(self.is_right_hand,9,4),4)
self:apply_velocity()
return true
end,
pose=3,
dir=-1,
idle_mult=0,
throw_cards=function(self)
local is_first=self.is_right_hand!=self.is_reflection
local dir,promise=self.dir,self:promise_sequence(
ternary(is_first,0,ternary_hard_mode(13,19)),
function()
self.is_idle=false
end)
local r
for r=ternary(is_first,0,1),4,2 do
promise=promise:and_then_sequence(
"set_pose",
{"move",40+52*dir,8*(r%5)+4,18,ease_out_in,{10*dir,-10,10*dir,10}},
{"set_pose",2},
ternary_hard_mode(0,12),
{"set_pose",1},
function()
sfx(13,2)
spawn_entity(17,self.x-7*dir,self.y,{
vx=-1.5*dir,
is_red=rnd()<0.5
})
end,
10)
end
return promise
end,
flourish_wand=function(self)
return self:promise_sequence(
{"move",40+20*self.dir,-30,12,ease_out,{-20,20,0,20}},
{"set_pose",6},
function()
sfx(23,1)
spawn_particle_burst(self,20,20,3,10)
freeze_and_shake_screen(0,20)
end)
end,
appear=function(self)
if not self.visible then
self.visible=true
return self:poof()
end
end,
disappear=function(self)
if self.visible then
self.visible=false
self:poof()
end
end,
pound=function(self)
local m,d=self.mirror,20*self.dir
return self:promise_sequence(
{"set_pose",2},
{"move",m.x+4*self.dir,m.y+20,15,ease_out,{d,0,d,0}},
function()
sfx(12,2)
freeze_and_shake_screen(0,2)
end,
1)
end,
move_to_temple=function(self)
return self:promise_sequence(
{"set_pose",1},
{"move",self.mirror.x+13*self.dir,self.mirror.y,20})
end,
set_pose=function(self,pose)
self.pose=pose or 3
end
},
{
function(self,x,y)
pal(14,self.parent.dark_color)
pal(15,self.parent.light_color)
sspr(117,30,11,1,x-4.5,y+4.5,11,100)
end,
function(self)
self.x=self.parent.x
end,
is_hitting=function(self,entity)
return self:col()==entity:col()
end
},
{
function(self,x,y,f,f2)
if f2>30 or f2%4>1 then
self:draw_sprite(4,5,36,30,9,7)
end
end,
hurtbox_channel=2,
on_hurt=function(self)
sfx(18,0)
if player_health.hearts<4 then
player_health.hearts+=1
player_health.anim,player_health.default_counter="gain",10
end
spawn_particle_burst(self,0,6,8,4)
self:die()
end
},
{
function(self)
self:draw_sprite(8,8,64+16*flr(self.frames_alive/3),31,16,14)
end
},
{
function(self)
self:draw_sprite(11,16,105,45,23,26)
end
},
{
function(self)
print_centered(self.points.."00",self.x+1,self.y,rainbow_color)
end,
vy=-0.5
}
}

-->8
function _init()
music(37)
starting_phase,title_screen,curtains=max(starting_phase,ternary(dget(0)>0,1,0)),spawn_entity(6),spawn_entity(4)
entities={title_screen,curtains}
if skip_title_screen then
title_screen.x,curtains.anim,title_screen.is_active=-200,"open"
title_screen:on_activated()
end
end

function _update()
if freeze_frames>0 then
freeze_frames=decrement_counter(freeze_frames)
if player then
player:check_inputs()
end
else
if scene_frame%30==0 and not is_paused and boss_phase>0 then
timer_seconds=min(5999,timer_seconds+1)
end
screen_shake_frames,scene_frame=decrement_counter(screen_shake_frames),increment_counter(scene_frame)
rainbow_color=flr(scene_frame/4)%6+8
if rainbow_color==13 then
rainbow_color=14
end
local num_promises=#promises
local i
for i=1,num_promises do
if promises[i] and decrement_counter_prop(promises[i],"frames_to_finish") then
promises[i]:finish()
end
end
filter_out_finished(promises)
local num_entities=#entities
for i=1,min(#entities,num_entities) do
local entity=entities[i]
if entity and (not is_paused or entity.is_pause_immune) then
if not entity:update(decrement_counter_prop(entity,"default_counter")) then
entity:apply_velocity()
end
decrement_counter_prop(entity,"invincibility_frames")
entity.frames_alive=increment_counter(entity.frames_alive)
if decrement_counter_prop(entity,"frames_to_death") then
entity:die()
end
end
end
if not is_paused then
local i,j
for i=1,min(#entities,num_entities) do
for j=1,min(#entities,num_entities) do
local entity,entity2=entities[i],entities[j]
if i!=j and band(entity.hitbox_channel,entity2.hurtbox_channel)>0 and entity:is_hitting(entity2) and entity2.invincibility_frames<=0 then
entity2:on_hurt(entity)
end
end
end
end
filter_out_finished(entities)
local i
for i=1,#entities do
local j=i
while j>1 and is_rendered_on_top_of(entities[j-1],entities[j]) do
entities[j],entities[j-1]=entities[j-1],entities[j]