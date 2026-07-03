--combo pool
--by nusan

skipmenu = false
menuselect = 2
maxallowed = 0
names = {"endless","easy","normal","hard"}

function toggledisplaynumber(b)
	if(b&32 > 0)	displaynumber=not displaynumber
	menuitem(1,"numbers: "..(displaynumber and "visible" or "hidden"),toggledisplaynumber)
end
displaynumber = false
toggledisplaynumber(0)

function newball(xx,yy,cc)
	local b = {x=xx,y=yy,vx=0,vy=0,c=cc,idx=ballidx,dead=false,mult=1,lastmult=0}
	add(balls, b)
	ballidx += 1
	return b
end

function newpart(xx,yy,time,cc)
	local b = {x=xx,y=yy,vx=0,vy=0,c=cc,t=time}
	add(parts, b)
	return b
end

function newtext(xx,yy,cc,intext)
	local b = {x=xx,y=yy,vx=0,vy=0,c=cc,t=1,text=intext}
	add(parts, b)
	return b
end

function reset()

	balls={}
	ballidx = 0

	parts = {}

	grid = {}

	time = 0
	menutime = 0

	launch_vrot = 0
	launch_rot = 0.25
	launch_px = 66
	launch_py = 64
	launch_vx = 0
	launch_vy = 0
	launch_x = 64
	launch_y = 120
	launch_dx = 0
	launch_dy = 1
	launch_str = 6

	launch_press = false
	launch_duration = 0
	avoid_nextlaunch = true

	launch_next = 1

	shouldrun = true

	score = 0
	ballscore = 0
	maxballscore = 0
	ballmult = 1
	maxmult = 1
	oldscore = 0
	newscoretimer = 0
	newballtimer = 0
	newballappear = 0
	oldballscore = 0
	newballscoretimer = 0
	newmaxtimer = 0
	newmaxappear = 0

	mainmenu = not skipmenu
	intromenu = false
	lastselect = 30

	death = false
	suddendeath = false
	suddendeathduration = 120
	victory = false
	finish = false
	finishtimer = 0

	pstam = 100
	astam = 0.5
	lstam = pstam

	plife = 1
	llife = plife

	for i=1,8 do
		grid[i]={}
		for j=1,8 do
			grid[i][j] = {}
		end
	end
