-- Builds the robot from primitives. The character template holds only
-- HumanoidRootPart, Head and Humanoid; everything you see lives in a cosmetic
-- "Body" folder rebuilt when the build, level band or visual size changes.
-- The physical root never resizes (resizing it caused the level-up glitch).
--
-- Art direction (D78, vault 07-robot-art-bible.md): every robot has its own body,
-- locomotion and silhouette, so five black silhouettes still read at a glance.
--   Rookie   compact scout buggy on 4 wheels, a round sensor dome, one long blaster, a whip antenna
--   Bombard  long low crawler on tracks, a tall box launcher tilted up, rear outrigger legs
--   Scorcher hot-rod wedge rising to the back, big rear wheels, twin exhaust stacks, a long nozzle
--   Bomber   a round naval-mine body with detonator horns between two giant wheels; after it
--            blows, a small smooth ball with a burning fuse and a whip aerial
--   Brawler  wide flat slab on armoured skirts, a front plow and a toothed saw disc
-- Shared language: a cyan sensor visor on every robot, gunmetal frames, brushed steel
-- moving parts, hazard yellow on dangerous edges, Neon only for lights, sensors and heat.
--
-- What else the body shows:
--   level band   Lv 20 side stripes, 40 light bar, 60 armoured deck, 80 crest, 100 gold trim
--   upgrades     barrels per Extra Barrel, barrel thickness per Damage stack, plates for armor,
--                a battery for HP, bigger wheels and fins for speed, an antenna and dish for pickup
--   mounts       on swivels that turn with the aim; each grows 15% per rank, the signature one +25%
--
-- Parts clients animate (Robots.luau): Turret (yaw), Gun (recoil; attributes Slide, Climb,
-- Settle), Swivel (mount yaw), Saw, Swing, SideSaw, SmashHub, FlipperHub, GuardShield,
-- Nozzle (Flame and PilotLight emitters), and any part with a Blink (Hz) or HeatGlow attribute.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Stats = require(Shared.Stats)
local Upgrades = require(Shared.Upgrades)

local RobotBuilder = {}

local R = Config.Robot
local P = Config.Presentation
local M = Enum.Material
local SHAPE = Enum.PartType

-- Materials (D77): painted metal panels, gunmetal frames, brushed steel, rubber, brass.
local DARK = Color3.fromRGB(52, 54, 58) -- gunmetal
local STEEL = Color3.fromRGB(128, 131, 136) -- brushed steel
local RUBBER = Color3.fromRGB(30, 30, 32)
local BRASS = Color3.fromRGB(176, 140, 64)
local HAZARD = Color3.fromRGB(206, 162, 42) -- warning-stripe yellow
local SENSOR = Color3.fromRGB(63, 212, 255) -- every robot's eyes (D78)
local LAMP = Color3.fromRGB(255, 238, 200)
local TAIL = Color3.fromRGB(190, 28, 24)
local AMBER = Color3.fromRGB(255, 170, 40)
local GROUND = -2.0 -- wheels touch here, below the root centre (unscaled)

-- Cylinders run along X; these turn the axis forward (Z) or up (Y).
local AXIS_Z = CFrame.Angles(0, math.rad(90), 0)
local AXIS_Y = CFrame.Angles(0, 0, math.rad(90))

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
	p.Material = material or M.SmoothPlastic
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

-- A part on a Motor6D, so clients can move it locally (turret, gun, swivels, saw).
-- `rotation` tilts its resting pose (the Bombard's launcher points up).
local function motorPart(ctx: Ctx, anchor: BasePart, name: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?, rotation: CFrame?): (Part, Motor6D)
	local s = ctx.s
	local lift = if anchor == ctx.root then ctx.lift else 0
	local c0 = CFrame.new(offset * s + Vector3.new(0, lift, 0)) * (rotation or CFrame.identity)
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

-- An invisible frame other parts hang off (turret yaw, gun recoil, mount swivel).
local function frame(ctx: Ctx, anchor: BasePart, name: string, offset: Vector3, rotation: CFrame?): Part
	local p = motorPart(ctx, anchor, name, Vector3.new(0.3, 0.3, 0.3), offset, DARK, M.SmoothPlastic, nil, rotation)
	p.Transparency = 1
	return p
end

-- A tyre on a steel rim, standing on the ground.
local function wheel(ctx: Ctx, x: number, z: number, d: number, width: number)
	local cf = CFrame.new(x, GROUND + d / 2, z)
	attach(ctx, ctx.root, "Wheel", Vector3.new(width, d, d), cf, RUBBER, M.SmoothPlastic, SHAPE.Cylinder)
	attach(ctx, ctx.root, "Rim", Vector3.new(width + 0.06, d * 0.55, d * 0.55), cf, STEEL, M.Metal, SHAPE.Cylinder)
end

local function lights(ctx: Ctx, xs: { number }, y: number, front: number, back: number)
	for _, x in xs do
		attach(ctx, ctx.root, "Headlight", Vector3.new(0.45, 0.26, 0.1), CFrame.new(x, y, front - 0.05), LAMP, M.Neon)
		attach(ctx, ctx.root, "TailLight", Vector3.new(0.38, 0.2, 0.1), CFrame.new(x, y, back + 0.05), TAIL, M.Neon)
	end
end

-- Melee visuals match the real hit area (D71) --------------------------------------

-- Studs of weapon reach (beyond the hitbox) in unscaled body units: the body is
-- drawn at visualScale x bodySize, the hitbox is HitboxRadius x the same.
local function reachU(build, studs: number): number
	local rangeMult = 1 + (build.stacks.stat_range or 0) * Config.StatPerStack.stat_range
	return studs * rangeMult / Stats.bodySize(build)
end

-- An overhead hammer on a hub on the turret, built in its impact pose: the head on
-- the ground `impactZ` in front. Clients hold it upright in front at rest, lift it
-- and slam it to 0 on every smash, counted by the model attribute `counter` (D80).
local function buildSmashHammer(ctx: Ctx, turret: BasePart, turretY: number, hubName: string, counter: string, pivot: Vector3, impactZ: number, headWidth: number, thick: number)
	local hub = motorPart(ctx, turret, hubName, Vector3.new(0.6, 0.6, 0.6), pivot, DARK, M.Metal, SHAPE.Ball)
	hub:SetAttribute("SmashCounter", counter)
	fade(hub)
	local head = Vector3.new(0, GROUND - turretY + thick / 2, impactZ) - pivot
	fade(attach(ctx, hub, hubName .. "Haft", Vector3.new(0.35, 0.35, head.Magnitude), CFrame.lookAt(head / 2, head), Color3.fromRGB(110, 75, 45), M.Wood))
	fade(attach(ctx, hub, hubName .. "Head", Vector3.new(headWidth, thick, thick), CFrame.lookAt(head, head * 2), DARK, M.Metal))
	for _, x in { -1, 1 } do
		fade(attach(ctx, hub, hubName .. "Face", Vector3.new(0.2, thick * 0.8, thick * 0.8), CFrame.lookAt(head, head * 2) * CFrame.new(x * headWidth / 2, 0, 0), STEEL, M.DiamondPlate))
	end
end

-- Bodies (D78) ----------------------------------------------------------------------
-- Each returns where the rest of the robot attaches: the turret height, the flat
-- "deck" that level bands and upgrade parts sit on, the front and back edges, the
-- mount sockets, and where the skill core sits on the turret.

type Body = {
	turretY: number,
	deck: { w: number, l: number, y: number, z: number },
	front: number,
	back: number,
	sockets: { [string]: Vector3 },
	core: Vector3,
}

-- Rookie: the baseline. A compact buggy with a sloped nose, exposed wheels under
-- fenders, a raised engine deck and one thin whip antenna with a blinking tip.
local function rookieBody(ctx: Ctx, paint: Color3, speedTier: number): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(3.6, 1.1, 3.4), CFrame.new(0, -0.55, 0.4), paint, M.Metal)
	attach(ctx, root, "Glacis", Vector3.new(3.6, 1.1, 1.3), CFrame.new(0, -0.55, -1.95), paint, M.Metal, SHAPE.Wedge)
	attach(ctx, root, "Skirt", Vector3.new(3.2, 0.4, 4.6), CFrame.new(0, -1.3, 0), DARK, M.DiamondPlate)
	attach(ctx, root, "Bumper", Vector3.new(3.0, 0.35, 0.3), CFrame.new(0, -1.0, -2.65), shade(STEEL, 0.2), M.Metal)
	attach(ctx, root, "EngineDeck", Vector3.new(3.0, 0.4, 0.85), CFrame.new(0, 0.2, 1.68), shade(paint, 0.25), M.Metal)
	for i = 0, 2 do
		attach(ctx, root, "Grille", Vector3.new(2.4, 0.06, 0.12), CFrame.new(0, 0.42, 1.43 + i * 0.25), DARK, M.Metal)
	end
	local d = if speedTier >= 1 then 2.0 else 1.6
	for _, x in { -2.15, 2.15 } do
		for _, z in { -1.5, 1.5 } do
			wheel(ctx, x, z, d, 0.75)
			attach(ctx, root, "Fender", Vector3.new(0.85, 0.12, d + 0.3), CFrame.new(x, GROUND + d + 0.1, z), shade(paint, 0.15), M.Metal)
		end
	end
	lights(ctx, { -1.1, 1.1 }, -1.0, -2.8, 2.1)
	attach(ctx, root, "Exhaust", Vector3.new(0.8, 0.28, 0.28), CFrame.new(1.2, -0.6, 2.25) * AXIS_Z, shade(STEEL, 0.45), M.Metal, SHAPE.Cylinder)
	attach(ctx, root, "Antenna", Vector3.new(0.1, 3.2, 0.1), CFrame.new(-1.25, 1.6, 1.7), STEEL, M.Metal)
	attach(ctx, root, "AntennaTip", Vector3.new(0.3, 0.3, 0.3), CFrame.new(-1.25, 3.25, 1.7), TAIL, M.Neon, SHAPE.Ball):SetAttribute("Blink", 1.2)
	return {
		turretY = 0.3,
		deck = { w = 3.6, l = 3.4, y = 0.0, z = 0.4 },
		front = -2.8,
		back = 2.1,
		sockets = { MountLeft = Vector3.new(-1.95, 0.5, 0.6), MountRight = Vector3.new(1.95, 0.5, 0.6), MountBack = Vector3.new(0, 0.9, 1.75) },
		core = Vector3.new(0, 1.0, 0.7),
	}
end

-- Bombard: a long, low tracked crawler. Tracks the whole length, armoured side skirts,
-- spare rockets racked on the rear deck and two hydraulic outrigger legs at the back.
local function bombardBody(ctx: Ctx, paint: Color3): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(3.6, 1.0, 4.8), CFrame.new(0, -0.6, 0), paint, M.Metal)
	attach(ctx, root, "Glacis", Vector3.new(3.6, 1.0, 0.9), CFrame.new(0, -0.6, -2.85), paint, M.Metal, SHAPE.Wedge)
	attach(ctx, root, "Skirt", Vector3.new(3.4, 0.4, 5.0), CFrame.new(0, -1.3, 0), DARK, M.DiamondPlate)
	for _, x in { -2.2, 2.2 } do
		attach(ctx, root, "Track", Vector3.new(0.85, 1.25, 5.6), CFrame.new(x, GROUND + 0.62, 0), RUBBER, M.Slate)
		for _, z in { -1.8, -0.6, 0.6, 1.8 } do
			attach(ctx, root, "RoadWheel", Vector3.new(0.9, 0.8, 0.8), CFrame.new(x, GROUND + 0.45, z), STEEL, M.Metal, SHAPE.Cylinder)
		end
		attach(ctx, root, "Sprocket", Vector3.new(0.92, 1.0, 1.0), CFrame.new(x, GROUND + 0.75, -2.55), DARK, M.Metal, SHAPE.Cylinder)
		attach(ctx, root, "TrackGuard", Vector3.new(1.0, 0.15, 5.8), CFrame.new(x, GROUND + 1.32, 0), shade(paint, 0.3), M.Metal)
	end
	lights(ctx, { -1.2, 1.2 }, -0.75, -2.9, 2.4)
	-- Spare rockets on a rack behind the launcher.
	attach(ctx, root, "Rack", Vector3.new(2.6, 0.2, 1.1), CFrame.new(0, 0.0, 2.1), DARK, M.Metal)
	for _, x in { -0.8, 0, 0.8 } do
		attach(ctx, root, "Missile", Vector3.new(1.4, 0.42, 0.42), CFrame.new(x, 0.32, 2.1) * AXIS_Z, Color3.fromRGB(205, 205, 196), M.Metal, SHAPE.Cylinder)
		attach(ctx, root, "MissileTip", Vector3.new(0.3, 0.44, 0.44), CFrame.new(x, 0.32, 1.35) * AXIS_Z, Color3.fromRGB(160, 40, 32), M.Metal, SHAPE.Cylinder)
	end
	-- Outrigger legs: a strut angled down and out from each rear corner to a pad.
	for _, x in { -1, 1 } do
		attach(ctx, root, "Outrigger", Vector3.new(0.3, 0.3, 2.0), CFrame.lookAt(Vector3.new(x * 2.0, -0.3, 2.3), Vector3.new(x * 2.9, GROUND + 0.2, 3.6)) * CFrame.new(0, 0, -1.0), STEEL, M.Metal)
		attach(ctx, root, "OutriggerPad", Vector3.new(0.8, 0.15, 0.8), CFrame.new(x * 2.95, GROUND + 0.1, 3.4), HAZARD, M.DiamondPlate)
	end
	return {
		turretY = 0.1,
		deck = { w = 3.6, l = 4.8, y = -0.1, z = 0 },
		front = -3.3,
		back = 2.4,
		sockets = { MountLeft = Vector3.new(-1.75, 0.15, -1.55), MountRight = Vector3.new(1.75, 0.15, -1.55), MountBack = Vector3.new(0, 0.95, 2.1) },
		core = Vector3.new(0, 0.45, 1.25),
	}
end

-- Scorcher: a hot-rod wedge, low at the nose and high at the back, on small front
-- wheels and big rear ones. Twin exhaust stacks with glowing tips, fuel tanks along
-- the flanks and a comb of heat-sink fins on the engine.
local function scorcherBody(ctx: Ctx, paint: Color3, speedTier: number): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(3.2, 1.6, 4.4), CFrame.new(0, -0.45, 0.1), paint, M.Metal, SHAPE.Wedge)
	attach(ctx, root, "Skirt", Vector3.new(2.8, 0.35, 4.8), CFrame.new(0, -1.35, 0), DARK, M.DiamondPlate)
	attach(ctx, root, "Engine", Vector3.new(2.4, 0.9, 1.3), CFrame.new(0, 0.5, 1.65), DARK, M.Metal)
	for i = 0, 3 do
		attach(ctx, root, "EngineFin", Vector3.new(2.2, 0.25, 0.08), CFrame.new(0, 1.05, 1.15 + i * 0.32), STEEL, M.Metal)
	end
	for _, x in { -0.85, 0.85 } do
		attach(ctx, root, "Stack", Vector3.new(2.3, 0.38, 0.38), CFrame.new(x, 1.75, 2.05) * AXIS_Y, shade(STEEL, 0.45), M.Metal, SHAPE.Cylinder)
		local tip = attach(ctx, root, "StackTip", Vector3.new(0.18, 0.46, 0.46), CFrame.new(x, 2.95, 2.05) * AXIS_Y, Color3.fromRGB(90, 40, 30), M.Neon, SHAPE.Cylinder)
		tip:SetAttribute("HeatGlow", true)
	end
	local rear = if speedTier >= 1 then 2.7 else 2.4
	for _, x in { -1.95, 1.95 } do
		wheel(ctx, x, 1.5, rear, 0.9)
		attach(ctx, root, "Fender", Vector3.new(1.0, 0.14, rear + 0.2), CFrame.new(x, GROUND + rear + 0.1, 1.5), shade(paint, 0.2), M.Metal)
		wheel(ctx, x * 0.85, -1.9, 1.2, 0.6)
		-- Fuel tank along the flank, strapped, with a brass valve.
		attach(ctx, root, "FuelTank", Vector3.new(0.75, 0.75, 1.8), CFrame.new(x * 0.82, -0.35, -0.6), Color3.fromRGB(150, 40, 32), M.Metal)
		attach(ctx, root, "TankStrap", Vector3.new(0.8, 0.8, 0.12), CFrame.new(x * 0.82, -0.35, -0.6), DARK, M.Metal)
		attach(ctx, root, "TankValve", Vector3.new(0.22, 0.3, 0.22), CFrame.new(x * 0.82, 0.12, -1.2), BRASS, M.Metal)
	end
	lights(ctx, { -0.9, 0.9 }, -1.35, -2.4, 2.4)
	return {
		turretY = 0.15,
		deck = { w = 3.2, l = 4.4, y = -0.2, z = 0.1 },
		front = -2.2,
		back = 2.4,
		sockets = { MountLeft = Vector3.new(-1.75, 0.35, -0.6), MountRight = Vector3.new(1.75, 0.35, -0.6), MountBack = Vector3.new(0, 1.35, 0.85) },
		core = Vector3.new(0, 0.5, 0.6),
	}
end

-- Brawler: wide and flat. A low slab on armoured skirts that hide the wheels, a
-- hazard-striped plow, corner spikes and riveted plates. Nothing on it stands tall.
local function brawlerBody(ctx: Ctx, paint: Color3): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(4.6, 0.8, 4.0), CFrame.new(0, -0.9, 0.3), paint, M.Metal)
	attach(ctx, root, "Plow", Vector3.new(5.2, 0.8, 1.4), CFrame.new(0, -1.2, -2.4), HAZARD, M.DiamondPlate, SHAPE.Wedge)
	-- Black chevrons laid on the plow's slope.
	local slope = math.atan(0.8 / 1.4)
	for _, x in { -1.8, 0, 1.8 } do
		attach(ctx, root, "WarningStripe", Vector3.new(0.45, 0.04, 1.5), CFrame.new(x, -1.2, -2.4) * CFrame.Angles(-slope, 0, 0) * CFrame.new(0, 0.03, 0) * CFrame.Angles(0, math.rad(30), 0), RUBBER, M.Metal)
	end
	for _, x in { -2.45, 2.45 } do
		attach(ctx, root, "SideSkirt", Vector3.new(0.35, 1.45, 4.4), CFrame.new(x, -1.25, 0.3), shade(paint, 0.35), M.DiamondPlate)
		for _, z in { -0.8, 1.4 } do
			attach(ctx, root, "Spike", Vector3.new(0.35, 0.35, 0.9), CFrame.new(x * 1.14, -0.95, z) * CFrame.Angles(0, math.rad(90), math.rad(45)), STEEL, M.Metal)
		end
	end
	for _, x in { -1, 1 } do
		attach(ctx, root, "Shoulder", Vector3.new(0.8, 0.7, 0.8), CFrame.new(x * 2.1, -0.65, -1.45) * CFrame.Angles(0, math.rad(45), 0), shade(STEEL, 0.2), M.Metal)
	end
	for _, bx in { -1.7, 0, 1.7 } do
		for _, bz in { -1.2, 1.8 } do
			attach(ctx, root, "Bolt", Vector3.new(0.22, 0.22, 0.22), CFrame.new(bx, -0.5, bz), STEEL, M.Metal, SHAPE.Ball)
		end
	end
	for _, x in { -0.9, 0.9 } do
		attach(ctx, root, "Exhaust", Vector3.new(0.7, 0.3, 0.3), CFrame.new(x, -0.75, 2.55) * AXIS_Z, shade(STEEL, 0.45), M.Metal, SHAPE.Cylinder)
	end
	lights(ctx, { -1.6, 1.6 }, -0.75, -1.75, 2.3)
	return {
		turretY = -0.2,
		deck = { w = 5.2, l = 4.0, y = -0.5, z = 0.3 }, -- as wide as the skirts
		front = -3.1,
		back = 2.3,
		sockets = { MountLeft = Vector3.new(-1.9, -0.35, 0.9), MountRight = Vector3.new(1.9, -0.35, 0.9), MountBack = Vector3.new(0, -0.3, 1.9) },
		core = Vector3.new(0, 0.35, 0.6),
	}
end

-- Bomber, big form: a round mine body between two giant wheels on an axle yoke,
-- with an armour belt and four detonator horns. The fuse on top fizzes.
local function bomberBody(ctx: Ctx, paint: Color3): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(4.0, 4.0, 4.0), CFrame.new(0, 0, 0), paint, M.Metal, SHAPE.Ball)
	attach(ctx, root, "ArmorBelt", Vector3.new(0.6, 4.25, 4.25), CFrame.new(0, 0, 0) * AXIS_Y, shade(paint, 0.45), M.DiamondPlate, SHAPE.Cylinder)
	attach(ctx, root, "Yoke", Vector3.new(5.0, 0.45, 0.7), CFrame.new(0, -0.25, 0), DARK, M.Metal)
	for _, x in { -2.45, 2.45 } do
		wheel(ctx, x, 0, 3.6, 0.75)
		attach(ctx, root, "Hub", Vector3.new(0.86, 0.7, 0.7), CFrame.new(x, GROUND + 1.8, 0), HAZARD, M.Metal, SHAPE.Cylinder)
		attach(ctx, root, "Fender", Vector3.new(0.95, 0.15, 2.6), CFrame.new(x, 1.85, 0), shade(paint, 0.3), M.Metal)
	end
	-- Detonator horns on the upper diagonals: the strapped explosive (D70).
	for i = 0, 3 do
		local az = math.rad(45 + i * 90)
		local dir = Vector3.new(math.cos(az) * math.cos(math.rad(30)), math.sin(math.rad(30)), math.sin(az) * math.cos(math.rad(30)))
		attach(ctx, root, "Horn", Vector3.new(0.34, 0.34, 1.0), CFrame.lookAt(dir * 2.15, dir * 3), DARK, M.Metal)
		attach(ctx, root, "HornTip", Vector3.new(0.42, 0.42, 0.42), CFrame.new(dir * 2.65), BRASS, M.Metal, SHAPE.Ball)
	end
	attach(ctx, root, "Visor", Vector3.new(1.2, 0.3, 0.12), CFrame.new(0, 0.7, -1.88) * CFrame.Angles(math.rad(20), 0, 0), SENSOR, M.Neon)
	attach(ctx, root, "Fuse", Vector3.new(0.6, 0.28, 0.28), CFrame.new(0, 1.95, 1.0) * AXIS_Y, RUBBER, M.Fabric, SHAPE.Cylinder)
	local spark = attach(ctx, root, "FuseSpark", Vector3.new(0.35, 0.35, 0.35), CFrame.new(0, 2.3, 1.0), AMBER, M.Neon, SHAPE.Ball)
	spark:SetAttribute("Blink", 6)
	for _, x in { -0.8, 0.8 } do
		attach(ctx, root, "TailLight", Vector3.new(0.35, 0.2, 0.1), CFrame.new(x, 0.3, 1.97), TAIL, M.Neon)
	end
	return {
		turretY = 1.85,
		deck = { w = 3.9, l = 3.9, y = 0.3, z = 0 },
		front = -2.1,
		back = 2.0,
		sockets = { MountLeft = Vector3.new(-1.55, 1.35, -0.4), MountRight = Vector3.new(1.55, 1.35, -0.4), MountBack = Vector3.new(0, 1.2, 1.7) },
		core = Vector3.new(0, 0.3, 0.75),
	}
end

-- Bomber, small form: the armour and horns are gone. A smooth hazard-striped ball on
-- two small wheels, a red core that blinks fast, a burning fuse and a whip aerial.
local function bomberSmallBody(ctx: Ctx, paint: Color3): Body
	local root = ctx.root
	attach(ctx, root, "Chassis", Vector3.new(3.0, 3.0, 3.0), CFrame.new(0, -0.5, 0), paint, M.Metal, SHAPE.Ball)
	for _, y in { -0.95, -0.05 } do
		attach(ctx, root, "HazardBand", Vector3.new(0.3, 3.02 * math.cos(math.asin((y + 0.5) / 1.5)), 3.02 * math.cos(math.asin((y + 0.5) / 1.5))), CFrame.new(0, y, 0) * AXIS_Y, HAZARD, M.Metal, SHAPE.Cylinder)
	end
	attach(ctx, root, "Core", Vector3.new(1.0, 1.0, 0.3), CFrame.new(0, -0.3, -1.4), Color3.fromRGB(255, 50, 40), M.Neon):SetAttribute("Blink", 4)
	attach(ctx, root, "Visor", Vector3.new(0.9, 0.22, 0.1), CFrame.new(0, 0.35, -1.25) * CFrame.Angles(math.rad(35), 0, 0), SENSOR, M.Neon)
	for _, x in { -1.7, 1.7 } do
		wheel(ctx, x, 0, 1.6, 0.55)
	end
	attach(ctx, root, "Axle", Vector3.new(3.4, 0.3, 0.3), CFrame.new(0, GROUND + 0.8, 0) , DARK, M.Metal, SHAPE.Cylinder)
	attach(ctx, root, "Whip", Vector3.new(0.08, 2.6, 0.08), CFrame.new(0.6, 1.9, 0.9) * CFrame.Angles(math.rad(-12), 0, 0), STEEL, M.Metal)
	attach(ctx, root, "Fuse", Vector3.new(0.5, 0.24, 0.24), CFrame.new(-0.4, 1.15, 0.5) * AXIS_Y, RUBBER, M.Fabric, SHAPE.Cylinder)
	attach(ctx, root, "FuseSpark", Vector3.new(0.45, 0.45, 0.45), CFrame.new(-0.4, 1.45, 0.5), AMBER, M.Neon, SHAPE.Ball):SetAttribute("Blink", 10)
	return {
		turretY = 0.95,
		deck = { w = 2.9, l = 2.9, y = -0.4, z = 0 },
		front = -1.6,
		back = 1.5,
		sockets = { MountLeft = Vector3.new(-1.2, 0.5, 0.1), MountRight = Vector3.new(1.2, 0.5, 0.1), MountBack = Vector3.new(0, 0.7, 1.0) },
		core = Vector3.new(0, 0.3, 0.6),
	}
end

-- Turret tops: what sits on each robot's yaw frame (D78).
local function turretTop(ctx: Ctx, turret: BasePart, chassisId: string, paint: Color3, podWidth: number)
	local top = paint:Lerp(Color3.new(1, 1, 1), 0.08) -- the same paint, a touch sun-faded
	if chassisId == "rookie" then
		attach(ctx, turret, "TurretRing", Vector3.new(0.4, 2.3, 2.3), CFrame.new(0, -0.05, 0) * AXIS_Y, DARK, M.Metal, SHAPE.Cylinder)
		attach(ctx, turret, "Dome", Vector3.new(2.1, 2.1, 2.1), CFrame.new(0, 0.25, 0.1), top, M.Metal, SHAPE.Ball)
		attach(ctx, turret, "Visor", Vector3.new(1.1, 0.22, 0.1), CFrame.new(0, 0.56, -0.9) * CFrame.Angles(math.rad(17), 0, 0), SENSOR, M.Neon)
		for _, x in { -1.1, 1.1 } do
			attach(ctx, turret, "SensorEar", Vector3.new(0.4, 0.55, 0.55), CFrame.new(x, 0.3, 0.1), STEEL, M.Metal, SHAPE.Cylinder)
		end
	elseif chassisId == "bombard" then
		attach(ctx, turret, "TurretRing", Vector3.new(0.45, 2.8, 2.8), CFrame.new(0, 0.05, 0) * AXIS_Y, DARK, M.Metal, SHAPE.Cylinder)
		for _, x in { -1, 1 } do
			attach(ctx, turret, "Cradle", Vector3.new(0.3, 1.5, 1.2), CFrame.new(x * (podWidth / 2 + 0.2), 0.8, 0.2), shade(paint, 0.2), M.Metal)
		end
	elseif chassisId == "scorcher" then
		attach(ctx, turret, "Cowl", Vector3.new(1.7, 0.6, 1.8), CFrame.new(0, 0.05, 0.1), top, M.Metal)
		attach(ctx, turret, "Visor", Vector3.new(0.8, 0.16, 0.08), CFrame.new(0, 0.18, -0.82), SENSOR, M.Neon)
	elseif chassisId == "brawler" then
		attach(ctx, turret, "Housing", Vector3.new(0.55, 2.0, 2.0), CFrame.new(0, 0, 0) * AXIS_Y, shade(paint, 0.3), M.Metal, SHAPE.Cylinder)
		attach(ctx, turret, "Visor", Vector3.new(0.9, 0.15, 0.1), CFrame.new(0, 0.08, -1.0), SENSOR, M.Neon)
	elseif chassisId == "bomber" then
		attach(ctx, turret, "MortarBase", Vector3.new(0.35, 1.9, 1.9), CFrame.new(0, -0.05, 0) * AXIS_Y, DARK, M.Metal, SHAPE.Cylinder)
		attach(ctx, turret, "NetRoll", Vector3.new(0.5, 0.5, 1.2), CFrame.new(1.0, 0.3, 0.3), Color3.fromRGB(150, 120, 80), M.Fabric)
	end
end

-- The recoiling gun frame on the turret, with its kick tuning for clients.
local function gunFrame(ctx: Ctx, turret: BasePart, chassisId: string, offset: Vector3, pitchDegrees: number): Part
	local gun = frame(ctx, turret, "Gun", offset, CFrame.Angles(math.rad(pitchDegrees), 0, 0))
	local k = P.recoil[chassisId] or P.recoil.default
	gun:SetAttribute("Slide", k.slide)
	gun:SetAttribute("Climb", math.rad(k.climb))
	gun:SetAttribute("Settle", k.settle)
	return gun
end

-- Mounted weapons -----------------------------------------------------------------

-- Weapons grow 15% per rank (D36); the signature weapon gets another 25%. Each sits on
-- a swivel that clients turn with the aim, within the hull's front arc (D78).
local function buildMount(ctx: Ctx, turret: BasePart, socketAt: Vector3, weaponId: string, rank: number, signature: boolean)
	local k = (1 + Config.MountRankScale * (rank - 1)) * (if signature then 1.25 else 1)
	local o = socketAt + Vector3.new(0, 0.4 * (k - 1), 0)
	local root = ctx.root
	local swivel: Part? = nil
	local function base(): Part
		if not swivel then
			swivel = motorPart(ctx, root, "Swivel", Vector3.new(0.9, 0.18, 0.9) * k, o - Vector3.new(0, 0.35 * k, 0), DARK, M.Metal)
		end
		return swivel :: Part
	end
	local function part(name: string, size: Vector3, local_: Vector3, color: Color3, material: Enum.Material, rotation: CFrame?, shape: Enum.PartType?): Part
		return attach(ctx, base(), name, size * k, CFrame.new(local_ * k + Vector3.new(0, 0.35 * k, 0)) * (rotation or CFrame.identity), color, material, shape)
	end

	if weaponId == "wpn_gatling" then
		part("Gatling", Vector3.new(0.9, 0.8, 1.4), Vector3.zero, DARK, M.Metal)
		part("AmmoDrum", Vector3.new(0.5, 0.8, 0.8), Vector3.new(0.65, 0, 0.3), shade(STEEL, 0.3), M.Metal, nil, SHAPE.Cylinder)
		for i = 1, rank do
			local x = (i - (rank + 1) / 2) * 0.22
			part("GatlingBarrel", Vector3.new(1.4, 0.18, 0.18), Vector3.new(x, 0.1, -1.3), STEEL, M.Metal, AXIS_Z, SHAPE.Cylinder)
		end
		part("BarrelClamp", Vector3.new(0.2, 0.55, 0.55), Vector3.new(0, 0.1, -1.6), DARK, M.Metal, AXIS_Z, SHAPE.Cylinder)
	elseif weaponId == "wpn_rocket" then
		part("RocketPod", Vector3.new(1.2, 0.9, 1.2), Vector3.zero, Color3.fromRGB(110, 120, 90), M.Metal)
		local tubes = Stats.rocketCount(rank) + 1
		for i = 1, tubes do
			local x = (i - (tubes + 1) / 2) * 0.32
			part("RocketTube", Vector3.new(0.6, 0.28, 0.28), Vector3.new(x, 0.15, -0.65), Color3.fromRGB(165, 46, 36), M.Metal, AXIS_Z, SHAPE.Cylinder)
		end
	elseif weaponId == "wpn_railgun" then
		for _, x in { -0.22, 0.22 } do
			part("Rail", Vector3.new(0.15, 0.25, 3.2), Vector3.new(x, 0.1, -0.8), DARK, M.Metal)
		end
		for i = 1, rank do
			part("RailCoil", Vector3.new(0.25, 0.7, 0.7), Vector3.new(0, 0.1, 0.4 - i * 0.45), Color3.fromRGB(80, 220, 255), M.Neon, AXIS_Z, SHAPE.Cylinder)
		end
	elseif weaponId == "wpn_shock" then
		part("ShockBase", Vector3.new(1.1, 0.4, 1.1), Vector3.zero, DARK, M.Metal)
		for i = 1, rank do
			part("ShockRing", Vector3.new(0.12, 0.9, 0.9), Vector3.new(0, 0.25 + i * 0.22, 0), Color3.fromRGB(120, 200, 255), M.Neon, AXIS_Y, SHAPE.Cylinder)
		end
		part("ShockOrb", Vector3.new(0.6, 0.6, 0.6), Vector3.new(0, 0.5 + rank * 0.22, 0), Color3.fromRGB(200, 240, 255), M.Neon, nil, SHAPE.Ball)
	elseif weaponId == "wpn_spikeram" then
		-- Minotaur Horns: always on the front, whatever socket they took. Two big
		-- horns sweep out and up; a bull plate sits between them.
		local horn = Color3.fromRGB(235, 225, 200)
		for _, side in { -1, 1 } do
			attach(ctx, root, "HornBase", Vector3.new(0.7, 0.7, 1.6) * k, CFrame.new(side * 1.5, 0.1, -2.6) * CFrame.Angles(math.rad(15), math.rad(side * 30), 0), horn, M.SmoothPlastic)
			attach(ctx, root, "HornTip", Vector3.new(0.45, 0.45, 1.5) * k, CFrame.new(side * (2.1 + 0.3 * (k - 1)), 0.7 + 0.2 * (k - 1), -3.3 - 0.3 * (k - 1)) * CFrame.Angles(math.rad(40), math.rad(side * 15), 0), horn, M.SmoothPlastic)
		end
		attach(ctx, root, "RamPlate", Vector3.new(2.4, 1.0, 0.35) * Vector3.new(1, k, 1), CFrame.new(0, -0.3, -2.45), DARK, M.DiamondPlate)
	elseif weaponId == "wpn_sidesaw" then
		-- Vertical Saw: a big blade standing on the middle of the back (D71); clients keep it spinning.
		fade((motorPart(ctx, root, "SideSaw", Vector3.new(0.3, 2.3, 2.3) * k, Vector3.new(0, 0.3 + 0.3 * (k - 1), 2.3 + 0.3 * (k - 1)), STEEL, M.Metal, SHAPE.Cylinder)))
		fade(attach(ctx, root, "SideSawHub", Vector3.new(0.5, 0.5, 0.5) * k, CFrame.new(0, 0.3 + 0.3 * (k - 1), 2.3 + 0.3 * (k - 1)), Color3.fromRGB(200, 60, 50), M.Neon))
	elseif weaponId == "wpn_traps" then
		part("TrapBox", Vector3.new(1.2, 0.8, 1.2), Vector3.zero, DARK, M.DiamondPlate)
		for i = 1, math.min(rank, 3) do
			part("TrapSpike", Vector3.new(0.25, 0.6, 0.25), Vector3.new((i - 2) * 0.35, 0.65, 0), Color3.fromRGB(200, 60, 50), M.Metal)
		end
	elseif weaponId == "wpn_shieldgen" then
		part("ShieldGen", Vector3.new(1.0, 0.9, 1.0), Vector3.zero, DARK, M.Metal)
		part("ShieldCore", Vector3.new(0.6, 0.6, 0.6), Vector3.new(0, 0.6, 0), Color3.fromRGB(110, 230, 160), M.Neon, nil, SHAPE.Ball)
		-- The shield itself turns with the turret, so it faces where you aim. Clients
		-- hide it while it is broken (the Guard attribute).
		attach(ctx, turret, "GuardShield", Vector3.new(5.5 + 0.4 * rank, 3.2, 0.3), CFrame.new(0, 0.3, -4.2), Color3.fromRGB(110, 230, 160), M.ForceField)
	end
end

-- Primary weapons (by robot type) ---------------------------------------------------

local function buildPrimary(ctx: Ctx, turret: BasePart, chassisId: string, build, body: Body, paint: Color3, podWidth: number)
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
		local hub = motorPart(ctx, turret, "Swing", Vector3.new(0.8, 0.8, 0.8), Vector3.new(0, 0.2, 0), DARK, M.Metal, SHAPE.Ball)
		hub:SetAttribute("SwingRate", Config.Weapons.axe.fireRate)
		fade(attach(ctx, hub, "AxeHaft", Vector3.new(0.4, 0.4, len - 1.2), CFrame.new(0, 0, -(len - 1.2) / 2), Color3.fromRGB(110, 75, 45), M.Wood))
		fade(attach(ctx, hub, "AxeBlade", Vector3.new(2.6, 0.25, 2.2), CFrame.new(1.1, 0, -(len - 1.2)), STEEL, M.Metal))
		fade(attach(ctx, hub, "AxeEdge", Vector3.new(0.25, 0.3, 2.4), CFrame.new(2.4, 0, -(len - 1.2)), Color3.fromRGB(205, 210, 215), M.Metal))
		return
	end
	-- Sledgehammer (D71, D80): pivots on the front edge of the turret, held upright,
	-- and slams forward onto its smash area. The head is as wide as the area.
	if weapon == "hammer" then
		local def = Config.Weapons.hammer
		local impactZ = -(R.HitboxRadius + reachU(build, def.reach))
		buildSmashHammer(ctx, turret, body.turretY, "SmashHub", "Smashes", Vector3.new(0, 0.6, -1.2), impactZ, math.min(3.4, reachU(build, def.smashRadius) * 0.7), 1.3)
		return
	end

	if chassisId == "bomber" then
		-- Net mortar: a short, wide tube tilted up, a net bundle in the mouth and four
		-- weights round the rim that pull the net open in flight.
		local gun = gunFrame(ctx, turret, chassisId, Vector3.new(0, 0.55, 0), 35)
		attach(ctx, gun, "MortarTube", Vector3.new(1.6, 1.4, 1.4), CFrame.new(0, 0, -0.4) * AXIS_Z, DARK, M.Metal, SHAPE.Cylinder)
		attach(ctx, gun, "MortarLip", Vector3.new(0.25, 1.75, 1.75), CFrame.new(0, 0, -1.25) * AXIS_Z, STEEL, M.Metal, SHAPE.Cylinder)
		attach(ctx, gun, "NetBundle", Vector3.new(0.2, 1.2, 1.2), CFrame.new(0, 0, -1.2) * AXIS_Z, Color3.fromRGB(150, 120, 80), M.Fabric, SHAPE.Cylinder)
		for _, c in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
			attach(ctx, gun, "NetWeight", Vector3.new(0.32, 0.32, 0.32), CFrame.new(c[1] * 0.62, c[2] * 0.62, -1.35), BRASS, M.Metal, SHAPE.Ball)
		end
		return
	end

	if chassisId == "brawler" then
		-- A big horizontal buzzsaw in front, sized so its edge is where it hits (D71);
		-- clients spin it while attacking. Teeth ride on the disc; a guard covers its back.
		local r = reachU(build, Config.Weapons.buzzsaw.reach)
		local cz = -(R.HitboxRadius + r / 2)
		local disc = r + 0.6
		local saw = motorPart(ctx, turret, "Saw", Vector3.new(0.35, disc, disc), Vector3.new(0, -0.3, cz), STEEL, M.Metal, SHAPE.Cylinder, AXIS_Y)
		-- In the saw's frame X is up, so teeth go round its Y-Z plane.
		for i = 0, 9 do
			local a = i * math.pi / 5
			attach(ctx, saw, "SawTooth", Vector3.new(0.3, 0.45, 0.5), CFrame.Angles(a, 0, 0) * CFrame.new(0, disc / 2 + 0.1, 0), Color3.fromRGB(205, 210, 215), M.Metal, SHAPE.Wedge)
		end
		attach(ctx, saw, "SawRing", Vector3.new(0.38, disc * 0.55, disc * 0.55), CFrame.identity, HAZARD, M.Metal, SHAPE.Cylinder)
		attach(ctx, turret, "SawHub", Vector3.new(0.9, 0.9, 0.9), CFrame.new(0, -0.1, cz), DARK, M.Metal, SHAPE.Ball)
		attach(ctx, turret, "SawArm", Vector3.new(0.6, 0.5, -cz - 0.8), CFrame.new(0, -0.2, (cz - 0.8) / 2), DARK, M.Metal)
		attach(ctx, turret, "SawGuard", Vector3.new(disc + 0.4, 0.12, disc * 0.45), CFrame.new(0, 0.05, cz + disc * 0.3), shade(STEEL, 0.2), M.DiamondPlate)
		return
	end

	if chassisId == "scorcher" then
		-- Flamethrower: a regulator block, a long barrel with heat bands, a flared bell
		-- and a glowing tip. The emitters sit on an invisible "Nozzle" at the tip.
		local gun = gunFrame(ctx, turret, chassisId, Vector3.new(0, 0.0, -0.7), 0)
		local w = thick + 0.4
		attach(ctx, gun, "Regulator", Vector3.new(0.9, 0.7, 0.9), CFrame.identity, DARK, M.Metal)
		attach(ctx, gun, "Gauge", Vector3.new(0.35, 0.35, 0.35), CFrame.new(0.45, 0.42, 0.1), BRASS, M.Metal, SHAPE.Ball)
		attach(ctx, gun, "NozzleBarrel", Vector3.new(2.6, w, w), CFrame.new(0, 0, -1.75) * AXIS_Z, DARK, M.Metal, SHAPE.Cylinder)
		for _, z in { -1.2, -2.3 } do
			attach(ctx, gun, "HeatBand", Vector3.new(0.2, w + 0.2, w + 0.2), CFrame.new(0, 0, z) * AXIS_Z, Color3.fromRGB(70, 78, 96), M.Metal, SHAPE.Cylinder):SetAttribute("HeatGlow", true)
		end
		attach(ctx, gun, "Bell", Vector3.new(0.55, w + 0.8, w + 0.8), CFrame.new(0, 0, -3.2) * AXIS_Z, shade(STEEL, 0.3), M.Metal, SHAPE.Cylinder)
		attach(ctx, gun, "NozzleTip", Vector3.new(0.12, w + 0.6, w + 0.6), CFrame.new(0, 0, -3.5) * AXIS_Z, Color3.fromRGB(90, 40, 30), M.Neon, SHAPE.Cylinder):SetAttribute("HeatGlow", true)
		attach(ctx, ctx.root, "FuelLine", Vector3.new(0.16, 0.16, 2.4), CFrame.new(0.5, -0.1, 0.2), RUBBER, M.SmoothPlastic)
		local nozzle = attach(ctx, gun, "Nozzle", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, 0, -3.55), DARK, M.SmoothPlastic)
		nozzle.Transparency = 1
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
		-- Pilot light: a small blue-tipped flame that burns at the tip while idle.
		local pilot = Instance.new("ParticleEmitter")
		pilot.Name = "PilotLight"
		pilot.EmissionDirection = Enum.NormalId.Front
		pilot.Rate = 25
		pilot.Speed = NumberRange.new(1, 2)
		pilot.Lifetime = NumberRange.new(0.15, 0.25)
		pilot.LightEmission = 1
		pilot.Color = ColorSequence.new(Color3.fromRGB(110, 170, 255), Color3.fromRGB(255, 150, 50))
		pilot.Size = NumberSequence.new(0.35, 0.1)
		pilot.Transparency = NumberSequence.new(0.2, 1)
		pilot.Parent = nozzle
		return
	end

	if chassisId == "bombard" then
		-- Box launcher on trunnions, tilted up: two rows of tubes (one row from 4
		-- barrels), a red rocket nose in each, a sight with a cyan lens, a backblast vent.
		local gun = gunFrame(ctx, turret, chassisId, Vector3.new(0, 1.35, 0.2), 12)
		local rows = if barrels >= 4 then 1 else 2
		local podLen = if rangeTier >= 1 then 3.0 else 2.6
		attach(ctx, gun, "Pod", Vector3.new(podWidth, 0.75 * rows + 0.5, podLen), CFrame.new(0, 0, -0.3), shade(paint, 0.2), M.Metal)
		local front = -0.3 - podLen / 2
		for c = 1, barrels do
			local x = (c - (barrels + 1) / 2) * 0.62
			for r = 1, rows do
				local y = (r - (rows + 1) / 2) * 0.68
				attach(ctx, gun, "LaunchTube", Vector3.new(0.2, 0.56, 0.56), CFrame.new(x, y, front - 0.05) * AXIS_Z, RUBBER, M.Metal, SHAPE.Cylinder)
				attach(ctx, gun, "RocketNose", Vector3.new(0.36, 0.36, 0.36), CFrame.new(x, y, front + 0.02), Color3.fromRGB(170, 42, 32), M.Metal, SHAPE.Ball)
			end
		end
		for _, x in { -1, 1 } do
			attach(ctx, gun, "PodStripe", Vector3.new(0.05, 0.22, podLen * 0.85), CFrame.new(x * (podWidth / 2 + 0.01), 0.15, -0.3), HAZARD, M.Metal)
		end
		attach(ctx, gun, "Backblast", Vector3.new(podWidth * 0.7, 0.75 * rows, 0.12), CFrame.new(0, 0, -0.3 + podLen / 2 + 0.05), DARK, M.DiamondPlate)
		attach(ctx, gun, "Sight", Vector3.new(0.4, 0.35, 0.8), CFrame.new(podWidth / 2 - 0.3, 0.375 * rows + 0.42, -0.6), DARK, M.Metal)
		attach(ctx, gun, "SightLens", Vector3.new(0.26, 0.2, 0.06), CFrame.new(podWidth / 2 - 0.3, 0.375 * rows + 0.42, -1.02), SENSOR, M.Neon)
		if rateTier >= 1 then
			attach(ctx, gun, "AmmoDrum", Vector3.new(0.6, 1.0, 1.0), CFrame.new(-(podWidth / 2 + 0.35), 0, 0.2), shade(STEEL, 0.3), M.Metal, SHAPE.Cylinder)
		end
		return
	end

	-- Rookie: blaster barrels (or the Laser Gun), one per Extra Barrel, on a finned breech.
	local gun = gunFrame(ctx, turret, chassisId, Vector3.new(0, 0.35, -0.6), 0)
	attach(ctx, gun, "Breech", Vector3.new(1.0, 0.75, 1.1), CFrame.new(0, 0, 0), DARK, M.Metal)
	for i = -1, 1 do
		attach(ctx, gun, "BreechFin", Vector3.new(0.9, 0.14, 0.08), CFrame.new(0, 0.42, i * 0.3), STEEL, M.Metal)
	end
	local len = R.BarrelLength * (if rangeTier >= 1 then 1.3 else 1)
	local width = thick
	local gap = math.max(width + 0.1, 0.5)
	for i = 1, barrels do
		local offset = i - (barrels + 1) / 2
		local yaw = if spread then -math.rad(offset * Config.Barrels.spreadDegrees) else 0
		local x = if spread then offset * 0.25 else offset * gap
		local cf = CFrame.new(x, 0, -0.6) * CFrame.Angles(0, yaw, 0) * CFrame.new(0, 0, -len / 2)
		if weapon == "laser" then
			attach(ctx, gun, "Barrel", Vector3.new(len, width, width), cf * AXIS_Z, Color3.fromRGB(200, 204, 210), M.Metal, SHAPE.Cylinder)
			attach(ctx, gun, "LaserLens", Vector3.new(width + 0.2, width + 0.2, width + 0.2), cf * CFrame.new(0, 0, -len / 2), Color3.fromRGB(255, 40, 60), M.Neon, SHAPE.Ball)
		else
			attach(ctx, gun, "Barrel", Vector3.new(len, width, width), cf * AXIS_Z, DARK, M.Metal, SHAPE.Cylinder)
			-- An amber energy coil and a muzzle brake at the tip.
			attach(ctx, gun, "Coil", Vector3.new(0.2, width + 0.16, width + 0.16), cf * CFrame.new(0, 0, len * 0.1) * AXIS_Z, Color3.fromRGB(255, 210, 90), M.Neon, SHAPE.Cylinder)
			attach(ctx, gun, "Muzzle", Vector3.new(width + 0.16, width + 0.16, 0.4), cf * CFrame.new(0, 0, -len / 2 + 0.1), shade(STEEL, 0.35), M.Metal)
		end
		if rateTier >= 1 then
			attach(ctx, gun, "CoolingRing", Vector3.new(0.2, width + 0.25, width + 0.25), cf * CFrame.new(0, 0, len * 0.3) * AXIS_Z, STEEL, M.Metal, SHAPE.Cylinder)
		end
	end
	if rangeTier >= 2 then
		attach(ctx, gun, "Scope", Vector3.new(0.35, 0.35, 1.6), CFrame.new(0.75, 0.55, -0.4), DARK, M.Metal)
		attach(ctx, gun, "ScopeLens", Vector3.new(0.25, 0.25, 0.06), CFrame.new(0.75, 0.55, -1.22), SENSOR, M.Neon)
	end
end

-- Level bands and upgrade parts, placed on each body's deck -----------------------------

local function dressDeck(ctx: Ctx, build, body: Body, level: number, trim: Color3, paint: Color3, speedTier: number)
	local root = ctx.root
	local st = build.stacks
	local d = body.deck
	local half = d.w / 2
	-- Level bands: a glance tells you how far along a robot is.
	if level >= 20 then
		for _, x in { -1, 1 } do
			attach(ctx, root, "Stripe", Vector3.new(0.08, 0.3, d.l * 0.85), CFrame.new(x * (half + 0.03), d.y - 0.35, d.z), trim, M.Metal)
		end
	end
	if level >= 40 then
		local z = body.back - 0.35
		attach(ctx, root, "LightBar", Vector3.new(d.w * 0.7, 0.15, 0.2), CFrame.new(0, d.y + 0.6, z), DARK, M.Metal)
		for _, x in { -1, 1 } do
			attach(ctx, root, "LightBarPost", Vector3.new(0.12, 0.6, 0.12), CFrame.new(x * d.w * 0.33, d.y + 0.3, z), DARK, M.Metal)
			attach(ctx, root, "BeaconLamp", Vector3.new(0.3, 0.22, 0.14), CFrame.new(x * d.w * 0.2, d.y + 0.75, z), AMBER, M.Neon):SetAttribute("Blink", 0.8)
		end
	end
	if level >= 60 then
		attach(ctx, root, "Hull", Vector3.new(d.w - 0.4, 0.3, d.l * 0.5), CFrame.new(0, d.y + 0.15, d.z + d.l * 0.2), paint:Lerp(DARK, 0.4), M.DiamondPlate)
	end
	if level >= 80 then
		attach(ctx, root, "Crest", Vector3.new(0.3, 1.4, 1.4), CFrame.new(0, d.y + 1.0, body.back - 0.9), trim, M.Metal)
	end
	if level >= 100 then
		for _, z in { -1, 1 } do
			attach(ctx, root, "GoldTrim", Vector3.new(d.w + 0.1, 0.2, 0.2), CFrame.new(0, d.y + 0.05, d.z + z * d.l / 2), BRASS, M.Metal)
		end
		for _, x in { -1, 1 } do
			attach(ctx, root, "GoldTrim", Vector3.new(0.2, 0.2, d.l + 0.1), CFrame.new(x * (half + 0.05), d.y + 0.05, d.z), BRASS, M.Metal)
		end
	end

	-- Armor Plating shows as plates (D33); Max HP as a battery and a frame.
	local armorStacks = st.stat_armor or 0
	local plate = shade(STEEL, 0.25)
	if armorStacks >= 1 then
		for _, x in { -1, 1 } do
			attach(ctx, root, "SideArmor", Vector3.new(0.3, 1.2, d.l * 0.8), CFrame.new(x * (half + 0.3), d.y - 0.75, d.z), plate, M.DiamondPlate)
		end
	end
	if armorStacks >= 3 then
		attach(ctx, root, "FrontArmor", Vector3.new(d.w * 0.85, 0.9, 0.35), CFrame.new(0, d.y - 0.6, body.front + 0.45), plate, M.DiamondPlate)
	end
	if armorStacks >= 5 then
		attach(ctx, root, "RoofArmor", Vector3.new(d.w * 0.75, 0.25, 1.0), CFrame.new(0, d.y + 0.15, body.back - 1.0), plate, M.DiamondPlate)
	end
	local hpTier = tier(st.stat_hp or 0, 3, 6)
	if hpTier >= 1 then
		attach(ctx, root, "Battery", Vector3.new(2.2, 0.8, 0.7), CFrame.new(0, d.y - 0.5, body.back + 0.35), Color3.fromRGB(58, 66, 60), M.Metal)
		attach(ctx, root, "Terminal", Vector3.new(0.25, 0.25, 0.25), CFrame.new(-0.75, d.y - 0.02, body.back + 0.35), TAIL, M.Metal)
		attach(ctx, root, "Terminal", Vector3.new(0.25, 0.25, 0.25), CFrame.new(0.75, d.y - 0.02, body.back + 0.35), DARK, M.Metal)
	end
	if hpTier >= 2 then
		attach(ctx, root, "Frame", Vector3.new(d.w + 0.3, 0.35, d.l + 0.5), CFrame.new(0, GROUND + 0.85, d.z), DARK, M.Metal)
	end
	local pickup = st.stat_pickup or 0
	if pickup >= 2 then
		attach(ctx, root, "PickupAntenna", Vector3.new(0.15, 2.5, 0.15), CFrame.new(half - 0.3, d.y + 1.25, body.back - 0.5), STEEL, M.Metal)
	end
	if pickup >= 4 then
		attach(ctx, root, "MagnetDish", Vector3.new(0.3, 1.6, 1.6), CFrame.new(-(half - 0.4), d.y + 0.7, body.back - 0.6) * AXIS_Y, shade(STEEL, 0.1), M.Metal, SHAPE.Cylinder)
	end
	if speedTier >= 2 then
		for _, x in { -1, 1 } do
			attach(ctx, root, "ExhaustFin", Vector3.new(0.3, 1.0, 1.2), CFrame.new(x * 1.2, d.y + 0.4, body.back - 0.2), STEEL, M.Metal)
		end
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
	local speedTier = tier(st.stat_speed or 0, 3, 6)
	local barrels = math.min(Config.Barrels.max, 1 + (st.stat_barrels or 0))
	local podWidth = math.max(1.7, barrels * 0.62 + 0.45)

	local body: Body
	if chassisId == "bombard" then
		body = bombardBody(ctx, paint)
	elseif chassisId == "scorcher" then
		body = scorcherBody(ctx, paint, speedTier)
	elseif chassisId == "brawler" then
		body = brawlerBody(ctx, paint)
	elseif chassisId == "bomber" then
		body = if build.small then bomberSmallBody(ctx, paint) else bomberBody(ctx, paint)
	else
		body = rookieBody(ctx, paint, speedTier)
	end
	dressDeck(ctx, build, body, level, trim, paint, speedTier)

	-- Turret: an invisible yaw frame on a Motor6D that every client turns toward the aim.
	local turret, motor = motorPart(ctx, root, "Turret", Vector3.new(0.4, 0.4, 0.4), Vector3.new(0, body.turretY, 0), paint, M.Metal)
	turret.Transparency = 1
	motor.Name = "TurretMotor"
	turretTop(ctx, turret, chassisId, paint, podWidth)
	buildPrimary(ctx, turret, chassisId, build, body, paint, podWidth)

	local rateTier = tier(st.stat_firerate or 0, 3, 6)
	if rateTier >= 2 then
		for _, x in { -1.0, 1.0 } do
			attach(ctx, turret, "HeatVent", Vector3.new(0.2, 0.5, 1.2), CFrame.new(x, 0.6, 0.4), Color3.fromRGB(255, 120, 40), M.Neon)
		end
	end
	if build.skill then
		local coreColor = ({
			skl_dash = Color3.fromRGB(80, 230, 255),
			skl_shield = Color3.fromRGB(240, 240, 255),
			skl_nullfield = Color3.fromRGB(170, 110, 255),
			skl_flipper = Color3.fromRGB(255, 200, 60),
			skl_earthwall = Color3.fromRGB(170, 120, 70),
			skl_bomb = Color3.fromRGB(255, 80, 40),
		})[build.skill] or Color3.new(1, 1, 1)
		attach(ctx, turret, "SkillCore", Vector3.new(0.7, 0.7, 0.7), CFrame.new(body.core), coreColor, M.Neon, SHAPE.Ball)
	end
	if build.skill == "skl_flipper" then
		-- Flipper plate on the front, hinged at its back edge; clients kick it up on each flip (Flips).
		local hinge = motorPart(ctx, root, "FlipperHub", Vector3.new(4.2, 0.3, 0.3), Vector3.new(0, -1.0, body.front + 0.15), DARK, M.Metal)
		attach(ctx, hinge, "FlipperPlate", Vector3.new(4.2, 0.25, 1.6), CFrame.new(0, 0, -0.8), HAZARD, M.DiamondPlate)
		for _, x in { -1.2, 1.2 } do
			attach(ctx, hinge, "FlipperRam", Vector3.new(0.3, 0.3, 1.0), CFrame.new(x, 0.2, 0.3), STEEL, M.Metal)
		end
	end

	-- Mounts; the highest rank is the signature weapon (first one wins a tie).
	local signatureIndex, best = 0, 0
	for i, weaponId in build.mounts do
		if (st[weaponId] or 1) > best then
			signatureIndex, best = i, st[weaponId] or 1
		end
	end
	for i, weaponId in build.mounts do
		local socket = Config.MountSockets[i]
		buildMount(ctx, turret, body.sockets[socket], weaponId, st[weaponId] or 1, i == signatureIndex and #build.mounts > 1)
	end

	folder.Parent = model
	model:SetAttribute("DressedLevel", level)
end

-- (Re)builds every visible part for the robot's build, size, type and level.
function RobotBuilder.dress(model: Model, build, color: Color3, scale: number, chassisId: string, level: number)
	buildBody(model, model.PrimaryPart :: BasePart, build, color, scale, chassisId, level)
	model:SetAttribute("Small", build.small == true)
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
	model:SetAttribute("Chassis", chassisId)
	model:SetAttribute("Small", build.small == true)
	model.Parent = Workspace
	return model
end

return RobotBuilder
