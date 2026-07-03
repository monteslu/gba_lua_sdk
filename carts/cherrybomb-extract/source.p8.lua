-- cherry bomb
-- by lazy devs

function _init()
 --this will clear the screen
 cls(0)
 
 cartdata("cherrybomb")
 highscore=dget(0)
 
 version="v1"
 
 startscreen()
 blinkt=1
 t=0
 lockout=0
 
 shake=0
 flash=0

 debug=""
 
 peekerx=64
 
 -- logo ani --
	fadetable={{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},{1,1,129,129,129,129,129,129,129,129,0,0,0,0,0},{2,2,2,130,130,130,130,130,128,128,128,128,128,0,0},{3,3,3,131,131,131,131,129,129,129,129,129,0,0,0},{4,4,132,132,132,132,132,132,130,128,128,128,128,0,0},{5,5,133,133,133,133,130,130,128,128,128,128,128,0,0},{6,6,134,13,13,13,141,5,5,5,133,130,128,128,0},{7,6,6,6,134,134,134,134,5,5,5,133,130,128,0},{8,8,136,136,136,136,132,132,132,130,128,128,128,128,0},{9,9,9,4,4,4,4,132,132,132,128,128,128,128,0},{10,10,138,138,138,4,4,4,132,132,133,128,128,128,0},{11,139,139,139,139,3,3,3,3,129,129,129,0,0,0},{12,12,12,140,140,140,140,131,131,131,1,129,129,129,0},{13,13,141,141,5,5,5,133,133,130,129,129,128,128,0},{14,14,14,134,134,141,141,2,2,133,130,130,128,128,0},{15,143,143,134,134,134,134,5,5,5,133,133,128,128,0}}

 cls(12)
 spr(10,40,34,6,5)
 cprint("a lazy devs game", 64,80,7)
 cprint("by krystian majewski", 64,86,7)
 
 fadeperc=1
 
 repeat
  dofade()
  fadeperc-=0.07
  flip()
 until( fadeperc<=0 )
 
 fadeperc=0
 dofade()
 for i=0,30 do
  flip()
 end
 
 repeat
  dofade()
  fadeperc+=0.07
  flip()
 until( fadeperc>=1 )
 fadeperc=0
 cls()
 dofade()
 for i=0,10 do
  flip()
 end
 
end

function dofade()
 fadeperc=min(fadeperc,1)
 for c=0,15 do
  pal(c,fadetable[c+1][flr(fadeperc*16+1)],1)
 end
end

function _update() 
 t+=1
 
 blinkt+=1
 
 if mode=="game" then
  update_game()
 elseif mode=="start" then
  update_start()
 elseif mode=="wavetext" then
  update_wavetext()
 elseif mode=="over" then
  update_over()
 elseif mode=="win" then
  update_win()
 end
 
end

function _draw()
 doshake()
 
 if mode=="game" then
  draw_game()
 elseif mode=="start" then
  draw_start()
 elseif mode=="wavetext" then
  draw_wavetext()
 elseif mode=="over" then
  draw_over()
 elseif mode=="win" then
  draw_win()
 end
 
 camera()
 print(debug,2,9,7)

end

function startscreen()
 makestars()
 mode="start"
 music(7)
end

function startgame()
 t=0
 wave=0
 lastwave=9
 nextwave()
 
 ship=makespr()
 ship.x=60
 ship.y=90
 ship.sx=0
 ship.sy=0
 ship.spr=2
   
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
 
 makestars()
  
 buls={}
 ebuls={}
 
 enemies={}
 
 parts={}
 
 shwaves={}
 
 pickups={}
 
 floats={}
end

-->8
-- tools

function makestars()
 stars={} 
 for i=1,100 do
  local newstar={}
  newstar.x=flr(rnd(128))
  newstar.y=flr(rnd(128))
  newstar.spd=rnd(1.5)+0.5
  add(stars,newstar)
 end 
end

function starfield()
 
 for i=1,#stars do
  local mystar=stars[i]
  local scol=6
  
  if mystar.spd<1 then
   scol=1
  elseif mystar.spd<1.5 then
   scol=13
  end   
  
  pset(mystar.x,mystar.y,scol)
 end
end

function animatestars(spd)
 if spd==nil then
  spd=1
 end
 
 for i=1,#stars do
  local mystar=stars[i]
  mystar.y=mystar.y+mystar.spd*spd
  if mystar.y>128 then
   mystar.y=mystar.y-128
  end
 end

end

function blink()
 local banim={5,5,5,5,5,5,5,5,5,5,5,6,6,7,7,6,6,5}
 
 if blinkt>#banim then
  blinkt=1
 end

 return banim[blinkt]
end

function drwoutline(myspr)
 spr(myspr.spr,myspr.x+1,myspr.y,myspr.sprw,myspr.sprh)
 spr(myspr.spr,myspr.x-1,myspr.y,myspr.sprw,myspr.sprh)
 spr(myspr.spr,myspr.x,myspr.y+1,myspr.sprw,myspr.sprh)
 spr(myspr.spr,myspr.x,myspr.y-1,myspr.sprw,myspr.sprh)
end

function drwmyspr(myspr)
 local sprx=myspr.x
 local spry=myspr.y
 
 if myspr.shake>0 then
  myspr.shake-=1
  if t%4<2 then
   sprx+=1
  end
 end
 if myspr.bulmode then
  sprx-=2
  spry-=2
 end
 
 spr(myspr.spr,sprx,spry,myspr.sprw,myspr.sprh)
end

function col(a,b)
 if a.ghost or b.ghost then 
  return false
 end

 local a_left=a.x
 local a_top=a.y
 local a_right=a.x+a.colw-1
 local a_bottom=a.y+a.colh-1
 
 local b_left=b.x
 local b_top=b.y
 local b_right=b.x+b.colw-1
 local b_bottom=b.y+b.colh-1

 if a_top>b_bottom then return false end
 if b_top>a_bottom then return false end
 if a_left>b_right then return false end
 if b_left>a_right then return false end
 
 return true
end

function explode(expx,expy,isblue)
 
 local myp={}
 myp.x=expx
 myp.y=expy
 
 myp.sx=0
 myp.sy=0
 
 myp.age=0
 myp.size=10
 myp.maxage=0
 myp.blue=isblue
 
 add(parts,myp)
	  
 for i=1,30 do
	 local myp={}
	 myp.x=expx
	 myp.y=expy
	 
	 myp.sx=rnd()*6-3
	 myp.sy=rnd()*6-3
	 
	 myp.age=rnd(2)
	 myp.size=1+rnd(4)
	 myp.maxage=10+rnd(10)
	 myp.blue=isblue
	 
	 add(parts,myp)
 end
 
 for i=1,20 do
	 local myp={}
	 myp.x=expx
	 myp.y=expy
	 
	 myp.sx=(rnd()-0.5)*10
	 myp.sy=(rnd()-0.5)*10
	 
	 myp.age=rnd(2)
	 myp.size=1+rnd(4)
	 myp.maxage=10+rnd(10)
	 myp.blue=isblue
	 myp.spark=true
	 
	 add(parts,myp)
 end
 
 big_shwave(expx,expy)
 
end

function bigexplode(expx,expy)
 
 local myp={}
 myp.x=expx
 myp.y=expy
 
 myp.sx=0
 myp.sy=0
 
 myp.age=0
 myp.size=25
 myp.maxage=0
 
 add(parts,myp)
	  
 for i=1,60 do
	 local myp={}
	 myp.x=expx
	 myp.y=expy
	 
	 myp.sx=rnd()*12-6
	 myp.sy=rnd()*12-6
	 
	 myp.age=rnd(2)
	 myp.size=1+rnd(6)
	 myp.maxage=20+rnd(20)
	 
	 add(parts,myp)
 end
 
 for i=1,100 do
	 local myp={}
	 myp.x=expx
	 myp.y=expy
	 
	 myp.sx=(rnd()-0.5)*30
	 myp.sy=(rnd()-0.5)*30
	 
	 myp.age=rnd(2)
	 myp.size=1+rnd(4)
	 myp.maxage=20+rnd(20)
	 myp.spark=true
	 
	 add(parts,myp)
 end
 
 big_shwave(expx,expy)
 
end

function page_red(page)
 local col=7
 
 if page>5 then
  col=10
 end
 if page>7 then
  col=9
 end
 if page>10 then
  col=8
 end
 if page>12 then
  col=2
 end
 if page>15 then
  col=5
 end
 
 return col
end

function page_blue(page)
 local col=7
 
 if page>5 then
  col=6
 end
 if page>7 then
  col=12
 end
 if page>10 then
  col=13
 end
 if page>12 then
  col=1
 end
 if page>15 then
  col=1
 end
 
 return col
end

function smol_shwave(shx,shy,shcol)
 if shcol==nil then
  shcol=9
 end 
 local mysw={}
 mysw.x=shx
 mysw.y=shy
 mysw.r=3
 mysw.tr=6
 mysw.col=shcol
 mysw.speed=1
 add(shwaves,mysw)
end

function big_shwave(shx,shy)
 local mysw={}
 mysw.x=shx
 mysw.y=shy
 mysw.r=3
 mysw.tr=25
 mysw.col=7
 mysw.speed=3.5
 add(shwaves,mysw)
end

function smol_spark(sx,sy)
 --for i=1,2 do
 local myp={}
 myp.x=sx
 myp.y=sy
 
 myp.sx=(rnd()-0.5)*8
 myp.sy=(rnd()-1)*3
 
 myp.age=rnd(2)
 myp.size=1+rnd(4)
 myp.maxage=10+rnd(10)
 myp.blue=isblue
 myp.spark=true
 
 add(parts,myp)
 --end
end

function makespr()
 local myspr={}
 myspr.x=0
 myspr.y=0
 myspr.sx=0
 myspr.sy=0
 
 myspr.flash=0
 myspr.shake=0
 
 myspr.aniframe=1
 myspr.spr=0
 myspr.sprw=1
 myspr.sprh=1
 myspr.colw=8
 myspr.colh=8
 
 return myspr
end

function doshake()

 local shakex=rnd(shake)-(shake/2)
 local shakey=rnd(shake)-(shake/2)
 
 camera(shakex,shakey)
 
 if shake>10 then
  shake*=0.9
 else
  shake-=1
  if shake<1 then
   shake=0
  end
 end
end

function popfloat(fltxt,flx,fly)
 local fl={}
 fl.x=flx
 fl.y=fly
 fl.txt=fltxt
 fl.age=0
 add(floats,fl)
end

function cprint(txt,x,y,c)
 print(txt,x-#txt*2,y,c)
end


-->8
--update

function update_game()
 --controls
 ship.sx=0
 ship.sy=0
 ship.spr=2
 
 if btn(0) then
  ship.sx=-2
  ship.spr=1
 end
 if btn(1) then
  ship.sx=2
  ship.spr=3
 end
 if btn(2) then
  ship.sy=-2
 end
 if btn(3) then
  ship.sy=2
 end
  
 if btnp(4) then
  if cher>0 then
   cherbomb()
   cher=0
  else
   sfx(32)
  end
 end
 
 if btn(5) then
  if bultimer<=0 then
	  local newbul=makespr()
	  newbul.x=ship.x+1
	  newbul.y=ship.y-3
	  newbul.spr=16
	  newbul.colw=6
	  newbul.sy=-4
	  newbul.dmg=1
	  add(buls,newbul)
	  
	  sfx(0)
	  muzzle=5
	  bultimer=4
  end
 end
 bultimer-=1
 
 --moving the ship
 ship.x+=ship.sx
 ship.y+=ship.sy
 
 --checking if we hit the edge
 if ship.x>120 then
  ship.x=120
 end
 if ship.x<0 then
  ship.x=0
 end
 if ship.y<0 then
  ship.y=0
 end
 if ship.y>120 then
  ship.y=120
 end
 
 --move the bullets
 for mybul in all(buls) do
  move(mybul)
  if mybul.y<-8 then
   del(buls,mybul)
  end
 end
 
 --move the ebuls
 for myebul in all(ebuls) do
  move(myebul)
  animate(myebul)
  if myebul.y>128 or myebul.x<-8 or myebul.x>128 or myebul.y<-8 then
   del(ebuls,myebul)
  end
 end 
 
 --move the pickups
 for mypick in all(pickups) do
  move(mypick)
  if mypick.y>128 then
   del(pickups,mypick)
  end
 end 
 
 --moving enemies 
 for myen in all(enemies) do
  --enemy mission
  doenemy(myen)
  
  --enemy animation
  animate(myen)
    
  --enemy leaving screen
  if myen.mission!="flyin" then 
   if myen.y>128 or myen.x<-8 or myen.x>128 then
    del(enemies,myen)
   end
  end
 end
 
 --collision enemy x bullets
 for myen in all(enemies) do
  for mybul in all(buls) do
   if col(myen,mybul) then
    del(buls,mybul)
    smol_shwave(mybul.x+4,mybul.y+4)
    smol_spark(myen.x+4,myen.y+4)
    if myen.mission!="flyin" then
     myen.hp-=mybul.dmg
    end
    sfx(3)
    if myen.boss then
     myen.flash=5
    else
     myen.flash=2
    end
    if myen.hp<=0 then
     killen(myen)
    end
   end
  end
 end
 
 --collision ebuls x bullets
 for mybul in all(buls) do
  if mybul.spr==17 then
	  for myebul in all(ebuls) do
	   if col(myebul,mybul) then
	    del(ebuls,myebul)
	    score+=5
	    smol_shwave(ebuls.x,ebuls.y,8)
	   end
	  end
  end
 end
 
 --collision ship x enemies
 if invul<=0 then
	 for myen in all(enemies) do
	  if col(myen,ship) then
    explode(ship.x+4,ship.y+4,true)
	   lives-=1
	   sfx(1)
	   shake=12
	   invul=60
    ship.x=60
    ship.y=100
    flash=3
	  end
	 end
 else
  invul-=1
 end
 
 --collision ship x ebuls
 if invul<=0 then
	 for myebul in all(ebuls) do
	  if col(myebul,ship) then
    explode(ship.x+4,ship.y+4,true)
	   lives-=1
	   shake=12
	   sfx(1)
	   invul=60
    ship.x=60
    ship.y=100
    flash=3
	  end
	 end
 end
 
 --collision pickup x ship
 for mypick in all(pickups) do
  if col(mypick,ship) then
   del(pickups,mypick)
   plogic(mypick)
  end
 end
 
 
 if lives<=0 then
  mode="over"
  lockout=t+30
  music(6)
  return
 end
 
 --picking
 picktimer()
 
 --animate flame
 flamespr=flamespr+1
 if flamespr>9 then
  flamespr=5
 end
 
 --animate mullze flash
 if muzzle>0 then
  muzzle=muzzle-1
 end
  
 if mode=="wavetext" then
  animatestars(2)
 else
  animatestars()
 end
 
 --check if wave over
 if mode=="game" and #enemies==0 then
  ebuls={}
  nextwave()
 end
 
end

function update_start()
 animatestars(0.4)
 
 if btn(4)==false and btn(5)==false then
  btnreleased=true
 end

 if btnreleased then
  if btnp(4) or btnp(5) then
   startgame()
   btnreleased=false
  end
 end
end

function update_over()
 if t<lockout then
  return
 end
 
 if btn(4)==false and btn(5)==false then
  btnreleased=true
 end

 if btnreleased then
  if btnp(4) or btnp(5) then
   if score>highscore then
    highscore=score
    dset(0,score)
   end
   startscreen()
   btnreleased=false
  end
 end
end

function update_win()
 if t<lockout then
  return
 end
 
 if btn(4)==false and btn(5)==false then
  btnreleased=true
 end

 if btnreleased then
  if btnp(4) or btnp(5) then
   if score>highscore then
    highscore=score
    dset(0,score)
   end
   startscreen()
   btnreleased=false
  end
 end
end

function update_wavetext()
 update_game()
 wavetime-=1
 if wavetime<=0 then
  mode="game"
  spawnwave()
 end
end
-->8
-- draw

function draw_game()
 if flash>0 then
  flash-=1
  cls(2)
 else
  cls(0)
 end
 
 starfield()

 if lives>0 then
	 if invul<=0 then
	  drwmyspr(ship)
	  spr(flamespr,ship.x,ship.y+8)
	 else
	  --invul state
	  if sin(t/5)<0.1 then
	   drwmyspr(ship)
	   spr(flamespr,ship.x,ship.y+8)
	  end
	 end
 end
 
 --drawing pickups
 for mypick in all(pickups) do
  local mycol=7
  if t%4<2 then
   