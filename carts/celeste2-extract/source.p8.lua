-- celeste2
-- exok games

level_index = 0
level_intro = 0

function game_start()
	
	-- reset state
	snow = {}
	clouds = {}
	freeze_time = 0
	frames = 0
	seconds = 0
	minutes = 0
	shake = 0
	sfx_timer = 0
	berry_count = 0
	death_count = 0
	collected = {}
	camera_x = 0
	camera_y = 0
	show_score = 0
	titlescreen_flash = nil

	for i=0,25 do 
		snow[i] = { x = rnd(132), y = rnd(132) } 
		clouds[i] = { x = rnd(132), y = rnd(132), s = 16 + rnd(32) }
	end

	-- goto titlescreen or level
	if level_index == 0 then
		current_music = 38
		music(current_music)
	else
		goto_level(level_index)
	end
end

function _init()
	game_start()
end

function _update()

	-- titlescreen
	if level_index == 0 then
		if titlescreen_flash then
			titlescreen_flash-= 1
			if titlescreen_flash < -30 then goto_level(1) end
		elseif btn(4) or btn(5) then
			titlescreen_flash = 50
			sfx(22, 3)
		end
	
	-- level intro card
	elseif level_intro > 0 then
		level_intro -= 1
		if level_intro == 0 then psfx(17, 24, 9) end

	-- normal level
	else
		-- timers
		sfx_timer = max(sfx_timer - 1)
		shake = max(shake - 1)
		infade = min(infade + 1, 60)
		if level_index != 8 then frames += 1 end
		if frames == 30 then seconds += 1 frames = 0 end
		if seconds == 60 then minutes += 1 seconds = 0 end

		update_input()

		--freeze
		if freeze_time > 0 then
			freeze_time -= 1
		else
			--objects
			for o in all(objects) do
				if o.freeze > 0 then
					o.freeze -= 1
				else
					o:update()
				end

				if o.destroyed then
					del(objects, o)
				end
			end
		end
	end
end

function _draw()

	pal()

	if level_index == 0 then

		cls(0)
		
		if titlescreen_flash then
			local c=10
			if titlescreen_flash>10 then
				if titlescreen_flash%10<5 then c=7 end
			elseif titlescreen_flash>5 then c=2
			elseif titlescreen_flash>0 then c=1
			else c=0 end
			if c<10 then for i=1,16 do pal(i,c) end end
		end

		sspr(64, 32, 64, 32, 36, 32)
		rect(0,0,127,127,7)
		print_center("lANI'S tREK", 64, 68, 14)
		print_center("a game by", 64, 80, 1)
		print_center("maddy thorson", 64, 87, 5)
		print_center("noel berry", 64, 94, 5)
		print_center("lena raine", 64, 101, 5)
		draw_snow()
		return
	end

	if level_intro > 0 then
		cls(0)
		camera(0, 0)
		draw_time(4, 4)
		if level_index != 8 then
			print_center("level " .. (level_index - 2), 64, 64 - 8, 7)
		end
		print_center(level.title, 64, 64, 7)
		return
	end

	local camera_x = peek2(0x5f28)
	local camera_y = peek2(0x5f2a)

	if shake > 0 then
		camera(camera_x - 2 + rnd(5), camera_y - 2 + rnd(5))
	end

	-- clear screen
	cls(level and level.bg and level.bg or 0)

	-- draw clouds
	draw_clouds(1, 0, 0, 1, 1, level.clouds or 13, #clouds)

	-- columns
	if level.columns then
		fillp(0b0000100000000010.1)
		local x = 0
		while x < level.width do
			local tx = x * 8 + camera_x * 0.1
			rectfill(tx, 0, tx + (x % 2) * 8 + 8, level.height * 8, level.columns)
			x += 1 + x % 7
		end
		fillp()
	end

	-- draw tileset
	for x = mid(0, flr(camera_x / 8), level.width),mid(0, flr((camera_x + 128) / 8), level.width) do
		for y = mid(0, flr(camera_y / 8), level.height),mid(0, flr((camera_y + 128) / 8), level.height) do
			local tile = tile_at(x, y)
			if level.pal and fget(tile, 7) then level.pal() end
			if tile != 0 and fget(tile, 0) then spr(tile, x * 8, y * 8) end
			pal() palt()
		end
	end

	-- score
	if show_score > 105 then
		rectfill(34,392,98, 434, 1)
		rectfill(32,390,96, 432, 0)
		rect(32,390,96, 432, 7)
		spr(21, 44, 396)
		print("X "..berry_count, 56, 398, 7)
		spr(87, 44, 408)
		draw_time(56, 408)
		spr(71, 44, 420)
		print("X "..death_count, 56, 421, 7)
	end

	-- draw objects
	local p = nil
	for o in all(objects) do
		if o.base == player then p = o else o:draw() end
	end
	if p then p:draw() end

	-- draw snow
	draw_snow()

	-- draw FG clouds
	if level.fogmode then
		if level.fogmode == 1 then fillp(0b0101101001011010.1) end
		draw_clouds(1.25, 0, level.height * 8 + 1, 1, 0, 7, #clouds - 10)
		fillp()
	end

	-- screen wipes
	-- very similar functions ... can they be compressed into one?
	if p ~= nil and p.wipe_timer > 5 then
		local e = (p.wipe_timer - 5) / 12
		for i=0,127 do
			s = (127 + 64) * e - 32 + sin(i * 0.2) * 16 + (127 - i) * 0.25
			rectfill(camera_x,camera_y+i,camera_x+s,camera_y+i,0)
		end
	end

	if infade < 15 then
		local e = infade / 12
		for i=0,127 do
			s = (127 + 64) * e - 32 + sin(i * 0.2) * 16 + (127 - i) * 0.25
			rectfill(camera_x+s,camera_y+i,camera_x+128,camera_y+i,0)
		end
	end

	-- game timer
	if infade < 45 then
		draw_time(camera_x + 4, camera_y + 4)
	end

	-- debug
	--[[
	for o in all(objects) do
		rect(o.x + o.hit_x, o.y + o .hit_y, o.x + o.hit_x + o.hit_w - 1, o.y + o.hit_y + o.hit_h - 1, 8)
	end

	camera(0, 0)
	print("cpu: " .. flr(stat(1) * 100) .. "/100", 9, 9, 8)
	print("mem: " .. flr(stat(0)) .. "/2048", 9, 15, 8)
	print("idx: " .. level.offset, 9, 21, 8)
	]]

	camera(camera_x, camera_y)
end

function draw_time(x,y)
	local m = minutes % 60
	local h = flr(minutes / 60)
	
	rectfill(x,y,x+32,y+6,0)
	print((h<10 and "0"..h or h)..":"..(m<10 and "0"..m or m)..":"..(seconds<10 and "0"..seconds or seconds),x+1,y+1,7)
end

function draw_clouds(scale, ox, oy, sx, sy, color, count)
	for i=0,count do
		local c = clouds[i]
		local s = c.s * scale
		local x = ox + (camera_x + (c.x - camera_x * 0.9) % (128 + s) - s / 2) * sx
		local y = oy + (camera_y + (c.y - camera_y * 0.9) % (128 + s / 2)) * sy
		clip(x - s / 2 - camera_x, y - s / 2 - camera_y, s, s / 2)
		circfill(x, y, s / 3, color)
		if i % 2 == 0 then
			circfill(x - s / 3, y, s / 5, color)
		end
		if i % 2 == 0 then
			circfill(x + s / 3, y, s / 6, color)
		end
		c.x += (4 - i % 4) * 0.25
	end
	clip(0,0,128,128)
end

function draw_snow()
	for i=1,#snow do
		local s = snow[i]
		circfill(camera_x + (s.x - camera_x * 0.5) % 132 - 2, camera_y + (s.y - camera_y * 0.5) % 132, i % 2, 7)
		s.x += (4 - i % 4)
		s.y += sin(time() * 0.25 + i * 0.1)
	end
end

function print_center(text, x, y, c)
	x -= (#text * 4 - 1) / 2
	print(text, x, y, c)
end

function approach(x, target, max_delta)
	return x < target and min(x + max_delta, target) or max(x - max_delta, target)
end

function psfx(id, off, len, lock)
	if sfx_timer <= 0 or lock then
		sfx(id, 3, off, len)
		if lock then sfx_timer = lock end
	end
end

function draw_sine_h(x0, x1, y, col, amplitude, time_freq, x_freq, fade_x_dist)
	pset(x0, y, col)
	pset(x1, y, col)

	local x_sign = sgn(x1 - x0)
	local x_max = abs(x1 - x0) - 1
	local last_y = y
	local this_y = 0
	local ax = 0
	local ay = 0
	local fade = 1

	for i = 1, x_max do
		
		if i <= fade_x_dist then
			fade = i / (fade_x_dist + 1)
		elseif i > x_max - fade_x_dist + 1 then
			fade = (x_max + 1 - i) / (fade_x_dist + 1)
		else
			fade = 1
		end

		ax = x0 + i * x_sign
		ay = y + sin(time() * time_freq + i * x_freq) * amplitude * fade
		pset(ax, ay + 1, 1)
		pset(ax, ay, col)

		this_y = ay
		while abs(ay - last_y) > 1 do
			ay -= sgn(this_y - last_y)
			pset(ax - x_sign, ay + 1, 1)
			pset(ax - x_sign, ay, col)
		end
		last_y = this_y
	end
end


levels = {
    {
        offset = 0,
        width = 96,
        height = 16,
		camera_mode = 1,
		music = 38,
    },
    {
		offset = 343,
        width = 32,
        height = 32,
        camera_mode = 2,
		music = 36,
		fogmode = 1,
		clouds = 0,
		columns = 1
    },
    {
		offset = 679,
        width = 128,
        height = 22,
        camera_mode = 3,
        camera_barriers_x = { 38 },
        camera_barrier_y = 6,
        music = 2,
		title = "trailhead"
    },
    {
        offset = 1313,
        width = 128,
        height = 32,
        camera_mode = 4,
        music = 2,
		title = "glacial caves",
		pal = function() pal(2, 12) pal(5, 2) end,
		columns = 1
    },
    {
		offset = 2411,
        width = 128,
        height = 16,
        camera_mode = 5,
        music = 2,
		title = "golden valley",
		pal = function() pal(2, 14) pal(5, 2) end,
		bg = 13,
		clouds = 15,
		fogmode = 2
    },
    {
		offset = 2645,
        width = 128,
        height = 16,
        camera_mode = 6,
        camera_barriers_x = { 105 },
        music = 2,
		pal = function() pal(2, 14) pal(5, 2) end,
		bg = 13,
		clouds = 15,
		fogmode = 2
    },
    {
		offset = 2880,
        width = 128,
        height = 16,
        camera_mode = 7,
        music = 2,
		pal = function() pal(2, 12) pal(5, 2) end,
		bg = 13,
		clouds = 7,
		fogmode = 2,
    },
    {
		offset = 3079,
        width = 16,
		height = 62,
		title = "destination",
        camera_mode = 8,
        music = 2,
		pal = function() pal(2, 1) pal(7, 11) end,
		bg = 15,
		clouds = 7,
        fogmode = 2,
        right_edge = true
    }
}

camera_x_barrier = function(tile_x, px, py)
    local bx = tile_x * 8
    if px < bx - 8 then
        camera_target_x = min(camera_target_x, bx - 128)
    elseif px > bx + 8 then
        camera_target_x = max(camera_target_x, bx)
    end
end

c_offset = 0
c_flag = false
camera_modes = {

    -- 1: Intro
    function(px, py)
        if px < 42 then
            camera_target_x = 0
        else
            camera_target_x = max(40, min(level.width * 8 - 128, px - 48))
        end
    end,

    -- 2: Intro 2
    function(px, py)
        if px < 120 then
            camera_target_x = 0
        elseif px > 136 then
            camera_target_x = 128
        else
            camera_target_x = px - 64
        end
        camera_target_y = max(min(level.height * 8 - 128, py - 64))
    end,

    -- 3: Level 1
    function(px, py)
        camera_target_x = max(min(level.width * 8 - 128, px - 56))
        for i,b in ipairs(level.camera_barriers_x) do
            camera_x_barrier(b, px, py)
        end

        if py < level.camera_barrier_y * 8 + 3 then
            camera_target_y = 0
        else
            camera_target_y = level.camera_barrier_y * 8
        end
    end,

    -- 4: Level 2
    function(px, py)
        if px % 128 > 8 and px % 128 < 120 then
            px = flr(px / 128) * 128 + 64
        end
        if py % 128 > 4 and py % 128 < 124 then
            py = flr(py / 128) * 128 + 64
        end
        camera_target_x = max(min(level.width * 8 - 128, px - 64))
        camera_target_y = max(min(level.height * 8 - 128, py - 64))
    end,

    -- 5: Level 3-1
    function(px, py)
        camera_target_x = max(min(level.width * 8 - 128, px - 32))
    end,

    -- 6: Level 3-2
    function(px, py)
        if px > 848 then
            c_offset = 48
        elseif px < 704 then
            c_flag = false
            c_offset = 32
        elseif px > 808 then
            c_flag = true
            c_offset = 96
        end

        camera_target_x = max(min(level.width * 8 - 128, px - c_offset))

        for i,b in ipairs(level.camera_barriers_x) do
            camera_x_barrier(b, px, py)
        end

        if c_flag then
            camera_target_x = max(camera_target_x, 672)
        end
    end,

    --7: Level 3-3
    function (px, py)
        if px > 420 then
            if px < 436 then
                c_offset = 32 + px - 420
            elseif px > 808 then
                c_offset = 48 - min(16, px - 808)
            else
                c_offset = 48
            end
        else
            c_offset = 32
        end
        camera_target_x = max(0, min(level.width * 8 - 128, px - c_offset))
    end,

    --8: End
    function (px, py)
        camera_target_y = max(0, min(level.height * 8 - 128, py - 32))
    end
}

snap_camera = function()
    camera_x = camera_target_x
    camera_y = camera_target_y
    camera(camera_x, camera_y)
end

tile_y = function(py)
    return max(0, min(flr(py / 8), level.height - 1))
end

function goto_level(index)

	-- set level
	level = levels[index]
	level_index = index
	level_checkpoint = nil

	if level.title and not standalone then
		level_intro = 60
	end

	if level_index == 2 then 
		psfx(17, 8, 16)
	end

	-- load into ram
	local function vget(x, y) return peek(0x4300 + x + y * level.width) end
	local function vset(x, y, v) return poke(0x4300 + x + y * level.width, v) end
	px9_decomp(0, 0, 0x1000 + level.offset, vget, vset)

	-- start music
	if current_music != level.music and level.music then
		current_music = level.music
		music(level.music)
	end
	
	-- load level contents
    restart_level()
end

function next_level()
	level_index += 1
	if standalone then
		load("celeste2/" .. level_index .. ".p8")
	else
		goto_level(level_index)
	end
end

function restart_level()
	camera_x = 0
	camera_y = 0
    camera_target_x = 0
	camera_target_y = 0
	objects = {}
	infade = 0
	have_grapple = level_index > 2
	sfx_timer = 0

	for i = 0,level.width-1 do
		for j = 0,level.height-1 do
			local t = types[tile_at(i, j)]
			if t and not collected[id(i, j)] and (not level_checkpoint or t != player) then
				create(t, i * 8, j * 8)
			end
		end
	end
end

-- gets the tile at the given location from the loaded level
function tile_at(x, y)
	if x < 0 or y < 0 or x >= level.width or y >= level.height then return 0 end

	if standalone then
		return mget(x, y)
	else
		return peek(0x4300 + x + y * level.width)
	end
end


input_x = 0
input_jump = false
input_jump_pressed = 0
input_grapple = false
input_grapple_pressed = 0
axis_x_value = 0
axis_x_turned = false

function update_input()
    -- axes
	local prev_x = axis_x_value
	if btn(0) then
		if btn(1) then
            if axis_x_turned then
                axis_x_value = prev_x
				input_x = prev_x
			else
                axis_x_turned = true
                axis_x_value = -prev_x
                input_x = -prev_x
			end
		else
            axis_x_turned = false
            axis_x_value = -1
            input_x = -1
		end
	elseif btn(1) then
        axis_x_turned = false
        axis_x_value = 1
        input_x = 1
	else
        axis_x_turned = false
        axis_x_value = 0
        input_x = 0
    end

	-- input_jump
	local jump = btn(4)
	if jump and not input_jump then		
		input_jump_pressed = 4
	else
		input_jump_pressed = jump and max(0, input_jump_pressed - 1) or 0
	end
	input_jump = jump

	-- input_grapple
	local grapple = btn(5)
	if grapple and not input_grapple then
		input_grapple_pressed = 4
	else
		input_grapple_pressed = grapple and max(0, input_grapple_pressed - 1) or 0
	end
	input_grapple = grapple
end

function consume_jump_press()
	local val = input_jump_pressed > 0
	input_jump_pressed = 0
	return val
end

function consume_grapple_press()
	local val = input_grapple_pressed > 0
	input_grapple_pressed = 0
	return val
end


objects = {}
types = {}
lookup = {}
function lookup.__index(self, i) return self.base[i] end

object = {}
object.speed_x = 0;
object.speed_y = 0;
object.remainder_x = 0;
object.remainder_y = 0;
object.hit_x = 0
object.hit_y = 0
object.hit_w = 8
object.hit_h = 8
object.grapple_mode = 0
object.hazard = 0
object.facing = 1
object.freeze = 0

function object.move_x(self, x, on_collide)	
	self.remainder_x += x
	local mx = flr(self.remainder_x + 0.5)
	self.remainder_x -= mx

	local total = mx
	local mxs = sgn(mx)
	while mx != 0
	do
		if self:check_solid(mxs, 0) then
			if on_collide then
				return on_collide(self, total - mx, total)
			end
			return true
		else
			self.x += mxs
			mx -= mxs
		end
	end

	return false
end

function object.move_y(self, y, on_collide)
	self.remainder_y += y
	local my = flr(self.remainder_y + 0.5)
	self.remainder_y -= my
	
	local total = my
	local mys = sgn(my)
	while my != 0
	do
		if self:check_solid(0, mys) then
			if on_collide then
				return on_collide(self, total - my, total)
			end
			return true
		else
			self.y += mys
			my -= mys
		end
	end

	return false
end

function object.on_collide_x(self, moved, target)
	self.remainder_x = 0
	self.speed_x = 0
	return true
end

function object.on_collide_y(self, moved, target)
	self.remainder_y = 0
	self.speed_y = 0
	return true
end

function object.update() end
function object.draw(self)
	spr(self.spr, self.x, self.y, 1, 1, self.flip_x, self.flip_y)
end

function object.overlaps(self, b, ox, oy)
	if self == b then return false end
	ox = ox or 0
	oy = oy or 0
	return
		ox + self.x + self.hit_x + self.hit_w > b.x + b.hit_x and
		oy + self.y + self.hit_y + self.hit_h > b.y + b.hit_y and
		ox + self.x + self.hit_x < b.x + b.hit_x + b.hit_w and
		oy + self.y + self.hit_y < b.y + b.hit_y + b.hit_h
end

function object.contains(self, px, py)
	return
		px >= self.x + self.hit_x and
		px < self.x + self.hit_x + self.hit_w and
		py >= self.y + self.hit_y and
		py < self.y + self.hit_y + self.hit_h
end

function object.check_solid(self, ox, oy)
	ox = ox or 0
	oy = oy or 0

	for i = flr((ox + self.x + self.hit_x) / 8),flr((ox + self.x + self.hit_x + self.hit_w - 1) / 8) do
		for j = tile_y(oy + self.y + self.hit_y),tile_y(oy + self.y + self.hit_y + self.hit_h - 1) do
			if fget(tile_at(i, j), 1) then
				return true
			end
		end
	end

	for o in all(objects) do
		if o.solid and o != self and not o.destroyed and self:overlaps(o, ox, oy) then
			return true
		end
	end

	return false
end

function object.corner_correct(self, dir_x, dir_y, side_dist, look_ahead, only_sign, func)
	look_ahead = look_ahead or 1
	only_sign = only_sign or 1

	if dir_x ~= 0 then
		for i = 1, side_dist do
			for s = 1, -2, -2 do
				if s == -only_sign then
					goto continue_x
				end

				if not self:check_solid(dir_x, i * s) and (not func or func(self, dir_x, i * s)) then
					self.x += dir_x
					self.y += i * s
					return true
				end

				::continue_x::
			end
		end
	elseif dir_y ~= 0 then
		for i = 1, side_dist do
			for s = 1, -1, -2 do
				if s == -only_sign then
					goto continue_y
				end

				if not self:check_solid(i * s, dir_y) and (not func or func(self, i * s, dir_y)) then
					self.x += i * s
					self.y += dir_y
					return true
				end

				::continue_y::
			end
		end
	end

	return false
end

function id(tx, ty) return level_index * 100 + flr(tx) + flr(ty) * 128 end

function create(type, x, y)
	local obj = {}
	obj.base = type
	obj.x = x
	obj.y = y
	obj.id = id(flr(x/8), flr(y/8))
	setmetatable(obj, lookup)
	add(objects, obj)
	if obj.init then obj.init(obj) end
	return obj
end

function new_type(spr)
	local obj = {}
	obj.spr = spr
	obj.base = object
	setmetatable(obj, lookup)
	types[spr] = obj
	return obj
end


grapple_pickup = new_type(20)
function grapple_pickup.draw(self)
	spr(self.spr, self.x, self.y + sin(time()) * 2, 1, 1, not self.right)
end

spike_v = new_type(36)
function spike_v.init(self)
	if not self:check_solid(0, 1) then
		self.flip_y = true
		self.hazard = 3
	else
		self.hit_y = 5
		self.hazard = 2
	end
	self.hit_h = 3
end

spike_h = new_type(37)
function spike_h.init(self)
	if self:check_solid(-1, 0) then
		self.flip_x = true
		self.hazard = 4
	else
		self.hit_x = 5
		self.hazard = 5
	end
	self.hit_w = 3
end

snowball = new_type(62)
snowball.grapple_mode = 3
snowball.holdable = true
snowball.thrown_timer = 0
snowball.stop = false
snowball.hp = 6
function snowball.update(self)
	if not self.held then
		self.thrown_timer -= 1

		--speed
		if self.stop then
			self.speed_x = approach(self.speed_x, 0, 0.25)
			if self.speed_x == 0 then
				self.stop = false
			end
		else
			if self.speed_x != 0 then
				self.speed_x = approach(self.speed_x, sgn(self.speed_x) * 2, 0.1)
			end
		end

		--gravity
		if not self:check_solid(0, 1) then
			self.speed_y = approach(self.speed_y, 4, 0.4)
		end

		--apply
		self:move_x(self.speed_x, self.on_collide_x)
		self:move_y(self.speed_y, self.on_collide_y)

		--bounds
		if self.y > level.height * 8 + 24 then
			self.destroyed = true
		end
	end
end
function snowball.on_collide_x(self, moved, total)
	if self:corner_correct(sgn(self.speed_x), 0, 2, 2, 1) then
		return false
	end

	if self:hurt() then
		return true
	end

	self.speed_x *= -1
	self.remainder_x = 0
	self.freeze = 1
	psfx(17, 0, 2)
	return true
end
function snowball.on_collide_y(self, moved, total)
	if self.speed_y < 0 then
		self.speed_y = 0
		self.remainder_y = 0
		return true
	end

	if self.speed_y >= 4 then
		self.speed_y = -2
		psfx(17, 0, 2)
	elseif self.speed_y >= 1 then
		self.speed_y = -1
		psfx(17, 0, 2)
	else
		self.speed_y = 0
	end
	self.remainder_y = 0
	return true
end
function snowball.on_release(self, thrown)
	if not thrown then
		self.stop = true
	end
	self.thrown_timer = 8
end
function snowball.hurt(self)
	self.hp -= 1
	if self.hp <= 0 then
		psfx(8, 16, 4)
		self.destroyed = true
		return true
	end
	return false
end
function snowball.bounce_overlaps(self, o)
	if self.speed_x != 0 then
		self.hit_w = 12
		self.hit_x = -2
		local ret = self:overlaps(o)
		self.hit_w = 8
		self.hit_x = 0
		return ret
	else
		return self:overlaps(o)
	end
end
function snowball.contains(self, px, py)
	return
		px >= self.x and
		px < self.x + 8 and
		py >= self.y - 1 and
		py < self.y + 10
end
function snowball.draw(self)
	pal(7, 1)
	spr(self.spr, self.x, self.y + 1)
	pal()
	spr(self.spr, self.x, self.y)
end

springboard = new_type(11)
springboard.grapple_mode = 3
springboard.holdable = true
springboard.thrown_timer = 0
function springboard.update(self)
	if not self.held then
		self.thrown_timer -= 1

		--friction and gravity	
		if self:check_solid(0, 1) then
			self.speed_x = approach(self.speed_x, 0, 1)
		else
			self.speed_x = approach(self.speed_x, 0, 0.2)
			self.speed_y = approach(self.speed_y, 4, 0.4)
		end

		--apply
		self:move_x(self.speed_x, self.on_collide_x)
		self:move_y(self.speed_y, self.on_collide_y)

		if self.player then
			self.player:move_y(self.speed_y)
		end

		self.destroyed = self.y > level.height * 8 + 24
	end
end
function springboard.on_collide_x(self, moved, total)
	self.speed_x *= -0.2
	self.remainder_x = 0
	self.freeze = 1
	return true
end
function springboard.on_collide_y(self, moved, total)
	if self.speed_y < 0 then
		self.speed_y = 0
		self.remainder_y = 0
		return true
	end

	if self.speed_y >= 2 then
		self.speed_y *= -0.4
	else
		self.speed_y = 0
	end
	self.remainder_y = 0
	self.speed_x *= 0.5
	return true
end
function springboard.on_release(self, thrown)
	if thrown then
		self.thrown_timer = 5
	end
end

grappler = new_type(46)
grappler.grapple_mode = 2
grappler.hit_x = -1
grappler.hit_y = -1
grappler.hit_w = 10
grappler.hit_h = 10

bridge = new_type(63)
function bridge.update(self)
	self.y += self.falling and 3 or 0
end

berry = new_type(21)
function berry.update(self)
	if self.collected then
		self.timer += 1
		self.y -= 0.2 * (self.timer > 5 and 1 or 0)
		self.destroyed = self.timer > 30
	elseif self.player then
		self.x += (self.player.x - self.x) / 8
		self.y += (self.player.y - 4 - self.y) / 8
		self.flash -= 1

		if self.player:check_solid(0, 1) and self.player.state != 99 then self.ground += 1 else self.ground = 0 end

		if self.ground > 3 or self.player.x > level.width * 8 - 7 or self.player.last_berry != self then
			psfx(8, 8, 8, 20)
			collected[self.id] = true
			berry_count += 1
			self.collected = true
			self.timer = 0
			self.draw = score
		end
	end
end
function berry.collect(self, player)
	if not self.player then
		self.player = player
		player.last_berry = self
		self.flash = 5
		self.ground = 0
		psfx(7, 12, 4)
	end
end
function berry.draw(self)
	if (self.timer or 0) < 5 then
		grapple_pickup.draw(self)
		if (self.flash or 0) > 0 then
			circ(self.x + 4, self.y + 4, self.flash * 3, 7)
			circfill(self.x + 4, self.y + 4, 5, 7)
		end
	else
		print("1000", self.x - 4, self.y + 1, 8)
		print("1000", self.x - 4, self.y, self.timer % 4 < 2 and 7 or 14)
	end
end

crumble = new_type(19)
crumble.solid = true
crumble.grapple_mode = 1
function crumble.init(self)
	self.time = 0
	self.breaking = false
	self.ox = self.x
	self.oy = self.y
end
function crumble.update(self)
	if self.breaking then
		self.time += 1
		if self.time > 10 then
			self.x = -32
			self.y = -32
		end
		if self.time > 90 then
			self.x = self.ox
			self.y = self.oy

			local can_respawn = true
			for o in all(objects) do
				if self:overlaps(o) then can_respawn = false break end
			end

			if can_respawn then
				self.breaking = false
				self.time = 0
				psfx(17, 5, 3)
			else
				self.x = -32
				self.y = -32
			end
		end
	end
end
function crumble.draw(self)
	object.draw(self)
	if self.time > 2 then
		fillp(0b1010010110100101.1)
		rectfill(self.x, self.y, self.x + 7, self.y + 7, 1)
		fillp()
	end
end

checkpoint = new_type(13)
function checkpoint.init(self)
	if level_checkpoint == self.id then
		create(player, self.x, self.y)
	end
end
function checkpoint.draw(self)
	if level_checkpoint == self.id then
		sspr(104, 0, 1, 8, self.x, self.y)
		pal(2, 11)
		for i=1,7 do
			sspr(104 + i, 0, 1, 8, self.x + i, self.y + sin(-time() * 2 + i * 0.25) * (i - 1) * 0.2)
		end
		pal()
	else
		object.draw(self)
	end
end

function make_spawner(tile, dir)
	local spawner = new_type(tile)
	function spawner.init(self)
		self.timer = (self.x / 8) % 32
		self.spr = -1
	end
	function spawner.update(self)
		self.timer += 1
		if self.timer >= 32 and abs(self.x - 64 - camera_x) < 128 then
			self.timer = 0
			local snowball = create(snowball, self.x, self.y - 8)
			snowball.speed_x = dir * 2
			snowball.speed_y = 4
			psfx(17, 5, 3)
		end
	end
	return spawner
end
snowball_spawner_r = make_spawner(14, 1)
snowball_spawner_l = make_spawner(15, -1)


player = new_type(2)
player.t_jump_grace = 0
player.t_var_jump = 0
player.var_jump_speed = 0
player.auto_var_jump = false
player.grapple_x = 0
player.grapple_y = 0
player.grapple_dir = 0
player.grapple_hit = nil
player.grapple_wave = 0
player.grapple_boost = false
player.t_grapple_cooldown = 0
player.grapple_retract = false
player.holding = nil
player.wipe_timer = 0
player.finished = false
player.t_grapple_jump_grace = 0
player.t_grapple_pickup = 0

player.state = 0

-- Grapple Functions

--[[
	object grapple modes:
		0 - no grapple
		1 - solid
		2 - solid centered
		2 - holdable
]]

function player.start_grapple(self)
	self.state = 10

	self.speed_x = 0
	self.speed_y = 0
	self.remainder_x = 0
	self.remainder_y = 0
	self.grapple_x = self.x
	self.grapple_y = self.y - 3	
	self.grapple_wave = 0
	self.grapple_retract = false
	self.t_grapple_cooldown = 6
	self.t_var_jump = 0

	if input_x != 0 then
		self.grapple_dir = input_x
	else
		self.grapple_dir = self.facing
	end
	self.facing = self.grapple_dir

	psfx(8, 0, 5)
end

-- 0 = nothing, 1 = hit!, 2 = fail
function player.grapple_check(self, x, y)
	local tile = tile_at(flr(x / 8), tile_y(y))
	if fget(tile, 1) then
		self.grapple_hit = nil
		return fget(tile, 2) and 2 or 1
	end

	for o in all(objects) do
		if o.grapple_mode != 0 and o:contains(x, y) then
			self.grapple_hit = o
			return 1
		end
	end

	return 0
end

-- Helpers

function player.jump(self)
	consume_jump_press()
	self.state = 0
	self.speed_y = -4
	self.var_jump_speed = -4
	self.speed_x += input_x * 0.2
	self.t_var_jump = 4
	self.t_jump_grace = 0
	self.auto_var_jump = false
	self:move_y(self.jump_grace_y - self.y)
	psfx(7, 0, 4)
end

function player.bounce(self, x, y)
	self.state = 0
	self.speed_y = -4
	self.var_jump_speed = -4
	self.t_var_jump = 4
	self.t_jump_grace = 0
	self.auto_var_jump = true
	self.speed_x += sgn(self.x - x) * 0.5
	self:move_y(y - self.y)	
end

function player.spring(self, y)
	consume_jump_press()
	if input_jump then 
		psfx(17, 2, 3)
	else
		psfx(17, 0, 2)
	end
	self.state = 0
	self.speed_y = -5
	self.var_jump_speed = -5
	self.t_var_jump = 6
	self.t_jump_grace = 0
	self.remainder_y = 0
	self.auto_var_jump = false
	self.springboard.player = nil

	for o in all(objects) do
		if o.base == crumble and not o.destroyed and self.springboard:overlaps(o, 0, 4) then
			o.breaking = true
			psfx(8, 20, 4)
		end
	end
end

function player.wall_jump(self, dir)
	consume_jump_press()
	self.state = 0
	self.speed_y = -3
	self.var_jump_speed = -3
	self.speed_x = 3 * dir	
	self.t_var_jump = 4
	self.auto_var_jump = false
	self.facing = dir
	self:move_x(-dir * 3)
	psfx(7, 4, 4)
end

function player.grapple_jump(self)
	consume_jump_press()
	psfx(17, 2, 3)
	self.state = 0
	self.t_grapple_jump_grace = 0
	self.state = 0
	self.speed_y = -3
	self.var_jump_speed = -3
	self.t_var_jump = 4
	self.auto_var_jump = false
	self.grapple_retract = true
	if abs(self.speed_x) > 4 then
		self.speed_x = sgn(self.speed_x) * 4
	end
	self:move_y(self.grapple_jump_grace_y - self.y)
end

function player.bounce_check(self, obj)
	return self.speed_y >= 0 and self.y - self.speed_y < obj.y + obj.speed_y + 4
end

function player.die(self)
	self.state = 99
	freeze_time = 2
	shake = 5
	death_count += 1
	psfx(14, 16, 16, 120)
end

--[[
	hazard types:
		0 - not a hazard
		1 - general hazard
		2 - up-spike
		3 - down-spike
		4 - right-spike
		5 - left-spike
]]

player.hazard_table = {
	[1] = function(self) return true end,
	[2] = function(self) return self.speed_y >= 0 end,
	[3] = function(self) return self.speed_y <= 0 end,
	[4] = function(self) return self.speed_x <= 0 end,
	[5] = function(self) return self.speed_x >= 0 end
}

function player.hazard_check(self, ox, oy)
	ox = ox or 0
	oy = oy or 0

	for o in all(objects) do
		if o.hazard != 0 and self:overlaps(o, ox, oy) and self.hazard_table[o.hazard](self) then
			return true
		end
	end

	return false
end

function player.correction_func(self, ox, oy)
	return not self:hazard_check(ox, oy)
end

-- Grappled Objects

pull_collide_x = function(self, moved, target)
	if self:corner_correct(sgn(target), 0, 4, 2, 0) then
		return false
	end
	return true
end

function player.release_holding(self, obj, x, y, thrown)
	obj.held = false
	obj.speed_x = x
	obj.speed_y = y
	obj:on_release(thrown)
	psfx(7, 24, 6)
	self.holding = nil
end

-- Events

function player.init(self)
	self.x += 4
	self.y += 8
	self.hit_x = -3
	self.hit_y = -6
	self.hit_w = 6
	self.hit_h = 6

	self.scarf = {}
	for i = 0,4 do
		add(self.scarf, { x = self.x, y = self.y })
	end

	--camera
	camera_modes[level.camera_mode](self.x, self.y)
	camera_x = camera_target_x
	camera_y = camera_target_y
	camera(camera_x, camera_y)
end

function player.update(self)
	local on_ground = self:check_solid(0, 1)
	if on_ground then
		self.t_jump_grace = 4
		self.jump_grace_y = self.y
	else
		self.t_jump_grace = max(0, self.t_jump_grace - 1)
	end

	self.t_grapple_jump_grace = max(self.t_grapple_jump_grace - 1)

	if self.t_grapple_cooldown > 0 and self.state < 1 then
		self.t_grapple_cooldown -= 1
	end

	-- grapple retract
	if self.grapple_retract then
		self.grapple_x = approach(self.grapple_x, self.x, 12)
		self.grapple_y = approach(self.grapple_y, self.y - 3, 6)

		if self.grapple_x == self.x and self.grapple_y == self.y - 3 then
			self.grapple_retract = false
		end
	end

	--[[
		player states:
			0 	- normal
			1	- lift
			2 	- springboard bounce
			10 	- throw grapple
			11 	- grapple attached to solid
			12	- grapple pulling in holdable
			50  - get grapple!!
			99 	- dead
			100 - finished level
	]]

	if self.state == 0 then
		-- normal state

		-- facing
		if input_x ~= 0 then
			self.facing = input_x
		end

		-- running
		local target, accel = 0, 0.2
		if abs(self.speed_x) > 2 and input_x == sgn(self.speed_x) then
			target,accel = 2, 0.1
		elseif on_ground then
			target, accel = 2, 0.8
		elseif input_x != 0 then
			target, accel = 2, 0.4
		end
		self.speed_x = approach(self.speed_x, input_x * target, accel)

		-- gravity
		if not on_ground then
			local max = btn(3) and 5.2 or 4.4
			if abs(self.speed_y) < 0.2 and input_jump then
				self.speed_y = min(self.speed_y + 0.4, max)
			else
				self.speed_y = min(self.speed_y + 0.8, max)
			end
		end

		-- variable jumping
		if self.t_var_jump > 0 then
			if input_jump or self.auto_var_jump then
				self.speed_y = self.var_jump_speed
				self.t_var_jump -= 1
			else
				self.t_var_jump = 0
			end
		end		

		-- jumping
		if input_jump_pressed > 0 then
			if self.t_jump_grace > 0 then
				self:jump()
			elseif self:check_solid(2) then
				self:wall_jump(-1)
			elseif self:check_solid(-2) then
				self:wall_jump(1)
			elseif self.t_grapple_jump_grace > 0 then
				self:grapple_jump()
			end
		end

		-- throw holding
		if self.holding and not input_grapple and not self.holding:check_solid(0, -2) then
			self.holding.y -= 2
			if btn(3) then
				self:release_holding(self.holding, 2 * self.facing, 0, false)
			else
				self:release_holding(self.holding, 4 * self.facing, -1, true)
			end
		end

		-- throw grapple
		if have_grapple and not self.holding and self.t_grapple_cooldown <= 0 and consume_grapple_press() then
			self:start_grapple()
		end

	elseif self.state == 1 then
		-- lift state
		hold = self.grapple_hit
		hold.x = approach(hold.x, self.x - 4, 4)
		hold.y = approach(hold.y, self.y - 14, 4)

		if hold.x == self.x - 4 and hold.y == self.y - 14 then
			self.state = 0
			self.holding = hold
		end

	elseif self.state == 2 then
		-- springboard bounce state

		local at_x = approach(self.x, self.springboard.x + 4, 0.5)
		self:move_x(at_x - self.x)

		local at_y = approach(self.y, self.springboard.y + 4, 0.2)
		self:move_y(at_y - self.y)

		if self.springboard.spr == 11 and self.y >= self.springboard.y + 2 then
			self.springboard.spr = 12
		elseif self.y == self.springboard.y + 4 then
			self:spring(self.springboard.y + 4)
			self.springboard.spr = 11
		end

	elseif self.state == 10 then
		-- throw grapple state

		-- grapple movement and hitting stuff
		local amount = min(64 - abs(self.grapple_x - self.x), 6)
		local grabbed = false
		for i = 1, amount do
			local hit = self:grapple_check(self.grapple_x + self.grapple_dir, self.grapple_y)
			if hit == 0 then
				hit = self:grapple_check(self.grapple_x + self.grapple_dir, self.grapple_y - 1)
			end
			if hit == 0 then
				hit = self:grapple_check(self.grapple_x + self.grapple_dir, self.grapple_y + 1)
			end

			local mode = self.grapple_hit and self.grapple_hit.grapple_mode or 0

			if hit == 0 then
				self.grapple_x += self.grapple_dir * 2
			elseif hit == 1 then
				if mode == 2 then
					self.grapple_x = self.grapple_hit.x + 4
					self.grapple_y = self.grapple_hit.y + 4
				elseif mode == 3 then
					self.grapple_hit.held = true
					grabbed = true
				end

				self.state = mode == 3 and 12 or 11
				self.grapple_wave = 2
				self.grapple_boost = false
				self.freeze = 2
				psfx(14, 0, 5)
				break
			end

			if hit == 2 or (hit == 0 and abs(self.grapple_x - self.x) >= 64) then
				psfx(hit == 2 and 7 or 14, 8, 3)
				self.grapple_retract = true
				self.freeze = 2
				self.state = 0
				break
			end
		end

		-- grapple wave
		self.grapple_wave = approach(self.grapple_wave, 1, 0.2)
		self.spr = 3

		-- release
		if not grabbed and (not input_grapple or abs(self.y - self.grapple_y) > 8) then
			self.state = 0
			self.grapple_retract = true
			psfx(-2)
		end

	elseif self.state == 11 then
		-- grapple attached state
		
		-- start boost
		if not self.grapple_boost then
			self.grapple_boost = true
			self.speed_x = self.grapple_dir * 8
		end

		-- acceleration
		self.speed_x = approach(self.speed_x, self.grapple_dir * 5, 0.25)
		self.speed_y = approach(self.speed_y, 0, 0.4)

		-- y-correction
		if self.speed_y == 0 then
			if self.y - 3 > self.grapple_y then
				self:move_y(-0.5)
			elseif self.y - 3 < self.grapple_y then
				self:move_y(0.5)
			end
		end

		-- wall pose
		if self.spr != 4 and self:check_solid(self.grapple_dir) then
			self.spr = 4
			psfx(14, 8, 3)
		end

		-- jumps
		if consume_jump_press() then
			if self:check_solid(self.grapple_dir * 2) then
				self:wall_jump(-self.grapple_dir)
			else
				self.grapple_jump_grace_y = self.y
				self:grapple_jump()
			end
		end

		-- grapple wave
		self.grapple_wave = approach(self.grapple_wave, 0, 0.6)

		-- release
		if not input_grapple or (self.grapple_hit and self.grapple_hit.destroyed) then
			self.state = 0
			self.t_grapple_jump_grace = 4
			self.grapple_jump_grace_y = self.y
			self.grapple_retract = true
			self.facing *= -1
			if abs(self.speed_x) > 5 then
				self.speed_x = sgn(self.speed_x) * 5
			elseif abs(self.speed_x) <= 0.5 then
				self.speed_x = 0
			end
		end

		-- release if beyond grapple point
		if sgn(self.x - self.grapple_x) == self.grapple_dir then
			self.state = 0
			if self.grapple_hit != nil and self.grapple_hit.grapple_mode == 2 then
				self.t_grapple_jump_grace = 4
				self.grapple_jump_grace_y = self.y
			end
			if abs(self.speed_x) > 5 then
				self.speed_x = sgn(self.speed_x) * 5
			end
		end

	elseif self.state == 12 then
		-- grapple pull state
		local obj = self.grapple_hit

		-- pull
		if obj:move_x(-self.grapple_dir * 6, pull_collide_x) then
			self.state = 0
			self.grapple_retract = true
			obj:on_release(-self.grapple_dir)
			obj.held = false
			return
		else
			self.grapple_x = approach(self.grapple_x, self.x, 6)
		end

		-- y-correct
		if obj.y != self.y - 7 then
			obj:move_y(sgn(self.y - obj.y - 7) * 0.5)
		end

		-- grapple wave
		self.grapple_wave = approach(self.grapple_wave, 0, 0.6)

		-- hold
		if self:overlaps(obj) then
			self.state = 1
			psfx(7, 16, 6)
		end

		-- release
		if not input_grapple or abs(obj.y - self.y + 7) > 8 or sgn(obj.x + 4 - self.x) == -self.grapple_dir then
			self.state = 0
			self.grapple_retract = true
			self:release_holding(obj, -self.grapple_dir * 5, 0, true)
		end

	elseif self.state == 50 then
		-- grapple pickup state
		self.speed_y = min(self.speed_y + 0.8, 4.5)
		self.speed_x = approach(self.speed_x, 0, 0.2)
		if on_ground then
			if self.t_grapple_pickup == 0 then music(39) end
			if self.t_grapple_pickup == 61 then music(-1) end
			if self.t_grapple_pickup == 70 then music(22) end
			if self.t_grapple_pickup > 80 then self.state = 0 end
			self.t_grapple_pickup += 1
		end

	elseif self.state == 99 or self.state == 100 then
		-- dead / finished state

		if self.state == 100 then
			self.x += 1
			if self.wipe_timer == 5 and level_index > 1 then psfx(17, 24, 9) end
		end

		self.wipe_timer += 1
		if self.wipe_timer > 20 then
			if self.state == 99 then restart_level() else next_level() end
		end
		return
	end

	-- apply
	self:move_x(self.speed_x, self.on_collide_x)
	self:move_y(self.speed_y, self.on_collide_y)

	-- holding
	if self.holding then
		self.holding.x = self.x - 4
		self.holding.y = self.y - 14
	end

	-- sprite
	if self.state == 50 and self.t_grapple_pickup > 0 then
		self.spr = 5
	elseif self.state != 11 then
		if not on_ground then
			self.spr = 3
		elseif input_x != 0 then
			self.spr += 0.25
			self.spr = 2 + self.spr % 2
		else
			self.spr = 2
		end
	end

	-- object interactions
	for o in all(objects) do
		if o.base == grapple_pickup and self:overlaps(o) then
			--grapple pickup
			o.destroyed = true
			have_grapple = true
			psfx(7, 12, 4)
			self.state = 50
		elseif o.base == bridge and not o.falling and self:overlaps(o) then
			--falling bridge tile
			o.falling = true
			self.freeze = 1
			shake = 2
			psfx(8, 16, 4)
		elseif o.base == snowball and not o.held then
			--snowball
			if self:bounce_check(o) and o:bounce_overlaps(self) then
				self:bounce(o.x + 4, o.y)
				psfx(17, 0, 2)
				o.freeze = 1
				o.speed_y = -1
				o:hurt()
			elseif o.speed_x != 0 and o.thrown_timer <= 0 and self:overlaps(o) then
				self:die()
				return
			end
		elseif o.base == springboard and self.state != 2 and not o.held and self:overlaps(o) and self:bounce_check(o) then
			--springboard
			self.state = 2
			self.speed_x = 0
			self.speed_y = 0
			self.t_jump_grace = 0
			self.springboard = o
			self.remainder_y = 0
			o.player = self
			self:move_y(o.y + 4 - self.y)
		elseif o.base == berry and self:overlaps(o) then
			--berry
			o:collect(self)
		elseif o.base == crumble and not o.breaking then
			--crumble
			if self.state == 0 and self:overlaps(o, 0, 1) then
				o.breaking = true
				psfx(8, 20, 4)
			elseif self.state == 11 then
				if self:overlaps(o, self.grapple_dir) or self:overlaps(o, self.grapple_dir, 3) or self:overlaps(o, self.grapple_dir, -2) then
					o.breaking = true
					psfx(8, 20, 4)
				end
			end
		elseif o.base == checkpoint and level_checkpoint != o.id and self:overlaps(o) then
			level_checkpoint = o.id
			psfx(8, 24, 6, 20)
		end
	end

	-- death
	if self.state < 99 and (self.y > level.height * 8 + 16 or self:hazard_check()) then
		if level_index == 1 and self.x > level.width * 8 - 64 then
			self.state = 100
			self.wipe_timer = -15
		else
			self:die()
		end
		return
	end

	-- bounds
	if self.y < -16 then
		self.y = -16
		self.speed_y = 0
	end
	if self.x < 3 then
		self.x = 3
		self.speed_x = 0
	elseif self.x > level.width * 8 - 3 then
		if level.right_edge then
			self.x = level.width * 8 - 3
			self.speed_x = 0
		else
			self.state = 100
		end
	end

	-- intro bridge music
	if current_music == levels[1].music and self.x > 61 * 8 then
		current_music = 37
		music(37)
		psfx(17, 24, 9)
	end

	-- ending music
	if level_index == 8 then
		if current_music != 40 and self.y > 40 then
			current_music = 40
			music(40)
		end
		if self.y > 376 then show_score += 1 end
		if show_score == 120 then music(38) end
	end

	-- camera
	camera_modes[level.camera_mode](self.x, self.y, on_ground)
	camera_x = approach(camera_x, camera_target_x, 5)
	camera_y = approach(camera_y, camera_target_y, 5)
	camera(camera_x, camera_y)
end

function player.on_collide_x(self, moved, target)

	if self.state == 0 then
		if sgn(target) == input_x and self:corner_correct(input_x, 0, 2, 2, -1, self.correction_func) then
			return false
		end
	elseif self.state == 11 then
		if self:corner_correct(self.grapple_dir, 0, 4, 2, 0, self.correction_func) then
			return false
		end
	end

	return object.on_collide_x(self, moved, target)
end

function player.on_collide_y(self, moved, target)
	if target < 0 and self:corner_correct(0, -1, 2, 1, input_x, self.correction_func) then
		return false
	end

	self.t_var_jump = 0
	return object.on_collide_y(self, moved, target)
end

function player.draw(self)

	-- death fx
	if self.state == 99 then
		local e = self.wipe_timer / 10
		local dx = mid(camera_x, self.x, camera_x + 128)
		local dy = mid(camera_y, self.y - 4, camera_y + 128)
		if e <= 1 then
			for i=0,7 do
				circfill(dx + cos(i / 8) * 32 * e, dy + sin(i / 8) * 32 * e, (1 - e) * 8, 10)
			end
		end
		return
	end

	-- scarf
	local last = { x = self.x - self.facing,y = self.y - 3 }
	for i=1,#self.scarf do
		local s = self.scarf[i]

		-- approach last pos with an offset
		s.x += (last.x - s.x - self.facing) / 1.5
		s.y += ((last.y - s.y) + sin(i * 0.25 + time()) * i * 0.25) / 2

		-- don't let it get too far
		local dx = s.x - last.x
		local dy = s.y - last.y
		local dist = sqrt(dx * dx + dy * dy)
		if dist > 1.5 then
			local nx = (s.x - last.x) / dist
			local ny = (s.y - last.y) / dist
			