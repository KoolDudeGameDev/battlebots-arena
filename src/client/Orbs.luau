-- Renders XP orbs and pods from the server's snapshot and batches. They float
-- above the ground and bob gently (pods also turn), so they read as live
-- pickups and stay visible over tall grass in third-person. Orbs are matte
-- gems, not neon. The Health Pack, Armor Pod and Fortify Pod are 3D models
-- (PickupModels), and so is the gold coin, which spins on its edge (D78).
-- A collected pickup flies to the robot that took it (orbs tint green if that
-- robot has Scavenger).

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local PickupModels = require(script.Parent.PickupModels)
local Sfx = require(script.Parent.Sfx)

local Orbs = {}

local KINDS = { "small", "medium", "core", "death", "health", "regen", "armor", "fortify", "coin" }
local COLORS = {
	small = Color3.fromRGB(90, 230, 120),
	medium = Color3.fromRGB(70, 160, 255),
	core = Color3.fromRGB(175, 95, 255), -- purple: gold is reserved for coins
	death = Color3.fromRGB(255, 70, 70),
	-- Booster pods (D34)
	health = Color3.fromRGB(255, 60, 70),
	regen = Color3.fromRGB(140, 255, 90),
	armor = Color3.fromRGB(90, 200, 255),
}
-- Pods are blocks so they never read as XP orbs; health packs are kept small (D41).
local POD_LOOK = {
	health = { shape = Enum.PartType.Block, size = 1.2 },
	regen = { shape = Enum.PartType.Ball, size = 1.6 },
	armor = { shape = Enum.PartType.Block, size = 1.8 },
}
local FLY_TIME = 0.15
local FLOAT = 1.9 -- gap between the ground and the bottom of an orb, clear of grass blades
local BOB = 0.35 -- studs up and down
local BOB_SPEED = 2.2 -- radians per second
local POD_TURN = 1.2 -- radians per second
local ANIMATE_RADIUS = 140 -- only nearby pickups bob; distant ones hold still (cheap)

-- A pickup is either a pooled Part (orbs and regen pods) or a Model
-- (health, armor and fortify), never both.
type Floater = { part: Part?, model: Model?, x: number, y: number, z: number, phase: number, pod: boolean, spin: boolean?, kind: string }
local floaters: { [number]: Floater } = {}
local orbs: { [number]: Floater } = {}
local pool: { Part } = {}
local flying: { { f: Floater, from: Vector3, target: Model?, t: number } } = {}
local folder: Folder

local function acquire(): Part
	local p = table.remove(pool)
	if p then
		return p
	end
	p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.SmoothPlastic -- matte gem: no neon glow
	p.Reflectance = 0.15
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = folder
	return p
end

local function stash(p: Part)
	p.CFrame = CFrame.new(0, -500, 0)
	table.insert(pool, p)
end

-- Removes a pickup's visual: pooled parts go back to the pool, models are destroyed.
local function release(f: Floater)
	if f.part then
		stash(f.part)
	elseif f.model then
		f.model:Destroy()
	end
end

local function position(f: Floater): Vector3
	if f.part then
		return f.part.Position
	end
	return (f.model :: Model):GetPivot().Position
end

-- Entry: { id, kindCode, x, z [, value] }
local function create(entry: { number })
	local id, code, x, z, value = entry[1], entry[2], entry[3], entry[4], entry[5]
	local kind = KINDS[code]
	if not kind or orbs[id] then
		return
	end
	local phase = (x * 0.37 + z * 0.61) % (2 * math.pi) -- neighbours bob out of step

	-- Health, armor and fortify are 3D models (a medkit, an armor vest and a heart).
	local model = PickupModels.create(kind)
	if model then
		local _, size = model:GetBoundingBox()
		local y = FLOAT + size.Y / 2
		model:PivotTo(CFrame.new(x, y, z))
		model.Parent = folder
		local f: Floater = { part = nil, model = model, x = x, y = y, z = z, phase = phase, pod = true, spin = kind == "coin", kind = kind }
		orbs[id] = f
		floaters[id] = f
		return
	end

	local pod = POD_LOOK[kind]
	local size = if pod then pod.size else Config.Orbs[kind].size
	if kind == "death" and value then
		size *= math.clamp(0.8 + value / 200, 0.8, 2.2)
	end
	local p = acquire()
	p.Shape = if pod then pod.shape else Enum.PartType.Ball
	p.Size = Vector3.one * size
	p.Material = Enum.Material.SmoothPlastic
	p.Color = COLORS[kind]
	local y = FLOAT + size / 2
	-- Pods sit tilted 45 degrees so they read as pickups, not orbs.
	p.CFrame = CFrame.new(x, y, z) * (if pod then CFrame.Angles(0, math.rad(45), math.rad(45)) else CFrame.identity)
	local f: Floater = { part = p, model = nil, x = x, y = y, z = z, phase = phase, pod = pod ~= nil, kind = kind }
	orbs[id] = f
	floaters[id] = f
end

local animParts: { BasePart } = {}
local animCFrames: { CFrame } = {}

-- Bobs every pickup near the camera in one BulkMoveTo call per frame.
local function animate(t: number)
	local cam = Workspace.CurrentCamera
	local focus = if cam then cam.Focus.Position else Vector3.zero
	local character = Players.LocalPlayer.Character
	local root = character and character.PrimaryPart
	if root then
		focus = root.Position
	end
	table.clear(animParts)
	table.clear(animCFrames)
	local r2 = ANIMATE_RADIUS * ANIMATE_RADIUS
	for _, f in floaters do
		local dx, dz = f.x - focus.X, f.z - focus.Z
		if dx * dx + dz * dz <= r2 then
			local y = f.y + math.sin(t * BOB_SPEED + f.phase) * BOB
			local cf = CFrame.new(f.x, y, f.z)
			if f.model then
				-- Models stay upright and turn slowly, like a game pickup; coins spin on edge.
				f.model:PivotTo(cf * CFrame.Angles(0, t * (if f.spin then 3 else POD_TURN) + f.phase, 0))
			elseif f.part then
				if f.pod then
					cf *= CFrame.Angles(0, t * POD_TURN + f.phase, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45))
				end
				table.insert(animParts, f.part)
				table.insert(animCFrames, cf)
			end
		end
	end
	if #animParts > 0 then
		Workspace:BulkMoveTo(animParts, animCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function robotByUserId(userId: number): Model?
	if userId == 0 then
		return nil
	end
	for _, m in CollectionService:GetTagged("Robot") do
		if m:GetAttribute("UserId") == userId and m:IsA("Model") then
			return m
		end
	end
	return nil
end

function Orbs.init(fx: Folder)
	folder = fx

	Remotes.OrbsSnapshot.OnClientEvent:Connect(function(list)
		for _, f in orbs do
			release(f)
		end
		table.clear(orbs)
		table.clear(floaters)
		for _, entry in list do
			create(entry)
		end
	end)
	Remotes.OrbsSpawned.OnClientEvent:Connect(function(list)
		for _, entry in list do
			create(entry)
		end
	end)
	Remotes.OrbsCollected.OnClientEvent:Connect(function(flat)
		for i = 1, #flat - 1, 2 do
			local f = orbs[flat[i]]
			if f then
				orbs[flat[i]] = nil
				floaters[flat[i]] = nil
				local target = robotByUserId(flat[i + 1])
				if f.kind == "coin" and target and target == Players.LocalPlayer.Character then
					Sfx.ui("Coin")
				end
				if target then
					if target:GetAttribute("Scavenger") and f.part then
						f.part.Color = Color3.fromRGB(120, 255, 140)
					end
					table.insert(flying, { f = f, from = position(f), target = target, t = 0 })
				else
					release(f)
				end
			end
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		animate(os.clock())
		for i = #flying, 1, -1 do
			local f = flying[i]
			f.t += dt
			local root = f.target and f.target.PrimaryPart
			if not root or f.t >= FLY_TIME then
				release(f.f)
				table.remove(flying, i)
			else
				local cf = CFrame.new(f.from:Lerp(root.Position, f.t / FLY_TIME))
				if f.f.part then
					f.f.part.CFrame = cf
				elseif f.f.model then
					f.f.model:PivotTo(cf)
				end
			end
		end
	end)
end

return Orbs
