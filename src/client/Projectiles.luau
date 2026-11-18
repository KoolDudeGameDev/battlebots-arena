-- Draws projectiles from the server's spawn batches. Each one flies the same
-- straight line the server simulates and stops at walls, cover, range end, or
-- when the server says it hit something. Purely visual.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Combat2D = require(Shared.Combat2D)
local Vfx = require(script.Parent.Vfx)
local Sfx = require(script.Parent.Sfx)
local ClientState = require(script.Parent.ClientState)
local MapLayouts = require(Shared.MapLayouts)
local MapQuery = require(Shared.MapQuery)

local Projectiles = {}

local HEIGHT = 3
local RECORD = 37 -- must match SPAWN_RECORD in server Combat
local FIELD_SLOW = Config.Skills.skl_nullfield.projectileSlow
local NET = Config.Weapons.netgun
local NET_CODE = NET.code

-- trail = seconds a streak lingers behind the shot; sound = the sound leaving the gun.
local LOOKS = {
	[1] = { size = Vector3.new(0.5, 0.5, 1.8), color = Color3.fromRGB(255, 235, 120), trail = 0.08, sound = "Blaster" }, -- blaster
	[2] = { size = Vector3.new(0.35, 0.35, 1.2), color = Color3.fromRGB(230, 230, 255), trail = 0.06, sound = "Gatling" }, -- gatling
	[3] = { size = Vector3.new(0.45, 0.45, 1.5), color = Color3.fromRGB(235, 232, 220), rocket = true, corkscrew = true, sound = "RocketLaunch" }, -- Rocket Pod mini-rockets (D78, D82)
	[4] = { size = Vector3.new(0.55, 0.55, 2.0), color = Color3.fromRGB(255, 150, 40), trail = 0.1, sound = "Blaster" }, -- ricochet
	[5] = { size = Vector3.new(0.3, 0.3, 4.5), color = Color3.fromRGB(90, 230, 255), trail = 0.15, sound = "Railgun" }, -- railgun
	[6] = { size = Vector3.new(3.0, 0.3, 1.2), color = Color3.fromRGB(170, 140, 90), sound = "NetLaunch" }, -- Bomber net (grows as it opens)
	[7] = { size = Vector3.new(1.5, 1.5, 4.8), color = Color3.fromRGB(235, 232, 220), rocket = true, sound = "RocketLaunch" }, -- Bombard rockets, doubled (D80)
	[8] = { size = Vector3.new(0.3, 0.3, 0.9), color = Color3.fromRGB(255, 190, 80), trail = 0.05, sound = "Gatling" }, -- Bomber core's Scrap Cannon pellets (D84)
}
LOOKS[Config.RicochetBounceCode] = LOOKS[Config.RicochetCode] -- a bounce looks like the shot that bounced
-- Shots fly level at the height they leave the gun (D82: they used to dip to a fixed
-- plane, which read as curving). A mount's shot starts at that mount's muzzle and
-- closes onto the server's line over MUZZLE_BLEND studs, in a straight line.
local MUZZLE_BLEND = 10
-- Which mount fires each kind of shot (D82); other kinds come from the main gun.
local MOUNT_OF: { [number]: string } = { [2] = "wpn_gatling", [3] = "wpn_rocket", [5] = "wpn_railgun" }

type Live = { part: Part, x: number, z: number, dx: number, dz: number, speed: number, accel: number, maxSpeed: number, remaining: number, owner: number, code: number, flown: number, y0: number, offX: number, offZ: number, spin: number, born: number, life: number }

local live: { [number]: Live } = {}
local pools: { [number]: { Part } } = {}
local folder: Folder
local player = Players.LocalPlayer
-- The same cover the server uses: the current map's layout (D81), minus the
-- pieces a boss has smashed.
local Workspace = game:GetService("Workspace")
local map = MapLayouts[Workspace:GetAttribute("Map") or "grassland"] or MapLayouts.grassland
local broken: { [number]: boolean } = {}
Workspace:GetAttributeChangedSignal("Map"):Connect(function()
	map = MapLayouts[Workspace:GetAttribute("Map")] or MapLayouts.grassland
end)
-- The server lists smashed pieces as "key,key," (reset to "" on every map load).
local function readBroken()
	broken = {}
	local list = Workspace:GetAttribute("CoverBroken")
	if type(list) == "string" then
		for key in string.gmatch(list, "%d+") do
			broken[tonumber(key) :: number] = true
		end
	end
end
readBroken()
Workspace:GetAttributeChangedSignal("CoverBroken"):Connect(readBroken)
-- What a shot sounds and looks like when it hits each kind of cover (Vfx.impact styles).
local SURFACE = { wood = "wood", metal = "robot", scrap = "robot" }

-- Shots are pooled per kind, so each kind's trail and exhaust are built once.
local function acquire(code: number): Part
	local pool = pools[code]
	if not pool then
		pool = {}
		pools[code] = pool
	end
	local p = table.remove(pool)
	if p then
		return p
	end
	local look = LOOKS[code] or LOOKS[1]
	p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = look.size
	p.Color = look.color
	if look.rocket then
		-- A white rocket body with a red nose glow, an exhaust flame, a light and a
		-- long smoke trail, so you can follow it from behind in third-person (D78).
		p.Material = Enum.Material.Metal
		local tail = Instance.new("Attachment")
		tail.Name = "Tail"
		tail.Position = Vector3.new(0, 0, look.size.Z / 2)
		tail.Parent = p
		local fire = Instance.new("ParticleEmitter")
		fire.Name = "Exhaust"
		fire.Texture = "rbxasset://textures/particles/fire_main.dds"
		fire.EmissionDirection = Enum.NormalId.Back
		fire.Rate = 90
		fire.Speed = NumberRange.new(6, 10)
		fire.Lifetime = NumberRange.new(0.08, 0.16)
		fire.LightEmission = 1
		fire.Size = NumberSequence.new(look.size.X * 1.45, look.size.X * 0.4)
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 230, 140), Color3.fromRGB(255, 90, 30))
		fire.Enabled = false
		fire.Parent = tail
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 150, 60)
		light.Range = look.size.X * 13
		light.Brightness = 2
		light.Parent = tail
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, look.size.Y * 0.47, look.size.Z / 2) -- trail as wide as the rocket (D80)
		a0.Parent = p
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -look.size.Y * 0.47, look.size.Z / 2)
		a1.Parent = p
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.7
		trail.Texture = "rbxasset://textures/particles/smoke_main.dds"
		trail.Color = ColorSequence.new(Color3.fromRGB(235, 225, 210), Color3.fromRGB(140, 136, 130))
		trail.Transparency = NumberSequence.new(0.25, 1)
		trail.WidthScale = NumberSequence.new(0.6, 2.2)
		trail.Enabled = false
		trail.Parent = p
		local nose = Instance.new("SurfaceLight")
		nose.Face = Enum.NormalId.Front
		nose.Color = Color3.fromRGB(255, 70, 50)
		nose.Range = look.size.X * 5.3
		nose.Parent = p
	elseif look.trail then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, look.size.Y / 2, 0)
		a0.Parent = p
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -look.size.Y / 2, 0)
		a1.Parent = p
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = look.trail
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(look.color)
		trail.Transparency = NumberSequence.new(0.3, 1)
		trail.Enabled = false
		trail.Parent = p
	end
	p.Parent = folder
	return p
end

-- Turns a pooled shot's trail and exhaust on or off. Clearing the trail stops a
-- reused shot from drawing a streak from where it was parked.
local function setEffects(p: Part, on: boolean)
	local trail = p:FindFirstChildOfClass("Trail")
	if trail then
		trail.Enabled = on
		trail:Clear()
	end
	local tail = p:FindFirstChild("Tail")
	local fire = tail and tail:FindFirstChild("Exhaust") :: ParticleEmitter?
	if fire then
		fire.Enabled = on
	end
end

-- The robot that fired a shot, by its entity id.
local function ownerModel(owner: number): Model?
	for _, m in CollectionService:GetTagged("Robot") do
		if m:IsA("Model") and m:GetAttribute("EntityId") == owner then
			return m
		end
	end
	return nil
end

-- What a shot that the server ended (it hit a robot or crate) looks like (D75).
-- Rockets explode and nets land through their own server effects.
local HIT_STYLE = { [1] = "robot", [2] = "robot", [4] = "robot", [5] = "robot", [8] = "robot", [Config.RicochetBounceCode] = "robot" }

-- A shot hitting cover: chips, dust or leaves, and the sound of what it is made of.
local COVER_SOUND: { [string]: string } = { stone = "Rubble", robot = "MetalHit" } -- wood: the leaves and chips are enough
local function coverHit(x: number, z: number, surface: string, l: Live)
	Vfx.impact(x, z, surface, l.dx, l.dz, l.y0)
	local sound = COVER_SOUND[surface]
	if sound then
		Sfx.at(sound, Vector3.new(x, l.y0, z), 0.5)
	end
end

-- Cover the shot is about to hit (within the next ~0.4 s of flight) with no robot in
-- front of it: where, and its surface. Nil if the shot must have hit a robot or crate.
local function coverAhead(l: Live): (number?, number?, string)
	local reach = math.max(6, l.speed * 0.4)
	local x2, z2 = l.x + l.dx * reach, l.z + l.dz * reach
	local t, kind = MapQuery.blockedAt(map, l.x, l.z, x2, z2, 0, broken)
	if not t then
		return nil, nil, ""
	end
	local hx, hz = l.x + (x2 - l.x) * t, l.z + (z2 - l.z) * t
	local along = reach * t
	for _, m in CollectionService:GetTagged("Robot") do
		local root = (m :: Model).PrimaryPart
		if root and m:GetAttribute("EntityId") ~= l.owner then
			local rx, rz = root.Position.X - l.x, root.Position.Z - l.z
			local d = rx * l.dx + rz * l.dz -- distance along the shot
			local side = math.abs(rx * l.dz - rz * l.dx)
			if d > -2 and d < along + 1 and side < (m:GetAttribute("HitRadius") or 3) + 1 then
				return nil, nil, "" -- a robot is in the way: it hit the robot
			end
		end
	end
	return hx, hz, SURFACE[kind or ""] or "stone"
end

local function release(id: number)
	local l = live[id]
	if l then
		live[id] = nil
		setEffects(l.part, false)
		l.part.CFrame = CFrame.new(0, -500, 0)
		table.insert(pools[l.code], l.part)
	end
end

function Projectiles.init(fx: Folder)
	folder = fx

	Remotes.ProjectilesSpawned.OnClientEvent:Connect(function(buf: buffer)
		if typeof(buf) ~= "buffer" then
			return
		end
		for o = 0, buffer.len(buf) - RECORD, RECORD do
			local id = buffer.readu32(buf, o)
			local code = buffer.readu8(buf, o + 4)
			local x = buffer.readf32(buf, o + 5)
			local z = buffer.readf32(buf, o + 9)
			local angle = buffer.readf32(buf, o + 13)
			local speed = buffer.readf32(buf, o + 17)
			local range = buffer.readf32(buf, o + 21)
			local accel = buffer.readf32(buf, o + 25)
			local maxSpeed = buffer.readf32(buf, o + 29)
			local owner = buffer.readu32(buf, o + 33)
			if not LOOKS[code] then
				code = 1
			end
			local look = LOOKS[code]
			local dx, dz = math.cos(angle), math.sin(angle)
			-- Your own shots leave from where your robot is now, not where the server
			-- last saw it (that lags by about a round trip while you drive, D78).
			local model = ownerModel(owner)
			local root = model and model.PrimaryPart
			-- A bounced Blaster shot starts where it hit, not at a gun.
			local fromGun = code ~= Config.RicochetBounceCode
			if fromGun and model and root and model == player.Character then
				local vel = root.AssemblyLinearVelocity
				local lag = math.min(0.3, player:GetNetworkPing() * 2)
				x += vel.X * lag
				z += vel.Z * lag
			end
			-- Where the shot visibly leaves: a mount's muzzle (which also swings to face
			-- the shot), else the main gun's height above the server's start point.
			local mount = MOUNT_OF[code]
			local muzzle = if mount and ClientState.actions.mountShot then ClientState.actions.mountShot(owner, mount, angle) else nil
			local body = model and model:FindFirstChild("Body")
			local gun = body and body:FindFirstChild("Gun")
			local y0 = if muzzle then muzzle.Y elseif gun and gun:IsA("BasePart") then gun.Position.Y else HEIGHT
			local offX, offZ = 0, 0
			if muzzle then
				offX, offZ = muzzle.X - x, muzzle.Z - z
			end
			local p = acquire(code)
			if code == NET_CODE then
				p.Size = look.size
			end
			local pos = Vector3.new(x + offX, y0, z + offZ)
			p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(dx, 0, dz))
			setEffects(p, true)
			live[id] = { part = p, x = x, z = z, dx = dx, dz = dz, speed = speed, accel = accel, maxSpeed = maxSpeed, remaining = range, owner = owner, code = code, flown = 0, y0 = y0, offX = offX, offZ = offZ, spin = math.random() * math.pi * 2,
				-- The longest this shot can fly: its whole range at launch speed, slowed by a Null Field the whole way.
				born = os.clock(), life = range / math.max(1, speed) / FIELD_SLOW + 1 }
			-- Feedback at the gun: the sound, the recoil, and a backblast puff for rockets.
			Sfx.at(look.sound, pos)
			if not mount and fromGun and ClientState.actions.kick then
				ClientState.actions.kick(owner)
			end
			if look.rocket then
				Vfx.puff(pos.X - dx * 2, pos.Z - dz * 2, if look.corkscrew then 0.8 else 1.2, "none")
			end
		end
	end)

	Remotes.ProjectilesEnded.OnClientEvent:Connect(function(buf: buffer)
		if typeof(buf) ~= "buffer" then
			return
		end
		for o = 0, buffer.len(buf) - 4, 4 do
			local id = buffer.readu32(buf, o)
			local l = live[id]
			-- Ended early by the server: it hit something. At the end of its range it just fades.
			-- The server is ahead of this drawing, so its "ended" often arrives before the
			-- shot visibly reaches what it hit: if cover is just ahead and no robot is in
			-- between, it hit the cover (a tree must not clang like a robot).
			if l and l.remaining > 1 and HIT_STYLE[l.code] then
				local cx, cz, surface = coverAhead(l)
				if cx and cz then
					coverHit(cx, cz, surface, l)
				else
					Vfx.impact(l.x, l.z, HIT_STYLE[l.code], l.dx, l.dz, l.y0)
					Sfx.at("MetalHit", Vector3.new(l.x, l.y0, l.z))
				end
			end
			release(id)
		end
	end)

	local fields: { any } = {}
	RunService.RenderStepped:Connect(function(dt)
		-- Active Null Fields (D68), from the robots' Field attribute.
		table.clear(fields)
		for _, model in CollectionService:GetTagged("Robot") do
			local r = model:GetAttribute("Field")
			local root = (model :: Model).PrimaryPart
			if type(r) == "number" and r > 0 and root then
				table.insert(fields, { x = root.Position.X, z = root.Position.Z, r = r, owner = model:GetAttribute("EntityId") })
			end
		end
		for id, l in live do
			-- A shot still here after the longest flight it could have is stuck (a play
			-- tester saw Bombard rockets hang in mid-air on a phone): log it and drop it.
			if os.clock() - l.born > l.life then
				warn(string.format("[Projectiles] stuck shot %d dropped: kind %d, speed %.1f, %.1f range left, flew %.1f", id, l.code, l.speed, l.remaining, l.flown))
				release(id)
				continue
			end
			if l.accel > 0 then -- same speed curve as the server (D45)
				l.speed = Combat2D.rocketSpeed(l.speed, l.accel, l.maxSpeed, dt)
			end
			local slow = Combat2D.fieldFactor(l.x, l.z, l.owner, fields, FIELD_SLOW)
			local step = math.min(l.speed * dt * slow, l.remaining)
			local x2, z2 = l.x + l.dx * step, l.z + l.dz * step
			local blocked = math.abs(x2) > map.half or math.abs(z2) > map.half
			local surface = "stone" -- what it hit (D75): wood, metal sparks, or stone
			if not blocked then
				local t, kind = MapQuery.blockedAt(map, l.x, l.z, x2, z2, 0, broken)
				if t then
					blocked = true
					surface = SURFACE[kind or ""] or "stone"
				end
			end
			if blocked and not (LOOKS[l.code] or LOOKS[1]).rocket and l.code ~= NET_CODE then
				coverHit(x2, z2, surface, l)
			end
			l.x, l.z = x2, z2
			l.remaining -= step
			l.flown += step
			if l.code == NET_CODE then -- the net opens in flight, as on the server (D72)
				local r = math.min(NET.openRadius, NET.radius + l.flown * NET.openPerStud)
				l.part.Size = Vector3.new(r * 2, 0.3, math.max(1.2, r * 0.8))
			end
			if blocked or l.remaining <= 1e-3 then
				release(id)
			else
				-- Level flight at the muzzle's height; a mount's offset shrinks to nothing
				-- over MUZZLE_BLEND studs (a straight line onto the server's path).
				local left = math.max(0, 1 - l.flown / MUZZLE_BLEND)
				local px, pz = x2 + l.offX * left, z2 + l.offZ * left
				local headX, headZ = l.dx, l.dz
				if left > 0 then
					headX, headZ = l.dx * MUZZLE_BLEND - l.offX, l.dz * MUZZLE_BLEND - l.offZ
				end
				local py = l.y0
				if (LOOKS[l.code] or LOOKS[1]).corkscrew then -- mini-rockets wobble as they fly
					local w = math.min(1, l.flown / 6) * 0.35
					local a = l.spin + l.flown * 0.5
					px += -l.dz * math.cos(a) * w
					pz += l.dx * math.cos(a) * w
					py += math.sin(a) * w
				end
				local pos = Vector3.new(px, py, pz)
				l.part.CFrame = CFrame.lookAt(pos, pos + Vector3.new(headX, 0, headZ))
			end
		end
	end)
end

return Projectiles
