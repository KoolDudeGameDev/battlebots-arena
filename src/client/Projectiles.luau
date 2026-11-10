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
local MapLayout = require(Shared.MapLayout)

local Projectiles = {}

local HEIGHT = 3
local HALF = Config.Arena.HalfSize
local RECORD = 37 -- must match SPAWN_RECORD in server Combat
local FIELD_SLOW = Config.Skills.skl_nullfield.projectileSlow
local NET = Config.Weapons.netgun
local NET_CODE = NET.code

-- trail = seconds a streak lingers behind the shot; sound = the sound leaving the gun.
local LOOKS = {
	[1] = { size = Vector3.new(0.5, 0.5, 1.8), color = Color3.fromRGB(255, 235, 120), trail = 0.08, sound = "Blaster" }, -- blaster
	[2] = { size = Vector3.new(0.35, 0.35, 1.2), color = Color3.fromRGB(230, 230, 255), trail = 0.06, sound = "Gatling" }, -- gatling
	[3] = { size = Vector3.new(0.75, 0.75, 2.4), color = Color3.fromRGB(235, 232, 220), rocket = true, sound = "RocketLaunch" }, -- rockets (D78)
	[4] = { size = Vector3.new(0.55, 0.55, 2.0), color = Color3.fromRGB(255, 150, 40), trail = 0.1, sound = "Blaster" }, -- ricochet
	[5] = { size = Vector3.new(0.3, 0.3, 4.5), color = Color3.fromRGB(90, 230, 255), trail = 0.15, sound = "Railgun" }, -- railgun
	[6] = { size = Vector3.new(3.0, 0.3, 1.2), color = Color3.fromRGB(170, 140, 90), sound = "NetLaunch" }, -- Bomber net (grows as it opens)
}
local MUZZLE_BLEND = 8 -- studs over which a shot drops from its gun's height to the shot plane

type Live = { part: Part, x: number, z: number, dx: number, dz: number, speed: number, accel: number, maxSpeed: number, remaining: number, owner: number, code: number, flown: number, y0: number }

local live: { [number]: Live } = {}
local pools: { [number]: { Part } } = {}
local folder: Folder
local player = Players.LocalPlayer
-- The same walls, pillars, trees and rocks the server uses (MapLayout).
local covers = MapLayout.boxes()
local circles = MapLayout.circles()

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
		fire.Size = NumberSequence.new(1.1, 0.3)
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 230, 140), Color3.fromRGB(255, 90, 30))
		fire.Enabled = false
		fire.Parent = tail
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 150, 60)
		light.Range = 10
		light.Brightness = 2
		light.Parent = tail
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0.35, look.size.Z / 2)
		a0.Parent = p
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, -0.35, look.size.Z / 2)
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
		nose.Range = 4
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
local HIT_STYLE = { [1] = "robot", [2] = "robot", [4] = "robot", [5] = "robot" }

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
			if model and root and model == player.Character then
				local vel = root.AssemblyLinearVelocity
				local lag = math.min(0.3, player:GetNetworkPing() * 2)
				x += vel.X * lag
				z += vel.Z * lag
			end
			-- Shots start at the muzzle's height and drop to the shot plane.
			local body = model and model:FindFirstChild("Body")
			local gun = body and body:FindFirstChild("Gun")
			local y0 = if gun and gun:IsA("BasePart") then gun.Position.Y else HEIGHT
			local p = acquire(code)
			if code == NET_CODE then
				p.Size = look.size
			end
			local pos = Vector3.new(x, y0, z)
			p.CFrame = CFrame.lookAt(pos, pos + Vector3.new(dx, 0, dz))
			setEffects(p, true)
			live[id] = { part = p, x = x, z = z, dx = dx, dz = dz, speed = speed, accel = accel, maxSpeed = maxSpeed, remaining = range, owner = owner, code = code, flown = 0, y0 = y0 }
			-- Feedback at the gun: the sound, the recoil, and a backblast puff for rockets.
			Sfx.at(look.sound, pos)
			if ClientState.actions.kick then
				ClientState.actions.kick(owner)
			end
			if look.rocket then
				Vfx.puff(x - dx * 3, z - dz * 3, 1.2, "none")
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
			if l and l.remaining > 1 and HIT_STYLE[l.code] then
				Vfx.impact(l.x, l.z, HIT_STYLE[l.code], l.dx, l.dz)
				Sfx.at("MetalHit", Vector3.new(l.x, HEIGHT, l.z))
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
			if l.accel > 0 then -- same speed curve as the server (D45)
				l.speed = Combat2D.rocketSpeed(l.speed, l.accel, l.maxSpeed, dt)
			end
			local slow = Combat2D.fieldFactor(l.x, l.z, l.owner, fields, FIELD_SLOW)
			local step = math.min(l.speed * dt * slow, l.remaining)
			local x2, z2 = l.x + l.dx * step, l.z + l.dz * step
			local blocked = math.abs(x2) > HALF or math.abs(z2) > HALF
			local surface = "stone" -- what it hit: trees are wood, everything else stone (D75)
			if not blocked then
				for _, b in covers do
					if Combat2D.segmentBox(l.x, l.z, x2, z2, b.minX, b.minZ, b.maxX, b.maxZ) then
						blocked = true
						break
					end
				end
			end
			if not blocked then
				for _, c in circles do
					if Combat2D.segmentCircle(l.x, l.z, x2, z2, c.x, c.z, c.r) then
						blocked = true
						surface = if c.kind == "tree" then "wood" else "stone"
						break
					end
				end
			end
			if blocked and l.code ~= 3 and l.code ~= NET_CODE then
				Vfx.impact(x2, z2, surface, l.dx, l.dz)
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
				local y = if l.flown < MUZZLE_BLEND then l.y0 + (HEIGHT - l.y0) * (l.flown / MUZZLE_BLEND) else HEIGHT
				local pos = Vector3.new(x2, y, z2)
				l.part.CFrame = CFrame.lookAt(pos, pos + Vector3.new(l.dx, 0, l.dz))
			end
		end
	end)
end

return Projectiles
