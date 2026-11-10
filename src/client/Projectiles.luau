-- Draws projectiles from the server's spawn batches. Each one flies the same
-- straight line the server simulates and stops at walls, cover, range end, or
-- when the server says it hit something. Purely visual.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Combat2D = require(Shared.Combat2D)
local Vfx = require(script.Parent.Vfx)
local MapLayout = require(Shared.MapLayout)

local Projectiles = {}

local HEIGHT = 3
local HALF = Config.Arena.HalfSize
local RECORD = 37 -- must match SPAWN_RECORD in server Combat
local FIELD_SLOW = Config.Skills.skl_nullfield.projectileSlow
local NET = Config.Weapons.netgun
local NET_CODE = NET.code

local LOOKS = {
	[1] = { size = Vector3.new(0.5, 0.5, 1.8), color = Color3.fromRGB(255, 235, 120) }, -- blaster
	[2] = { size = Vector3.new(0.35, 0.35, 1.2), color = Color3.fromRGB(230, 230, 255) }, -- gatling
	[3] = { size = Vector3.new(0.8, 0.8, 1.8), color = Color3.fromRGB(255, 90, 60) }, -- rockets
	[4] = { size = Vector3.new(0.55, 0.55, 2.0), color = Color3.fromRGB(255, 150, 40) }, -- ricochet
	[5] = { size = Vector3.new(0.3, 0.3, 4.5), color = Color3.fromRGB(90, 230, 255) }, -- railgun
	[6] = { size = Vector3.new(3.0, 0.3, 1.2), color = Color3.fromRGB(170, 140, 90) }, -- Bomber net (grows as it opens)
}

type Live = { part: Part, x: number, z: number, dx: number, dz: number, speed: number, accel: number, maxSpeed: number, remaining: number, owner: number, code: number, flown: number }

local live: { [number]: Live } = {}
local pool: { Part } = {}
local folder: Folder
-- The same walls, pillars, trees and rocks the server uses (MapLayout).
local covers = MapLayout.boxes()
local circles = MapLayout.circles()

local function acquire(): Part
	local p = table.remove(pool)
	if p then
		return p
	end
	p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Parent = folder
	return p
end

-- What a shot that the server ended (it hit a robot or crate) looks like (D75).
-- Rockets explode and nets land through their own server effects.
local HIT_STYLE = { [1] = "robot", [2] = "robot", [4] = "robot", [5] = "robot" }

local function release(id: number)
	local l = live[id]
	if l then
		live[id] = nil
		l.part.CFrame = CFrame.new(0, -500, 0)
		table.insert(pool, l.part)
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
			local look = LOOKS[code] or LOOKS[1]
			local p = acquire()
			p.Size = look.size
			p.Color = look.color
			live[id] = { part = p, x = x, z = z, dx = math.cos(angle), dz = math.sin(angle), speed = speed, accel = accel, maxSpeed = maxSpeed, remaining = range, owner = owner, code = code, flown = 0 }
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
				local pos = Vector3.new(x2, HEIGHT, z2)
				l.part.CFrame = CFrame.lookAt(pos, pos + Vector3.new(l.dx, 0, l.dz))
			end
		end
	end)
end

return Projectiles
