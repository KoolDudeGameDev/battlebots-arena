-- Builds the robot from primitives. The character template holds only
-- HumanoidRootPart, Head and Humanoid; everything you see lives in a cosmetic
-- "Body" folder rebuilt when the build, level band or visual size changes.
-- The physical root never resizes (resizing it caused the level-up glitch).
--
-- What the body shows (visual evolution v2):
--   robot type   Rookie blaster turret, Brawler buzzsaw, Scorcher flamethrower, Bombard launcher
--   level band   Lv 20 accent stripes, 40 tracks, 60 armoured hull, 80 crest, 100 gold trim
--   upgrades     barrels per Extra Barrel, barrel thickness per Damage stack, plates for armor,
--                batteries for HP, wheels/fins for speed, antenna/dish for pickup
--   mounts       each weapon grows 15% per rank; the highest-rank one (signature) is 25% bigger
-- Phase 3 art will swap these primitives for modeled parts on the same offsets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Stats = require(Shared.Stats)
local Upgrades = require(Shared.Upgrades)

local RobotBuilder = {}

local R = Config.Robot
-- Realistic materials (D77): painted metal panels, gunmetal frames, brushed steel,
-- rubber tyres, brass trim. Neon is kept for lights and energy weapons only.
local DARK = Color3.fromRGB(52, 54, 58) -- gunmetal
local STEEL = Color3.fromRGB(128, 131, 136) -- brushed steel
local RUBBER = Color3.fromRGB(30, 30, 32)
local BRASS = Color3.fromRGB(176, 140, 64)
local HAZARD = Color3.fromRGB(206, 162, 42) -- warning-stripe yellow

local function shade(c: Color3, k: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), k)
end

function RobotBuilder.installStarterCharacter()
	local model = Instance.new("Model")
	model.Name = "StarterCharacter"

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(R.RootSize[1], R.RootSize[2], R.RootSize[3])
	root.Transparency = 1
	root.CanCollide = true
	root.CFrame = CFrame.new(0, R.HipHeight + R.RootSize[2] / 2, 0)
	root.Parent = model

	-- Humanoid rigs expect a Head; this one is invisible and welded to the root.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1, 1, 1)
	head.Transparency = 1
	head.CanCollide = false
	head.Massless = true
	head.CFrame = root.CFrame
	head.Parent = model
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = head
	weld.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.HipHeight = R.HipHeight
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = 0 -- also hides the mobile jump button
	humanoid.WalkSpeed = R.MoveSpeed
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = StarterPlayer
end

-- Part helpers ------------------------------------------------------------------

local function makePart(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Parent = parent
	return p
end

local function weldTo(anchor: BasePart, p: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = anchor
	w.Part1 = p
	w.Parent = p
end

-- s = visual scale; lift raises everything welded to the root so the bigger
-- body still stands on the ground (the root itself never moves or resizes).
type Ctx = { folder: Folder, s: number, lift: number, root: BasePart }

-- Offsets and sizes are in unscaled studs.
local function attach(ctx: Ctx, anchor: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local s = ctx.s
	local lift = if anchor == ctx.root then ctx.lift else 0
	local scaled = CFrame.new(offset.Position * s + Vector3.new(0, lift, 0)) * offset.Rotation
	local p = makePart(ctx.folder, name, size * s, anchor.CFrame * scaled, color, material)
	if shape then
		p.Shape = shape
	end
	weldTo(anchor, p)
	return p
end

-- Parts your own camera looks through in third-person (D72): clients fade them
-- for the robot's owner only, so a big hammer or saw never blocks the view.
local function fade(p: Instance)
	p:SetAttribute("ViewFade", true)
end

local function tier(stacks: number, first: number, second: number): number
	if stacks >= second then
		return 2
	elseif stacks >= first then
		return 1
	end
	return 0
end

-- A part on a Motor6D, so clients can rotate it locally (turret, saw).
local function motorPart(ctx: Ctx, anchor: BasePart, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?): (Part, Motor6D)
	local s = ctx.s
	local lift = if anchor == ctx.root then ctx.lift else 0
	local c0 = CFrame.new(offset * s + Vector3.new(0, lift, 0))
	local p = makePart(ctx.folder, name, size * s, anchor.CFrame * c0, color, material)
	if shape then
		p.Shape = shape
	end
	local motor = Instance.new("Motor6D")
	motor.Name = name .. "Motor"
	motor.Part0 = anchor
	motor.Part1 = p
	motor.C0 = c0
	motor.Parent = p
	return p, motor
end

-- Melee visuals match the real hit area (D71) --------------------------------------

-- Studs of weapon reach (beyond the hitbox) in unscaled body units: the body is
-- drawn at visualScale x bodySize, the hitbox is HitboxRadius x the same.
local function reachU(build, studs: number): number
	local rangeMult = 1 + (build.stacks.stat_range or 0) * Config.StatPerStack.stat_range
	return studs * rangeMult / Stats.bodySize(build)
end

-- Ground height relative to the turret centre, in unscaled units (wheels touch -2.0 below the root).
local GROUND_FROM_TURRET = -2.0 - R.TurretHeight

-- An overhead hammer on a hub on the turret, built in its impact pose: the head on
-- the ground `impactZ` in front. Clients rotate the hub from 180 degrees (raised
-- behind) to 0 on every smash, counted by the model attribute `counter`.
local function buildSmashHammer(ctx: Ctx, turret: BasePart, hubName: string, counter: string, pivot: Vector3, impactZ: number, headWidth: number, thick: number)
	local hub = motorPart(ctx, turret, hubName, Vector3.new(0.6, 0.6, 0.6), pivot, DARK, Enum.Material.Metal, Enum.PartType.Ball)
	hub:SetAttribute("SmashCounter", counter)
	fade(hub)
	local head = Vector3.new(0, GROUND_FROM_TURRET + thick / 2, impactZ) - pivot
	fade(attach(ctx, hub, hubName .. "Haft", Vector3.new(0.35, 0.35, head.Magnitude), CFrame.lookAt(head / 2, head), Color3.fromRGB(110, 75, 45), Enum.Material.Wood))
	fade(attach(ctx, hub, hubName .. "Head", Vector3.new(headWidth, thick, thick), CFrame.lookAt(head, head * 2), DARK, Enum.Material.Metal))
	for _, x in { -1, 1 } do
		fade(attach(ctx, hub, hubName .. "Face", Vector3.new(0.2, thick * 0.8, thick * 0.8), CFrame.lookAt(head, head * 2) * CFrame.new(x * headWidth / 2, 0, 0), STEEL, Enum.Material.DiamondPlate))
	end
end

-- Mounted weapons -----------------------------------------------------------------

local MOUNT_OFFSETS = {
	MountLeft = Vector3.new(-1.85, 0.75, 0.5),
	MountRight = Vector3.new(1.85, 0.75, 0.5),
	MountBack = Vector3.new(0, 0.75, 1.85),
}

-- Weapons grow 15% per rank (D36); the signature weapon gets another 25%.
local function buildMount(ctx: Ctx, turret: BasePart, socket: string, weaponId: string, rank: number, signature: boolean)
	local k = (1 + Config.MountRankScale * (rank - 1)) * (if signature then 1.25 else 1)
	local o = MOUNT_OFFSETS[socket] + Vector3.new(0, 0.4 * (k - 1), 0)
	local root = ctx.root
	local function part(name: string, size: Vector3, local_: Vector3, color: Color3, material: Enum.Material, rotation: CFrame?, shape: Enum.PartType?)
		attach(ctx, root, name, size * k, CFrame.new(o + local_ * k) * (rotation or CFrame.identity), color, material, shape)
	end
	local sideways = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis (X) turned to point forward (-Z)
	local upright = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis turned to point up

	if weaponId == "wpn_gatling" then
		part("Gatling", Vector3.new(0.9, 0.8, 1.4), Vector3.zero, DARK, Enum.Material.Metal)
		for i = 1, rank do
			local x = (i - (rank + 1) / 2) * 0.22
			part("GatlingBarrel", Vector3.new(0.18, 0.18, 1.4), Vector3.new(x, 0.1, -1.3), STEEL, Enum.Material.Metal)
		end
	elseif weaponId == "wpn_rocket" then
		part("RocketPod", Vector3.new(1.2, 0.9, 1.2), Vector3.zero, Color3.fromRGB(110, 120, 90), Enum.Material.Metal)
		local tubes = Stats.rocketCount(rank) + 1
		for i = 1, tubes do
			local x = (i - (tubes + 1) / 2) * 0.32
			part("RocketTube", Vector3.new(0.6, 0.28, 0.28), Vector3.new(x, 0.15, -0.65), Color3.fromRGB(165, 46, 36), Enum.Material.Metal, sideways, Enum.PartType.Cylinder)
		end
	elseif weaponId == "wpn_railgun" then
		for _, x in { -0.22, 0.22 } do
			part("Rail", Vector3.new(0.15, 0.25, 3.2), Vector3.new(x, 0.1, -0.8), DARK, Enum.Material.Metal)
		end
		for i = 1, rank do
			part("RailCoil", Vector3.new(0.25, 0.7, 0.7), Vector3.new(0, 0.1, 0.4 - i * 0.45), Color3.fromRGB(80, 220, 255), Enum.Material.Neon, sideways, Enum.PartType.Cylinder)
		end
	elseif weaponId == "wpn_shock" then
		part("ShockBase", Vector3.new(1.1, 0.4, 1.1), Vector3.zero, DARK, Enum.Material.Metal)
		for i = 1, rank do
			part("ShockRing", Vector3.new(0.12, 0.9, 0.9), Vector3.new(0, 0.25 + i * 0.22, 0), Color3.fromRGB(120, 200, 255), Enum.Material.Neon, upright, Enum.PartType.Cylinder)
		end
		part("ShockOrb", Vector3.new(0.6, 0.6, 0.6), Vector3.new(0, 0.5 + rank * 0.22, 0), Color3.fromRGB(200, 240, 255), Enum.Material.Neon, nil, Enum.PartType.Ball)
	elseif weaponId == "wpn_spikeram" then
		-- Minotaur Horns: always on the front, whatever socket they took. Two big
		-- horns sweep out and up; a bull plate sits between them.
		local horn = Color3.fromRGB(235, 225, 200)
		for _, side in { -1, 1 } do
			attach(ctx, root, "HornBase", Vector3.new(0.7, 0.7, 1.6) * k, CFrame.new(side * 1.5, 0.1, -2.6) * CFrame.Angles(math.rad(15), math.rad(side * 30), 0), horn, Enum.Material.SmoothPlastic)
			attach(ctx, root, "HornTip", Vector3.new(0.45, 0.45, 1.5) * k, CFrame.new(side * (2.1 + 0.3 * (k - 1)), 0.7 + 0.2 * (k - 1), -3.3 - 0.3 * (k - 1)) * CFrame.Angles(math.rad(40), math.rad(side * 15), 0), horn, Enum.Material.SmoothPlastic)
		end
		attach(ctx, root, "RamPlate", Vector3.new(2.4, 1.0, 0.35) * Vector3.new(1, k, 1), CFrame.new(0, -0.3, -2.45), DARK, Enum.Material.DiamondPlate)
	elseif weaponId == "wpn_sidesaw" then
		-- Vertical Saw: a big blade standing on the middle of the back (D71); clients keep it spinning.
		fade((motorPart(ctx, root, "SideSaw", Vector3.new(0.3, 2.3, 2.3) * k, Vector3.new(0, 0.3 + 0.3 * (k - 1), 2.3 + 0.3 * (k - 1)), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)))
		fade(attach(ctx, root, "SideSawHub", Vector3.new(0.5, 0.5, 0.5) * k, CFrame.new(0, 0.3 + 0.3 * (k - 1), 2.3 + 0.3 * (k - 1)), Color3.fromRGB(200, 60, 50), Enum.Material.Neon))
	elseif weaponId == "wpn_traps" then
		part("TrapBox", Vector3.new(1.2, 0.8, 1.2), Vector3.zero, DARK, Enum.Material.DiamondPlate)
		for i = 1, math.min(rank, 3) do
			part("TrapSpike", Vector3.new(0.25, 0.6, 0.25), Vector3.new((i - 2) * 0.35, 0.65, 0), Color3.fromRGB(200, 60, 50), Enum.Material.Metal)
		end
	elseif weaponId == "wpn_shieldgen" then
		part("ShieldGen", Vector3.new(1.0, 0.9, 1.0), Vector3.zero, DARK, Enum.Material.Metal)
		part("ShieldCore", Vector3.new(0.6, 0.6, 0.6), Vector3.new(0, 0.6, 0), Color3.fromRGB(110, 230, 160), Enum.Material.Neon, nil, Enum.PartType.Ball)
		-- The shield itself turns with the turret, so it faces where you aim. Clients
		-- hide it while it is broken (the Guard attribute).
		attach(ctx, turret, "GuardShield", Vector3.new(5.5 + 0.4 * rank, 3.2, 0.3), CFrame.new(0, 0.3, -4.2), Color3.fromRGB(110, 230, 160), Enum.Material.ForceField)
	end
end

-- Primary weapons (by robot type) ---------------------------------------------------

local function buildPrimary(ctx: Ctx, turret: BasePart, chassisId: string, build)
	local st = build.stacks
	local barrels = math.min(Config.Barrels.max, 1 + (st.stat_barrels or 0))
	local spread = (st.mod_spread or 0) > 0
	local rangeTier = tier(st.stat_range or 0, 3, 6)
	local rateTier = tier(st.stat_firerate or 0, 3, 6)
	local thick = 0.5 + 0.05 * math.min(st.stat_damage or 0, 8) -- every Damage stack thickens the gun
	local variant = Upgrades.primaryFor(st)
	local weapon = variant and variant.weapon

	-- Battle Axe (D71): a long haft from the turret centre that clients spin a full
	-- 360 per swing; the blade tip reaches exactly as far as the axe hits.
	if weapon == "axe" then
		local len = R.HitboxRadius + reachU(build, Config.Weapons.axe.reach)
		local hub = motorPart(ctx, turret, "Swing", Vector3.new(0.8, 0.8, 0.8), Vector3.new(0, 0.2, 0), DARK, Enum.Material.Metal, Enum.PartType.Ball)
		hub:SetAttribute("SwingRate", Config.Weapons.axe.fireRate)
		fade(attach(ctx, hub, "AxeHaft", Vector3.new(0.4, 0.4, len - 1.2), CFrame.new(0, 0, -(len - 1.2) / 2), Color3.fromRGB(110, 75, 45), Enum.Material.Wood))
		fade(attach(ctx, hub, "AxeBlade", Vector3.new(2.6, 0.25, 2.2), CFrame.new(1.1, 0, -(len - 1.2)), STEEL, Enum.Material.Metal))
		fade(attach(ctx, hub, "AxeEdge", Vector3.new(0.25, 0.3, 2.4), CFrame.new(2.4, 0, -(len - 1.2)), Color3.fromRGB(205, 210, 215), Enum.Material.Metal))
		return
	end
	-- Sledgehammer (D71): raised behind on the turret, it smashes 180 degrees over the
	-- top onto its smash area in front. The head is as wide as the area.
	if weapon == "hammer" then
		local def = Config.Weapons.hammer
		local impactZ = -(R.HitboxRadius + reachU(build, def.reach))
		buildSmashHammer(ctx, turret, "SmashHub", "Smashes", Vector3.new(0, 1.0, 0.6), impactZ, math.min(3.4, reachU(build, def.smashRadius) * 0.7), 1.3)
		return
	end

	if chassisId == "bomber" then
		-- Net launcher: a short, wide mortar with a rolled net on top.
		attach(ctx, turret, "NetLauncher", Vector3.new(2.0, 1.5, 1.5), CFrame.new(0, 0.2, -1.6) * CFrame.Angles(0, math.rad(90), 0), DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
		attach(ctx, turret, "NetRoll", Vector3.new(1.3, 0.5, 0.5), CFrame.new(0, 0.95, -1.4), Color3.fromRGB(150, 120, 80), Enum.Material.Fabric, Enum.PartType.Cylinder)
		attach(ctx, turret, "NetMuzzle", Vector3.new(0.3, 1.7, 1.7), CFrame.new(0, 0.2, -2.6) * CFrame.Angles(0, math.rad(90), 0), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		return
	end

	if chassisId == "brawler" then
		-- A big horizontal buzzsaw in front, sized so its edge is where it hits (D71);
		-- clients spin it while attacking.
		local r = reachU(build, Config.Weapons.buzzsaw.reach)
		local cz = -(R.HitboxRadius + r / 2)
		motorPart(ctx, turret, "Saw", Vector3.new(0.35, r + 0.6, r + 0.6), Vector3.new(0, -0.3, cz), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		local saw = ctx.folder:FindFirstChild("Saw") :: Part
		saw.CFrame = saw.CFrame * CFrame.Angles(0, 0, math.rad(90))
		local motor = saw:FindFirstChild("SawMotor") :: Motor6D
		motor.C0 = motor.C0 * CFrame.Angles(0, 0, math.rad(90))
		attach(ctx, turret, "SawHub", Vector3.new(0.9, 0.9, 0.9), CFrame.new(0, -0.1, cz), HAZARD, Enum.Material.Metal, Enum.PartType.Ball)
		attach(ctx, turret, "SawArm", Vector3.new(0.6, 0.5, -cz - 0.8), CFrame.new(0, -0.2, (cz - 0.8) / 2), DARK, Enum.Material.Metal)
		return
	end

	if chassisId == "scorcher" then
		local nozzle = attach(ctx, turret, "Nozzle", Vector3.new(thick + 0.5, thick + 0.5, 2.4), CFrame.new(0, 0, -2.3), DARK, Enum.Material.Metal)
		-- Heat-blued steel bands and a fuel line back to the tanks.
		for _, z in { -1.6, -2.6 } do
			attach(ctx, turret, "NozzleBand", Vector3.new(0.2, thick + 0.7, thick + 0.7), CFrame.new(0, 0, z) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(70, 78, 96), Enum.Material.Metal, Enum.PartType.Cylinder)
		end
		attach(ctx, turret, "FuelLine", Vector3.new(0.18, 0.18, 2.6), CFrame.new(0.55, -0.3, 0.2), RUBBER, Enum.Material.SmoothPlastic)
		attach(ctx, turret, "NozzleTip", Vector3.new(0.5, 1.1, 1.1), CFrame.new(0, 0, -3.55) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(255, 120, 30), Enum.Material.Neon, Enum.PartType.Cylinder)
		-- Flame jet: clients switch it on while the robot attacks.
		local fire = Instance.new("ParticleEmitter")
		fire.Name = "Flame"
		fire.Enabled = false
		fire.EmissionDirection = Enum.NormalId.Front
		fire.Rate = 140
		local flameLen = 1 + (st.stat_range or 0) * Config.StatPerStack.stat_range
		fire.Speed = NumberRange.new(36 * flameLen, 44 * flameLen)
		fire.Lifetime = NumberRange.new(0.3, 0.42)
		local flameSpread = 18 + (st.stat_cone or 0) * Config.StatPerStack.stat_cone / 2 -- Wider Flames (D71)
		fire.SpreadAngle = Vector2.new(flameSpread, flameSpread)
		fire.LightEmission = 1
		fire.Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 70, 20))
		fire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 3.2) })
		fire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
		fire.Parent = nozzle
		return
	end

	-- Rookie (blaster barrels) and Bombard (launch tubes): one per barrel.
	local isLauncher = chassisId == "bombard"
	local len = (if isLauncher then 2.6 else R.BarrelLength) * (if rangeTier >= 1 then 1.3 else 1)
	local width = if isLauncher then thick + 0.35 else thick
	local gap = math.max(width + 0.1, 0.5)
	for i = 1, barrels do
		local offset = i - (barrels + 1) / 2
		local yaw = if spread then -math.rad(offset * Config.Barrels.spreadDegrees) else 0
		local x = if spread then offset * 0.25 else offset * gap
		local cf = CFrame.new(x, 0, -1.2) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -len / 2)
		if isLauncher then
			attach(ctx, turret, "LaunchTube", Vector3.new(len, width, width), cf * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(86, 94, 66), Enum.Material.Metal, Enum.PartType.Cylinder)
			attach(ctx, turret, "TubeRim", Vector3.new(0.15, width + 0.12, width + 0.12), cf * CFrame.new(0, 0, -len / 2) * CFrame.Angles(0, math.rad(90), 0), DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
		else
			attach(ctx, turret, "Barrel", Vector3.new(width, width, len), cf, if weapon == "laser" then Color3.fromRGB(200, 204, 210) else DARK, Enum.Material.Metal)
			if weapon ~= "laser" then
				-- A muzzle brake at the tip, like a real gun.
				attach(ctx, turret, "Muzzle", Vector3.new(width + 0.16, width + 0.16, 0.4), cf * CFrame.new(0, 0, -len / 2 + 0.1), shade(STEEL, 0.35), Enum.Material.Metal)
			end
			if weapon == "laser" then
				attach(ctx, turret, "LaserLens", Vector3.new(width + 0.2, width + 0.2, width + 0.2), cf * CFrame.new(0, 0, -len / 2), Color3.fromRGB(255, 40, 60), Enum.Material.Neon, Enum.PartType.Ball)
			end
		end
		if rateTier >= 1 then
			attach(ctx, turret, "CoolingRing", Vector3.new(0.2, width + 0.25, width + 0.25), cf * CFrame.new(0, 0, len * 0.2) * CFrame.Angles(0, math.rad(90), 0), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		end
	end
	if rateTier >= 2 then
		for _, x in { -1.0, 1.0 } do
			attach(ctx, turret, "HeatVent", Vector3.new(0.2, 0.5, 1.2), CFrame.new(x, 0.6, 0.4), Color3.fromRGB(255, 120, 40), Enum.Material.Neon)
		end
	end
	if rangeTier >= 2 then
		attach(ctx, turret, "Scope", Vector3.new(0.35, 0.35, 1.6), CFrame.new(1.0, 0.65, -0.6), DARK, Enum.Material.Metal)
	end
end

-- Body -------------------------------------------------------------------------

local function buildBody(model: Model, root: BasePart, build, color: Color3, scale: number, chassisId: string, level: number)
	local old = model:FindFirstChild("Body")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Body"
	local ctx: Ctx = { folder = folder, s = scale, lift = (scale - 1) * R.BodyLift, root = root }
	local st = build.stacks
	-- Paint (D77): the player's colour on metal panels; trim is off-white on dark
	-- paint and near-black on light paint, like stencilled markings.
	local paint = color
	local bright = (color.R + color.G + color.B) / 3 > 0.55
	local trim = if bright then Color3.fromRGB(40, 40, 42) else Color3.fromRGB(222, 216, 200)
	local accent = color:Lerp(Color3.new(1, 1, 1), 0.08) -- the turret: the same paint, a touch sun-faded

	-- Chassis (Brawler sits lower and wider, Bombard is boxier)
	local chassisSize = ({
		brawler = Vector3.new(4.8, 1.2, 4.8),
		bombard = Vector3.new(4.6, 1.6, 4.8),
	})[chassisId] or Vector3.new(4.4, 1.4, 4.6)
	attach(ctx, root, "Chassis", chassisSize, CFrame.new(0, -0.4, 0), paint, Enum.Material.Metal)
	local top = -0.4 + chassisSize.Y / 2
	local front, back = -chassisSize.Z / 2, chassisSize.Z / 2
	-- Gunmetal frame underneath, a steel bumper, seams and bolts on the deck.
	attach(ctx, root, "Skirt", Vector3.new(chassisSize.X - 0.4, 0.45, chassisSize.Z + 0.2), CFrame.new(0, -1.25, 0), DARK, Enum.Material.DiamondPlate)
	attach(ctx, root, "Bumper", Vector3.new(chassisSize.X * 0.85, 0.35, 0.3), CFrame.new(0, -0.95, front - 0.12), shade(STEEL, 0.2), Enum.Material.Metal)
	for _, z in { -0.9, 0.9 } do
		attach(ctx, root, "Seam", Vector3.new(chassisSize.X + 0.02, 0.05, 0.07), CFrame.new(0, top, z), shade(paint, 0.5), Enum.Material.Metal)
	end
	for _, bx in { -1, 1 } do
		for _, bz in { -1, 1 } do
			attach(ctx, root, "Bolt", Vector3.new(0.2, 0.2, 0.2), CFrame.new(bx * (chassisSize.X / 2 - 0.3), top, bz * (chassisSize.Z / 2 - 0.3)), STEEL, Enum.Material.Metal, Enum.PartType.Ball)
		end
	end
	-- Head and tail lights, an engine grille and an exhaust pipe.
	for _, x in { -1.4, 1.4 } do
		attach(ctx, root, "Headlight", Vector3.new(0.5, 0.3, 0.1), CFrame.new(x, -0.3, front - 0.04), Color3.fromRGB(255, 238, 200), Enum.Material.Neon)
		attach(ctx, root, "TailLight", Vector3.new(0.4, 0.2, 0.1), CFrame.new(x, -0.3, back + 0.04), Color3.fromRGB(190, 28, 24), Enum.Material.Neon)
	end
	for i = 0, 2 do
		attach(ctx, root, "Grille", Vector3.new(1.3, 0.05, 0.1), CFrame.new(-0.9, top + 0.02, 1.25 + i * 0.25), DARK, Enum.Material.Metal)
	end
	attach(ctx, root, "Exhaust", Vector3.new(0.9, 0.32, 0.32), CFrame.new(1.4, 0.15, back + 0.1) * CFrame.Angles(0, math.rad(90), math.rad(-20)), shade(STEEL, 0.45), Enum.Material.Metal, Enum.PartType.Cylinder)

	-- Wheels below Lv 40, tracks from Lv 40 (speed upgrades make them bigger)
	local speedTier = tier(st.stat_speed or 0, 3, 6)
	if level >= 40 then
		local w = if speedTier >= 1 then 1.2 else 0.9
		for _, x in { -2.55, 2.55 } do
			attach(ctx, root, "Track", Vector3.new(w, 1.4, 5.2), CFrame.new(x, -1.3, 0), RUBBER, Enum.Material.Slate)
			-- Steel road wheels showing through the tread.
			for _, z in { -1.7, 0, 1.7 } do
				attach(ctx, root, "RoadWheel", Vector3.new(w + 0.06, 0.95, 0.95), CFrame.new(x, -1.3, z), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
			end
		end
	else
		local d = if speedTier >= 1 then 2.2 else 1.6
		for _, x in { -2.5, 2.5 } do
			for _, z in { -1.5, 1.5 } do
				-- Rubber tyre, steel rim, gunmetal hub.
				local cf = CFrame.new(x, -2.0 + d / 2, z)
				attach(ctx, root, "Wheel", Vector3.new(0.8, d, d), cf, RUBBER, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
				attach(ctx, root, "Rim", Vector3.new(0.86, d * 0.56, d * 0.56), cf, STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
				attach(ctx, root, "Hub", Vector3.new(0.92, d * 0.22, d * 0.22), cf, DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
			end
		end
	end
	if speedTier >= 2 then
		for _, x in { -1.2, 1.2 } do
			attach(ctx, root, "ExhaustFin", Vector3.new(0.3, 1.0, 1.2), CFrame.new(x, 0.3, 2.6), STEEL, Enum.Material.Metal)
		end
	end

	-- Level bands: a glance tells you how far along a robot is.
	if level >= 20 then
		for _, x in { -2.24, 2.24 } do
			attach(ctx, root, "Stripe", Vector3.new(0.08, 0.3, 4.0), CFrame.new(x, -0.2, 0), trim, Enum.Material.Metal)
		end
	end
	if level >= 60 then
		attach(ctx, root, "Hull", Vector3.new(4.0, 0.5, 3.6), CFrame.new(0, 0.42, 0.3), paint:Lerp(DARK, 0.4), Enum.Material.DiamondPlate)
	end
	if level >= 80 then
		attach(ctx, root, "Crest", Vector3.new(0.3, 1.6, 1.8), CFrame.new(0, 1.4, 1.6), trim, Enum.Material.Metal)
	end
	if level >= 100 then
		for _, z in { -2.3, 2.3 } do
			attach(ctx, root, "GoldTrim", Vector3.new(4.5, 0.2, 0.2), CFrame.new(0, 0.32, z), BRASS, Enum.Material.Metal)
		end
		for _, x in { -2.25, 2.25 } do
			attach(ctx, root, "GoldTrim", Vector3.new(0.2, 0.2, 4.6), CFrame.new(x, 0.32, 0), BRASS, Enum.Material.Metal)
		end
	end

	-- Robot-type extras on the chassis
	if chassisId == "brawler" then
		attach(ctx, root, "Wedge", Vector3.new(4.6, 0.5, 1.2), CFrame.new(0, -0.95, -2.7), shade(STEEL, 0.15), Enum.Material.DiamondPlate)
		-- Yellow-and-black warning stripes on the wedge.
		for i = -2, 2 do
			attach(ctx, root, "WarningStripe", Vector3.new(0.35, 0.06, 1.0), CFrame.new(i * 0.85, -0.68, -2.7) * CFrame.Angles(0, math.rad(35), 0), if i % 2 == 0 then HAZARD else RUBBER, Enum.Material.Metal)
		end
	elseif chassisId == "scorcher" then
		for _, x in { -0.9, 0.9 } do
			-- Red pressure tanks with steel straps and a valve on top.
			attach(ctx, root, "FuelTank", Vector3.new(1.6, 0.9, 0.9), CFrame.new(x, 0.6, 1.9) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(150, 40, 32), Enum.Material.Metal, Enum.PartType.Cylinder)
			attach(ctx, root, "TankStrap", Vector3.new(0.12, 0.96, 0.96), CFrame.new(x, 0.6, 1.9) * CFrame.Angles(0, math.rad(90), 0), DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
			attach(ctx, root, "TankValve", Vector3.new(0.25, 0.3, 0.25), CFrame.new(x, 1.5, 1.9), BRASS, Enum.Material.Metal)
		end
	elseif chassisId == "bomber" and not build.small then
		-- Big form: bombs strapped all round the hull, with a lit fuse on top (D70).
		local bomb = Color3.fromRGB(44, 46, 42)
		for _, p in { { -2.5, 1.2 }, { 2.5, 1.2 }, { -2.5, -1.2 }, { 2.5, -1.2 }, { 0, 2.6 } } do
			attach(ctx, root, "Bomb", Vector3.new(1.3, 1.3, 1.3), CFrame.new(p[1], 0.3, p[2]), bomb, Enum.Material.Metal, Enum.PartType.Ball)
			-- A yellow warning band round each bomb.
			attach(ctx, root, "BombBand", Vector3.new(0.18, 1.34, 1.34), CFrame.new(p[1], 0.3, p[2]) * CFrame.Angles(0, 0, math.rad(90)), HAZARD, Enum.Material.Metal, Enum.PartType.Cylinder)
		end
		attach(ctx, root, "BombStrap", Vector3.new(5.6, 0.25, 0.3), CFrame.new(0, 0.3, 1.2), Color3.fromRGB(70, 62, 48), Enum.Material.Fabric)
		attach(ctx, root, "Fuse", Vector3.new(0.35, 0.35, 0.35), CFrame.new(0, 0.95, 2.6), Color3.fromRGB(255, 170, 40), Enum.Material.Neon, Enum.PartType.Ball)
	elseif chassisId == "bombard" then
		for _, x in { -0.8, 0, 0.8 } do
			attach(ctx, root, "Missile", Vector3.new(1.4, 0.45, 0.45), CFrame.new(x, 0.6, 2.0) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(205, 205, 196), Enum.Material.Metal, Enum.PartType.Cylinder)
			attach(ctx, root, "MissileTip", Vector3.new(0.3, 0.47, 0.47), CFrame.new(x, 0.6, 1.25) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(160, 40, 32), Enum.Material.Metal, Enum.PartType.Cylinder)
		end
	end

	-- Armor Plating shows as plates (D33); Max HP as batteries and a frame.
	local armorStacks = st.stat_armor or 0
	if armorStacks >= 1 then
		for _, x in { -3.05, 3.05 } do
			attach(ctx, root, "SideArmor", Vector3.new(0.3, 1.4, 3.8), CFrame.new(x, -0.6, 0), shade(STEEL, 0.25), Enum.Material.DiamondPlate)
		end
	end
	if armorStacks >= 3 then
		attach(ctx, root, "FrontArmor", Vector3.new(4.2, 1.2, 0.4), CFrame.new(0, -0.4, -2.55), shade(STEEL, 0.25), Enum.Material.DiamondPlate)
	end
	if armorStacks >= 5 then
		attach(ctx, root, "RoofArmor", Vector3.new(3.6, 0.3, 1.2), CFrame.new(0, 0.45, 1.6), shade(STEEL, 0.25), Enum.Material.DiamondPlate)
	end
	local hpTier = tier(st.stat_hp or 0, 3, 6)
	if hpTier >= 1 then
		attach(ctx, root, "Battery", Vector3.new(2.6, 0.9, 0.9), CFrame.new(0, -0.1, 2.6), Color3.fromRGB(58, 66, 60), Enum.Material.Metal)
		attach(ctx, root, "Terminal", Vector3.new(0.25, 0.25, 0.25), CFrame.new(-0.9, 0.45, 2.6), Color3.fromRGB(170, 40, 30), Enum.Material.Metal)
		attach(ctx, root, "Terminal", Vector3.new(0.25, 0.25, 0.25), CFrame.new(0.9, 0.45, 2.6), DARK, Enum.Material.Metal)
	end
	if hpTier >= 2 then
		attach(ctx, root, "Frame", Vector3.new(4.8, 0.4, 5.0), CFrame.new(0, -1.15, 0), DARK, Enum.Material.Metal)
	end
	local pickup = st.stat_pickup or 0
	if pickup >= 2 then
		attach(ctx, root, "Antenna", Vector3.new(0.15, 2.5, 0.15), CFrame.new(1.6, 1.4, 1.7), STEEL, Enum.Material.Metal)
	end
	if pickup >= 4 then
		attach(ctx, root, "MagnetDish", Vector3.new(0.3, 1.6, 1.6), CFrame.new(-1.5, 0.6, 1.6) * CFrame.Angles(0, 0, math.rad(90)), shade(STEEL, 0.1), Enum.Material.Metal, Enum.PartType.Cylinder)
	end

	-- Turret on a Motor6D: every client rotates it locally toward the aim.
	local turretSize = if chassisId == "bombard" then Vector3.new(2.7, 1.3, 2.7) elseif chassisId == "brawler" then Vector3.new(2.0, 0.8, 2.0) else Vector3.new(2.4, 1.0, 2.4)
	local turret, motor = motorPart(ctx, root, "Turret", turretSize, Vector3.new(0, R.TurretHeight, 0), accent, Enum.Material.Metal)
	motor.Name = "TurretMotor"
	-- A hatch on top and a gunmetal mantlet where the weapon leaves the turret.
	attach(ctx, turret, "Hatch", Vector3.new(0.12, 0.9, 0.9), CFrame.new(0.45, turretSize.Y / 2 + 0.03, 0.4) * CFrame.Angles(0, 0, math.rad(90)), shade(paint, 0.3), Enum.Material.Metal, Enum.PartType.Cylinder)
	attach(ctx, turret, "Mantlet", Vector3.new(turretSize.X * 0.55, turretSize.Y * 0.7, 0.3), CFrame.new(0, 0, -turretSize.Z / 2 - 0.1), DARK, Enum.Material.Metal)
	buildPrimary(ctx, turret, chassisId, build)
	if build.skill then
		local coreColor = ({
			skl_dash = Color3.fromRGB(80, 230, 255),
			skl_shield = Color3.fromRGB(240, 240, 255),
			skl_nullfield = Color3.fromRGB(170, 110, 255),
			skl_flipper = Color3.fromRGB(255, 200, 60),
			skl_earthwall = Color3.fromRGB(170, 120, 70),
		})[build.skill] or Color3.new(1, 1, 1)
		attach(ctx, turret, "SkillCore", Vector3.new(0.8, 0.8, 0.8), CFrame.new(0, turretSize.Y / 2 + 0.2, 0.5), coreColor, Enum.Material.Neon, Enum.PartType.Ball)
	end
	if build.skill == "skl_flipper" then
		-- Flipper plate on the front bumper, hinged at its back edge; clients kick it up on each flip (Flips).
		local hinge = motorPart(ctx, root, "FlipperHub", Vector3.new(4.2, 0.3, 0.3), Vector3.new(0, -1.0, -2.4), DARK, Enum.Material.Metal)
		attach(ctx, hinge, "FlipperPlate", Vector3.new(4.2, 0.25, 1.6), CFrame.new(0, 0, -0.8), HAZARD, Enum.Material.DiamondPlate)
	end

	-- Mounts; the highest rank is the signature weapon (first one wins a tie).
	local signatureIndex, best = 0, 0
	for i, weaponId in build.mounts do
		if (st[weaponId] or 1) > best then
			signatureIndex, best = i, st[weaponId] or 1
		end
	end
	for i, weaponId in build.mounts do
		buildMount(ctx, turret, Config.MountSockets[i], weaponId, st[weaponId] or 1, i == signatureIndex and #build.mounts > 1)
	end

	folder.Parent = model
	model:SetAttribute("DressedLevel", level)
end

-- (Re)builds every visible part for the robot's build, size, type and level.
function RobotBuilder.dress(model: Model, build, color: Color3, scale: number, chassisId: string, level: number)
	buildBody(model, model.PrimaryPart :: BasePart, build, color, scale, chassisId, level)
end

-- A stationary target robot for /dummy and /showcase.
function RobotBuilder.buildDummy(x: number, z: number, build, scale: number, chassisId: string, level: number): Model
	local model = Instance.new("Model")
	model.Name = "Dummy"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(R.RootSize[1], R.RootSize[2], R.RootSize[3])
	root.Transparency = 1
	root.Anchored = true
	root.CFrame = CFrame.new(x, R.HipHeight + R.RootSize[2] / 2, z)
	root.Parent = model
	model.PrimaryPart = root
	model:SetAttribute("VisualScale", scale)
	buildBody(model, root, build, Color3.fromRGB(118, 122, 116), scale, chassisId, level)
	model.Parent = Workspace
	return model
end

return RobotBuilder
