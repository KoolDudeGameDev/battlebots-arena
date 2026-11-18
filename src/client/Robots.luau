-- Per-robot presentation for every robot in the arena: name, level and HP tag,
-- turret rotation, damage flash, spawn-protection fade, the shield bubble, and
-- two ground markers everyone can see: a filled disc for the hitbox and a faint
-- thin ring for the attack range ("danger zone").
-- Reads the attributes the server sets on each robot model.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ClientState = require(script.Parent.ClientState)
local Sfx = require(script.Parent.Sfx)
local RobotMotion = require(Shared.RobotMotion)

local Robots = {}

local player = Players.LocalPlayer
local fxFolder: Folder
local RING_SHOW_MARGIN = 25 -- studs outside an enemy's range where its ring appears
local PRES = Config.Presentation
local SWIVEL = math.rad(PRES.swivelDegrees)
local HEAT_COLD = Color3.fromRGB(90, 40, 30)
local HEAT_HOT = Color3.fromRGB(255, 150, 50)

-- A mounted weapon's swivel (D82): it follows the aim, but swings to face each of
-- its own shots for a moment and kicks back when it fires.
type Mount = { motor: Motor6D, weapon: string?, muzzle: Attachment?, rel: number, aimAngle: number, aimUntil: number, kick: number }

-- Animated parts found in a robot's Body (rescanned whenever the body is rebuilt).
type Rig = {
	yaw: { Motor6D }, -- turret: turns with the aim inside the swivel arc
	mounts: { Mount },
	gun: Motor6D?,
	gunPart: BasePart?,
	blink: { BasePart },
	heat: { BasePart },
	flameLoop: Sound?,
	sawLoop: Sound?,
}

type View = {
	model: Model,
	gui: BillboardGui,
	levelLabel: TextLabel,
	hpBack: Frame,
	hpFill: Frame,
	armorBack: Frame,
	armorFill: Frame,
	pressureBack: Frame, -- Bomber shell: how big its blast is now (D84)
	pressureFill: Frame,
	markLabel: TextLabel, -- marked by a Bomber net (D84)
	highlight: Highlight,
	hitDisc: CylinderHandleAdornment,
	rangeRing: CylinderHandleAdornment,
	bubble: Part?,
	field: Part?, -- Null Field dome
	fieldT: number, -- seconds since the dome opened
	net: Part?, -- Bomber net
	fadeBody: Instance?, -- the Body the fade list was built for
	fadeParts: { BasePart },
	stars: Part?, -- Flipper stun marker
	lastFlips: number,
	flipT: number,
	sideSpin: number,
	smash: { [string]: { last: number, t: number } }, -- per hammer hub
	angle: number,
	hasAim: boolean,
	spin: number,
	sawRate: number, -- spins up and down instead of snapping (D78)
	kick: number, -- recoil, 1 at the shot and settling to 0
	heat: number, -- Scorcher heat glow, 0-1
	lastHp: number,
	lastArmor: number,
	rig: Rig?,
	rigBody: Instance?,
	smoke: ParticleEmitter,
	sparks: ParticleEmitter,
	burn: { ParticleEmitter }, -- flames and smoke while burning (D88)
	burnLight: PointLight,
	conns: { RBXScriptConnection },
}

local views: { [Model]: View } = {}
local sawBase: { [Motor6D]: CFrame } = {} -- each saw's resting C0
local SMASH_HUBS = { "SmashHub" } -- the Sledgehammer main weapon
local FLAME_PARTS = { "Flame", "FlameCore", "FlameEmbers", "FlameSmoke", "FlameLight" } -- on the Scorcher's Nozzle (D88)
setmetatable(sawBase :: any, { __mode = "k" }) -- forget saws that were rebuilt

local function bandColor(level: number): Color3
	local color = Config.LevelBands[1].color
	for _, band in Config.LevelBands do
		if level >= band.min then
			color = band.color
		end
	end
	return Color3.fromRGB(color[1], color[2], color[3])
end

local function label(parent: Instance, text: string, size: number, pos: UDim2, height: number): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, height)
	l.Position = pos
	l.Font = Enum.Font.GothamBold
	l.TextSize = size
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.Text = text
	l.Parent = parent
	return l
end

local function refresh(v: View)
	local m = v.model
	local level = m:GetAttribute("Level") or 0
	v.levelLabel.Text = "Lv " .. level
	v.levelLabel.TextColor3 = bandColor(level)
	local hp = m:GetAttribute("HP") or 0
	local maxHp = m:GetAttribute("MaxHP") or 100
	v.hpFill.Size = UDim2.fromScale(math.clamp(hp / maxHp, 0, 1), 1)
	local armor = m:GetAttribute("Armor") or 0
	local maxArmor = m:GetAttribute("MaxArmor") or 0
	local hasArmor = armor > 0 or maxArmor > 0
	-- A boss's bars live in the HUD (top centre), so its tag shows only the name, high
	-- above the body where it never hides the boss itself (D78).
	local boss = m:HasTag("Boss")
	v.hpBack.Visible = not boss and (hp < maxHp or hasArmor)
	v.armorBack.Visible = not boss and hasArmor
	v.levelLabel.Visible = not boss
	v.armorFill.Size = UDim2.fromScale(math.clamp(armor / math.max(maxArmor, armor, 1), 0, 1), 1)
	local pressure = m:GetAttribute("Pressure")
	v.pressureBack.Visible = not boss and m:GetAttribute("Chassis") == "bomber" and not m:GetAttribute("Small") and type(pressure) == "number"
	v.pressureFill.Size = UDim2.fromScale(math.clamp((tonumber(pressure) or 0) / 100, 0, 1), 1)
	v.markLabel.Visible = m:GetAttribute("Marked") == true
	local scale = m:GetAttribute("VisualScale") or 1
	v.gui.StudsOffsetWorldSpace = Vector3.new(0, 2.5 + 3 * scale, 0)

	-- Damage you can read without the bar (D78): smoke under 35% HP, sparks under 15%.
	local frac = hp / math.max(1, maxHp)
	v.smoke.Enabled = hp > 0 and frac < PRES.smokeBelow
	v.smoke.Rate = 6 + 18 * (1 - frac / PRES.smokeBelow)
	v.sparks.Enabled = hp > 0 and frac < PRES.sparksBelow

	-- Burning (D88): set alight by a flamethrower, the Inferno Giant or lava.
	local burning = m:GetAttribute("Burning") == true
	for _, e in v.burn do
		e.Enabled = burning
	end
	v.burnLight.Enabled = burning

	local hitRadius = m:GetAttribute("HitRadius") or Config.Robot.HitboxRadius
	v.hitDisc.Radius = hitRadius
	local range = m:GetAttribute("AttackRange") or 0
	v.rangeRing.Radius = range
	v.rangeRing.InnerRadius = math.max(0, range - 0.3) -- a thin line, not a filled area
end

-- A flat marker on the ground under the robot (adornments draw without Parts).
local function groundMarker(root: BasePart, color: Color3, transparency: number): CylinderHandleAdornment
	local a = Instance.new("CylinderHandleAdornment")
	a.Adornee = root
	a.Height = 0.06
	a.Color3 = color
	a.Transparency = transparency
	a.AlwaysOnTop = false
	a.ZIndex = 0
	-- The cylinder's axis is its Z; tip it upright and sit it just above the grass.
	local groundOffset = Config.Robot.HipHeight + Config.Robot.RootSize[2] / 2 - 0.15
	a.CFrame = CFrame.new(0, -groundOffset, 0) * CFrame.Angles(math.rad(90), 0, 0)
	a.Parent = fxFolder
	return a
end

local function setFade(v: View)
	local amount = if v.model:GetAttribute("Protected") then 0.55 else 0
	for _, d in v.model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Name ~= "Head" then
			d.LocalTransparencyModifier = amount
		end
	end
end

local function flash(v: View, color: Color3?)
	v.highlight.FillColor = color or Color3.new(1, 1, 1)
	v.highlight.FillTransparency = 0.15
	task.delay(0.08, function()
		if v.highlight.Parent then
			v.highlight.FillTransparency = 1
		end
	end)
end

local function add(model: Instance)
	if not model:IsA("Model") or views[model] then
		return
	end
	local root = model:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root or not model.Parent then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(170, 78) -- the top line is the MARKED tag (D84)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = root
	gui.ResetOnSpawn = false
	local name = (model:GetAttribute("DisplayName") or model.Name) :: string
	label(gui, name, 14, UDim2.fromOffset(0, 16), 16)
	local levelLabel = label(gui, "Lv 0", 14, UDim2.fromOffset(0, 32), 16)
	local hpBack = Instance.new("Frame")
	hpBack.Size = UDim2.fromOffset(130, 11)
	hpBack.Position = UDim2.new(0.5, -65, 0, 51)
	hpBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBack.BorderSizePixel = 0
	hpBack.Parent = gui
	local hpFill = Instance.new("Frame")
	hpFill.BackgroundColor3 = if model == player.Character then Color3.fromRGB(90, 220, 110) else Color3.fromRGB(235, 80, 70)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBack
	local armorBack = Instance.new("Frame")
	armorBack.Size = UDim2.fromOffset(130, 6)
	armorBack.Position = UDim2.new(0.5, -65, 0, 64)
	armorBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	armorBack.BorderSizePixel = 0
	armorBack.Visible = false
	armorBack.Parent = gui
	local armorFill = Instance.new("Frame")
	armorFill.BackgroundColor3 = Color3.fromRGB(110, 170, 255)
	armorFill.BorderSizePixel = 0
	armorFill.Parent = armorBack
	-- Bomber Pressure (D84): an orange gauge under the bars, so everyone can see how
	-- big the blast would be right now.
	local pressureBack = Instance.new("Frame")
	pressureBack.Size = UDim2.fromOffset(130, 5)
	pressureBack.Position = UDim2.new(0.5, -65, 0, 71)
	pressureBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	pressureBack.BorderSizePixel = 0
	pressureBack.Visible = false
	pressureBack.Parent = gui
	local pressureFill = Instance.new("Frame")
	pressureFill.BackgroundColor3 = Color3.fromRGB(255, 140, 40)
	pressureFill.BorderSizePixel = 0
	pressureFill.Parent = pressureBack
	-- A yellow chevron while a Bomber net has marked this robot.
	local markLabel = label(gui, "▼ MARKED", 12, UDim2.fromOffset(0, 0), 14)
	markLabel.TextColor3 = Color3.fromRGB(255, 215, 40)
	markLabel.Visible = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 1
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Adornee = model
	highlight.Parent = fxFolder

	-- Ground markers: your own in green/white, everyone else's in red.
	local mine = model == player.Character
	local hitDisc = groundMarker(root, if mine then Color3.fromRGB(90, 220, 110) else Color3.fromRGB(235, 80, 70), 0.72)
	local rangeRing = groundMarker(root, if mine then Color3.new(1, 1, 1) else Color3.fromRGB(255, 140, 130), 0.8)

	-- Damage smoke and sparks rise from the hull (a local attachment on the root).
	local hull = Instance.new("Attachment")
	hull.Name = "DamageFx"
	hull.Position = Vector3.new(0, 0.5, 0.6)
	hull.Parent = root
	local smoke = Instance.new("ParticleEmitter")
	smoke.Enabled = false
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(60, 58, 56), Color3.fromRGB(110, 108, 104))
	smoke.Size = NumberSequence.new(1, 3.5)
	smoke.Transparency = NumberSequence.new(0.35, 1)
	smoke.Lifetime = NumberRange.new(1.2, 1.8)
	smoke.Speed = NumberRange.new(3, 5)
	smoke.SpreadAngle = Vector2.new(15, 15)
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.Parent = hull
	local sparks = Instance.new("ParticleEmitter")
	sparks.Enabled = false
	sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparks.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120))
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.35, 0)
	sparks.Lifetime = NumberRange.new(0.3, 0.6)
	sparks.Speed = NumberRange.new(8, 14)
	sparks.SpreadAngle = Vector2.new(60, 60)
	sparks.Acceleration = Vector3.new(0, -40, 0)
	sparks.Rate = 12
	sparks.EmissionDirection = Enum.NormalId.Top
	sparks.Parent = hull

	-- Burning: flames licking up off the hull, thick dark smoke and an orange glow.
	-- The smoke keeps drifting for a second or two after the fire goes out.
	local burnAt = Instance.new("Attachment")
	burnAt.Name = "BurnFx"
	burnAt.Position = Vector3.new(0, 1, 0)
	burnAt.Parent = root
	local burnFire = Instance.new("ParticleEmitter")
	burnFire.Enabled = false
	burnFire.Texture = "rbxasset://textures/particles/fire_main.dds"
	burnFire.Rate = 34
	burnFire.Lifetime = NumberRange.new(0.45, 0.8)
	burnFire.Speed = NumberRange.new(3, 6)
	burnFire.SpreadAngle = Vector2.new(30, 30)
	burnFire.EmissionDirection = Enum.NormalId.Top
	burnFire.Acceleration = Vector3.new(0, 5, 0)
	burnFire.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(0.4, 2.4), NumberSequenceKeypoint.new(1, 0.4) })
	burnFire.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.7, 0.4), NumberSequenceKeypoint.new(1, 1) })
	burnFire.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 235, 140)), ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 130, 30)), ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 40, 10)) })
	burnFire.LightEmission = 1
	burnFire.Rotation = NumberRange.new(0, 360)
	burnFire.RotSpeed = NumberRange.new(-120, 120)
	burnFire.Parent = burnAt
	local burnSmoke = Instance.new("ParticleEmitter")
	burnSmoke.Enabled = false
	burnSmoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	burnSmoke.Rate = 14
	burnSmoke.Lifetime = NumberRange.new(1.6, 2.4)
	burnSmoke.Speed = NumberRange.new(4, 7)
	burnSmoke.SpreadAngle = Vector2.new(18, 18)
	burnSmoke.EmissionDirection = Enum.NormalId.Top
	burnSmoke.Acceleration = Vector3.new(0, 2, 0)
	burnSmoke.Size = NumberSequence.new(1.5, 5)
	burnSmoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.12, 0.35), NumberSequenceKeypoint.new(1, 1) })
	burnSmoke.Color = ColorSequence.new(Color3.fromRGB(38, 35, 33), Color3.fromRGB(95, 92, 88))
	burnSmoke.Rotation = NumberRange.new(0, 360)
	burnSmoke.RotSpeed = NumberRange.new(-30, 30)
	burnSmoke.Parent = burnAt
	local burnLight = Instance.new("PointLight")
	burnLight.Enabled = false
	burnLight.Color = Color3.fromRGB(255, 130, 40)
	burnLight.Range = 10
	burnLight.Brightness = 2
	burnLight.Shadows = false
	burnLight.Parent = burnAt

	local v: View = {
		model = model,
		gui = gui,
		levelLabel = levelLabel,
		hpBack = hpBack,
		hpFill = hpFill,
		armorBack = armorBack,
		armorFill = armorFill,
		pressureBack = pressureBack,
		pressureFill = pressureFill,
		markLabel = markLabel,
		highlight = highlight,
		hitDisc = hitDisc,
		rangeRing = rangeRing,
		bubble = nil,
		field = nil,
		fieldT = 0,
		net = nil,
		fadeBody = nil,
		fadeParts = {},
		stars = nil,
		lastFlips = 0,
		flipT = math.huge,
		sideSpin = 0,
		smash = {},
		angle = 0,
		hasAim = false,
		spin = 0,
		sawRate = 2,
		kick = 0,
		heat = 0,
		lastHp = model:GetAttribute("HP") or 0,
		lastArmor = model:GetAttribute("Armor") or 0,
		rig = nil,
		rigBody = nil,
		smoke = smoke,
		sparks = sparks,
		burn = { burnFire, burnSmoke },
		burnLight = burnLight,
		conns = {},
	}
	views[model] = v
	refresh(v)
	setFade(v)

	table.insert(v.conns, model:GetAttributeChangedSignal("HP"):Connect(function()
		local hp = model:GetAttribute("HP") or 0
		if hp < v.lastHp then
			flash(v)
			if model == player.Character then
				ClientState.actions.shake(0.35)
			end
		end
		v.lastHp = hp
		refresh(v)
	end))
	-- Armor soaking a hit flashes blue instead of white (D78).
	table.insert(v.conns, model:GetAttributeChangedSignal("Armor"):Connect(function()
		local armor = model:GetAttribute("Armor") or 0
		if armor < v.lastArmor then
			flash(v, Color3.fromRGB(110, 170, 255))
		end
		v.lastArmor = armor
		refresh(v)
	end))
	for _, attr in { "MaxHP", "MaxArmor", "HitRadius", "AttackRange", "VisualScale", "Pressure", "Marked", "Small", "Burning" } do
		table.insert(v.conns, model:GetAttributeChangedSignal(attr):Connect(function()
			refresh(v)
		end))
	end
	local lastLevel = model:GetAttribute("Level") or 0
	table.insert(v.conns, model:GetAttributeChangedSignal("Level"):Connect(function()
		local level = model:GetAttribute("Level") or 0
		if model == player.Character and level > lastLevel then
			Sfx.ui("LevelUp")
		end
		lastLevel = level
		refresh(v)
	end))
	table.insert(v.conns, model:GetAttributeChangedSignal("Flips"):Connect(function()
		local r = model.PrimaryPart
		if r then
			Sfx.at("Servo", r.Position)
		end
	end))
	table.insert(v.conns, model:GetAttributeChangedSignal("Protected"):Connect(function()
		setFade(v)
	end))
	table.insert(v.conns, model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") and model:GetAttribute("Protected") then
			d.LocalTransparencyModifier = 0.55
		end
	end))
end

local function remove(model: Instance)
	local v = views[model :: Model]
	if not v then
		return
	end
	views[model :: Model] = nil
	for _, c in v.conns do
		c:Disconnect()
	end
	v.gui:Destroy()
	v.highlight:Destroy()
	local hull = v.smoke.Parent
	if hull then
		hull:Destroy()
	end
	v.hitDisc:Destroy()
	v.rangeRing:Destroy()
	if v.bubble then
		v.bubble:Destroy()
	end
	if v.field then
		v.field:Destroy()
	end
	if v.net then
		v.net:Destroy()
	end
	if v.stars then
		v.stars:Destroy()
	end
end

local function shortestLerp(from: number, to: number, alpha: number): number
	local d = (to - from + math.pi) % (2 * math.pi) - math.pi
	return from + d * alpha
end

-- The resting C0 of a motor, remembered the first time it is seen.
local function baseOf(motor: Motor6D): CFrame
	local base = sawBase[motor]
	if not base then
		base = motor.C0
		sawBase[motor] = base
	end
	return base
end

-- Finds the parts this robot animates, once per body build.
local function scan(body: Instance): Rig
	local rig: Rig = { yaw = {}, mounts = {}, gun = nil, gunPart = nil, blink = {}, heat = {}, flameLoop = nil, sawLoop = nil }
	for _, d in body:GetDescendants() do
		if d:IsA("Motor6D") then
			if d.Name == "TurretMotor" then
				table.insert(rig.yaw, d)
			elseif d.Name == "SwivelMotor" then
				local sw = d.Part1
				local weapon = sw and sw:GetAttribute("Mount")
				local muzzle = sw and sw:FindFirstChild("Muzzle")
				table.insert(rig.mounts, {
					motor = d,
					weapon = if type(weapon) == "string" then weapon else nil,
					muzzle = if muzzle and muzzle:IsA("Attachment") then muzzle else nil,
					rel = 0,
					aimAngle = 0,
					aimUntil = 0,
					kick = 0,
				})
			elseif d.Name == "GunMotor" then
				rig.gun = d
				rig.gunPart = d.Part1
			end
		elseif d:IsA("BasePart") then
			if d:GetAttribute("Blink") then
				table.insert(rig.blink, d)
			end
			if d:GetAttribute("HeatGlow") then
				table.insert(rig.heat, d)
			end
		end
	end
	local nozzle = body:FindFirstChild("Nozzle")
	if nozzle and nozzle:IsA("BasePart") then
		rig.flameLoop = Sfx.loop("Flamethrower", nozzle)
	end
	local saw = body:FindFirstChild("Saw")
	if saw and saw:IsA("BasePart") then
		rig.sawLoop = Sfx.loop("SawLoop", saw)
	end
	return rig
end

-- A shot left this robot's gun: kick it back (D78). Called by Projectiles.
function Robots.kick(entityId: number)
	for model, v in views do
		if model:GetAttribute("EntityId") == entityId then
			v.kick = 1
			return
		end
	end
end

-- Hull-relative swivel angle (inside the arc) that points along world angle `angle`.
local function relAngle(root: BasePart, angle: number): number
	local look = root.CFrame:VectorToObjectSpace(Vector3.new(math.cos(angle), 0, math.sin(angle)))
	return math.clamp(math.atan2(-look.X, -look.Z), -SWIVEL, SWIVEL)
end

-- A mounted weapon fired along world angle `angle` (D82): its swivel snaps to face the
-- shot and kicks back. Returns where the shot leaves (the muzzle), if the robot is here.
function Robots.mountShot(entityId: number, weapon: string, angle: number): Vector3?
	for model, v in views do
		if model:GetAttribute("EntityId") ~= entityId then
			continue
		end
		local root = model.PrimaryPart
		local rig = v.rig
		if not root or not rig then
			return nil
		end
		for _, m in rig.mounts do
			if m.weapon == weapon then
				m.aimAngle, m.aimUntil, m.kick = angle, os.clock() + 0.7, 1
				m.rel = relAngle(root, angle)
				if not m.muzzle then
					return nil
				end
				local swivel = root.CFrame * baseOf(m.motor) * CFrame.Angles(0, m.rel, 0)
				return (swivel * CFrame.new(m.muzzle.Position)).Position
			end
		end
		return nil
	end
	return nil
end

-- Animators (D94) ---------------------------------------------------------------
-- Each robot feature animates itself from one frame's facts. RobotMotion holds the
-- timing curves (tested in Lune); these apply them to parts. Order matters where two
-- share state: the saw and the Battle Axe both turn v.spin.

type AnimFrame = {
	v: View,
	model: Model,
	root: BasePart,
	body: Instance?,
	rig: Rig?,
	attacking: boolean,
	scale: number,
	lift: number,
	dt: number,
	me: Model?,
	myRoot: BasePart?,
}

local MOTION = PRES.motion

-- A cosmetic part in the effects folder: anchored, no collision, no shadow.
local function ghostPart(shape: Enum.PartType, material: Enum.Material, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Shape = shape
	p.Material = material
	p.Color = color
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- An effect part that exists only while `on`: made by `make`, destroyed after.
local function marker(v: View, key: string, on: boolean, make: () -> Part): Part?
	local p = (v :: any)[key] :: Part?
	if on and not p then
		local made = make()
		made.Parent = fxFolder
		;(v :: any)[key] = made
		return made
	elseif not on and p then
		p:Destroy()
		;(v :: any)[key] = nil
		return nil
	end
	return p
end

-- With up to 20 robots, an enemy's range ring only shows once you are near its edge,
-- so the ground never fills up with circles.
local function rangeRing(f: AnimFrame)
	local range = f.model:GetAttribute("AttackRange") or 0
	if f.model == f.me then
		f.v.rangeRing.Visible = range > 0
	elseif f.myRoot then
		local d = (f.root.Position - (f.myRoot :: BasePart).Position).Magnitude
		f.v.rangeRing.Visible = range > 0 and d < range + RING_SHOW_MARGIN
	else
		f.v.rangeRing.Visible = false
	end
end

-- Aim: your own follows your aim instantly; others ease toward the 10 Hz angles the
-- server rebroadcasts.
local function aim(f: AnimFrame)
	local v = f.v
	local userId = f.model:GetAttribute("UserId") or 0
	local target = if f.model == player.Character then ClientState.localAim else ClientState.aims[userId]
	if target then
		v.angle = if f.model == player.Character or not v.hasAim then target else shortestLerp(v.angle, target, math.min(1, f.dt * MOTION.aimEase))
		v.hasAim = true
	end
end

-- Third-person clarity (D72): your own name tag is hidden (the HUD shows it) and your
-- big weapons fade so they never block the view ahead.
local function viewFade(f: AnimFrame)
	local v = f.v
	local third = f.model == f.me and ClientState.camMode == "third"
	v.gui.Enabled = not third
	local body = f.body
	if body and v.fadeBody ~= body then
		v.fadeBody = body
		v.fadeParts = {}
		for _, d in body:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute("ViewFade") then
				table.insert(v.fadeParts, d)
			end
		end
	end
	for _, part in v.fadeParts do
		part.LocalTransparencyModifier = if third then 0.8 else 0
	end
end

-- Turret and mounted weapons (D78): they turn toward the aim, but only within a
-- 180-degree arc in front of the hull. The hull turns to cover the rest
-- (InputController), so the guns never point through it.
local function swivels(f: AnimFrame)
	local rig = f.rig
	if not rig then
		return
	end
	local rel = if f.v.hasAim then relAngle(f.root, f.v.angle) else 0
	local turn = CFrame.Angles(0, rel, 0)
	for _, m in rig.yaw do
		m.C0 = baseOf(m) * turn
	end
	-- Mounts (D82): face their last shot for a moment, then ease back to the aim.
	local clock = os.clock()
	for _, m in rig.mounts do
		local want = if clock < m.aimUntil then relAngle(f.root, m.aimAngle) else rel
		m.rel += (want - m.rel) * math.min(1, f.dt * MOTION.mountEase)
		m.kick = math.max(0, m.kick - f.dt / MOTION.mountKickTime)
		m.motor.C0 = baseOf(m.motor) * CFrame.Angles(0, m.rel, 0) * CFrame.new(0, 0, m.kick * m.kick * MOTION.mountKickDistance * f.scale)
	end
end

-- Recoil (D78): each shot slides the gun back and lifts the muzzle, then it settles.
-- The Scorcher's nozzle shudders under pressure instead.
local function recoil(f: AnimFrame)
	local rig, v = f.rig, f.v
	local gun = rig and rig.gun
	local gp = rig and rig.gunPart
	if not (gun and gp) then
		return
	end
	local settle = gp:GetAttribute("Settle") or 0.1
	v.kick = math.max(0, v.kick - f.dt / settle)
	local k = v.kick * v.kick
	local shudder = if f.attacking and f.model:GetAttribute("Chassis") == "scorcher" then (math.random() - 0.5) * 0.06 else 0
	gun.C0 = baseOf(gun) * CFrame.new(shudder, shudder, k * (gp:GetAttribute("Slide") or 0) * f.scale) * CFrame.Angles(k * (gp:GetAttribute("Climb") or 0), 0, 0)
end

-- Heat (the Scorcher's nozzle bands and exhaust tips): glows while firing, cools after.
local function heat(f: AnimFrame)
	local rig, v = f.rig, f.v
	if not rig or #rig.heat == 0 then
		return
	end
	v.heat = RobotMotion.heat(MOTION, v.heat, f.attacking, f.dt)
	local c = HEAT_COLD:Lerp(HEAT_HOT, v.heat)
	for _, part in rig.heat do
		part.Color = c
		part.Material = if v.heat > 0.15 or part.Name == "NozzleTip" or part.Name == "StackTip" then Enum.Material.Neon else Enum.Material.Metal
	end
end

-- Blinking lamps: antenna tips, beacons, the Bomber's fuse and core.
local function blink(f: AnimFrame)
	local rig = f.rig
	if not rig then
		return
	end
	local t = os.clock()
	for _, part in rig.blink do
		part.Transparency = if RobotMotion.blinkOn(t, part:GetAttribute("Blink") or 1) then 0 else 0.7
	end
end

-- The flamethrower roars while attacking.
local function flameSound(f: AnimFrame)
	local loop = f.rig and f.rig.flameLoop
	if loop and loop.Playing ~= f.attacking then
		loop.Playing = f.attacking
	end
end

-- Saw: spins up when attacking and winds down after (it never snaps); its scream follows.
local function saw(f: AnimFrame)
	local part = f.body and f.body:FindFirstChild("Saw")
	local motor = part and part:FindFirstChild("SawMotor") :: Motor6D?
	if not motor then
		return
	end
	local v = f.v
	v.sawRate = RobotMotion.sawRate(MOTION, v.sawRate, f.attacking, f.dt)
	v.spin += f.dt * v.sawRate
	motor.C0 = baseOf(motor) * CFrame.Angles(v.spin, 0, 0)
	local loop = f.rig and f.rig.sawLoop
	if loop then
		if not loop.Playing then
			loop.Playing = true
		end
		loop.Volume, loop.PlaybackSpeed = RobotMotion.sawSound(MOTION, v.sawRate)
	end
end

-- Battle Axe: a full 360 sweep round the robot per swing while attacking (D71).
local function axe(f: AnimFrame)
	local swing = f.body and f.body:FindFirstChild("Swing")
	local motor = swing and swing:FindFirstChild("SwingMotor") :: Motor6D?
	if not (swing and motor) then
		return
	end
	if f.attacking then
		f.v.spin += f.dt * (swing:GetAttribute("SwingRate") or 1) * 2 * math.pi
	end
	motor.C0 = baseOf(motor) * CFrame.Angles(0, -f.v.spin, 0) -- clockwise seen from above: the blade's edge leads (D83)
end

-- Vertical Saw on the back: always spinning.
local function sideSaw(f: AnimFrame)
	local part = f.body and f.body:FindFirstChild("SideSaw")
	local motor = part and part:FindFirstChild("SideSawMotor") :: Motor6D?
	if not motor then
		return
	end
	f.v.sideSpin += f.dt * MOTION.sideSawSpin
	motor.C0 = baseOf(motor) * CFrame.Angles(f.v.sideSpin, 0, 0)
end

-- Sledgehammer (D80): each new smash (its counter attribute ticks up) replays the
-- RobotMotion smash curve; at rest it stands upright in front.
local function hammer(f: AnimFrame)
	for _, hubName in SMASH_HUBS do
		local hub = f.body and f.body:FindFirstChild(hubName)
		local motor = hub and hub:FindFirstChild(hubName .. "Motor") :: Motor6D?
		if not (hub and motor) then
			continue
		end
		local counter = hub:GetAttribute("SmashCounter") or ""
		local st = f.v.smash[hubName]
		if not st then
			st = { last = f.model:GetAttribute(counter) or 0, t = math.huge }
			f.v.smash[hubName] = st
		end
		local n = f.model:GetAttribute(counter) or 0
		if n ~= st.last then
			st.last, st.t = n, 0
		end
		st.t += f.dt
		motor.C0 = baseOf(motor) * CFrame.Angles(RobotMotion.smashAngle(MOTION, st.t), 0, 0)
	end
end

-- Shield Generator: the barrier fades as the front shield wears down.
local function guardShield(f: AnimFrame)
	local guard = f.body and f.body:FindFirstChild("GuardShield") :: BasePart?
	if guard then
		local g = f.model:GetAttribute("Guard") or 0
		guard.Transparency = if g > 0 then 0.15 + 0.6 * (1 - g) else 1
	end
end

-- Flamethrower (D88): the jet, its core, embers, smoke and glow all go together; the
-- pilot flame hides inside the jet; the light flickers.
local function flame(f: AnimFrame)
	local nozzle = f.body and f.body:FindFirstChild("Nozzle")
	local jet = nozzle and nozzle:FindFirstChild("Flame") :: ParticleEmitter?
	if not (jet and nozzle) then
		return
	end
	if jet.Enabled ~= f.attacking then
		for _, name in FLAME_PARTS do
			local fx = nozzle:FindFirstChild(name)
			if fx then
				(fx :: any).Enabled = f.attacking
			end
		end
		local pilot = nozzle:FindFirstChild("PilotLight") :: ParticleEmitter?
		if pilot then
			pilot.Enabled = not f.attacking
		end
	end
	local glow = nozzle:FindFirstChild("FlameLight") :: PointLight?
	if glow and f.attacking then
		glow.Brightness = 2.4 + math.random() * 1.4 -- flicker
	end
end

-- Shield Pulse: a force-field bubble round the robot.
local function shieldBubble(f: AnimFrame)
	local b = marker(f.v, "bubble", f.model:GetAttribute("Shield") == true, function()
		return ghostPart(Enum.PartType.Ball, Enum.Material.ForceField, Color3.fromRGB(140, 220, 255), 0)
	end)
	if b then
		b.Size = Vector3.one * 9 * f.scale
		b.CFrame = CFrame.new(f.root.Position + Vector3.new(0, f.lift, 0))
	end
end

-- Bomber net: a brown mesh over a netted robot (D70).
local function net(f: AnimFrame)
	local n = marker(f.v, "net", f.model:GetAttribute("Netted") == true, function()
		return ghostPart(Enum.PartType.Ball, Enum.Material.Fabric, Color3.fromRGB(150, 120, 80), 0.55)
	end)
	if n then
		n.Size = Vector3.one * 7 * f.scale
		n.CFrame = CFrame.new(f.root.Position + Vector3.new(0, f.lift, 0))
	end
end

-- Flipped (D72): a spinning yellow ring over the stunned robot.
local function stunRing(f: AnimFrame)
	local st = marker(f.v, "stars", f.model:GetAttribute("Flipped") == true, function()
		return ghostPart(Enum.PartType.Cylinder, Enum.Material.Neon, Color3.fromRGB(255, 220, 60), 0.3)
	end)
	if st then
		st.Size = Vector3.new(0.2, 3.5 * f.scale, 3.5 * f.scale)
		st.CFrame = CFrame.new(f.root.Position + Vector3.new(0, 4 * f.scale + f.lift, 0)) * CFrame.Angles(0, os.clock() * 6, math.rad(90))
	end
end

-- Flipper plate: kicks up on each flip, then settles.
local function flipper(f: AnimFrame)
	local hub = f.body and f.body:FindFirstChild("FlipperHub")
	local motor = hub and hub:FindFirstChild("FlipperHubMotor") :: Motor6D?
	if not motor then
		return
	end
	local v = f.v
	local flips = f.model:GetAttribute("Flips") or 0
	if flips ~= v.lastFlips then
		v.lastFlips, v.flipT = flips, 0
	end
	v.flipT += f.dt
	motor.C0 = baseOf(motor) * CFrame.Angles(RobotMotion.flipAngle(MOTION, v.flipT), 0, 0)
end

-- Null Field (D68, D82): a huge force-field dome over the robot, as big as the field
-- (it grows with the skill's rank). It swells open, then holds.
local function nullField(f: AnimFrame)
	local v = f.v
	local fieldR = f.model:GetAttribute("Field")
	local on = type(fieldR) == "number" and fieldR > 0
	local dome = marker(v, "field", on, function()
		local d = ghostPart(Enum.PartType.Ball, Enum.Material.ForceField, Color3.fromRGB(170, 110, 255), 0)
		d.Size = Vector3.one
		local edge = Instance.new("CylinderHandleAdornment")
		edge.Name = "Edge"
		edge.Adornee = d
		edge.Height = 0.15
		edge.CFrame = CFrame.new(0, 0.1, 0) * CFrame.Angles(math.rad(90), 0, 0)
		edge.Color3 = Color3.fromRGB(200, 150, 255)
		edge.Transparency = 0.25
		edge.Parent = d
		v.fieldT = 0
		return d
	end)
	if dome and type(fieldR) == "number" then
		v.fieldT += f.dt
		local r = math.max(0.5, fieldR * RobotMotion.fieldOpen(MOTION, v.fieldT))
		dome.Size = Vector3.one * r * 2
		dome.CFrame = CFrame.new(f.root.Position.X, 0, f.root.Position.Z) -- centred on the ground: a dome
		local edge = dome:FindFirstChild("Edge") :: CylinderHandleAdornment?
		if edge then -- a bright ring where the dome meets the ground
			edge.Radius = r
			edge.InnerRadius = math.max(0, r - 0.5)
		end
	end
end

-- Every frame, in this order.
local ANIMATORS: { (f: AnimFrame) -> () } = {
	rangeRing,
	aim,
	viewFade,
	swivels,
	recoil,
	heat,
	blink,
	flameSound,
	saw,
	axe,
	sideSaw,
	hammer,
	guardShield,
	flame,
	shieldBubble,
	net,
	stunRing,
	flipper,
	nullField,
}

function Robots.init(folder: Folder)
	fxFolder = folder
	ClientState.actions.kick = Robots.kick
	ClientState.actions.mountShot = Robots.mountShot
	for _, m in CollectionService:GetTagged("Robot") do
		task.spawn(add, m)
	end
	CollectionService:GetInstanceAddedSignal("Robot"):Connect(add)
	CollectionService:GetInstanceRemovedSignal("Robot"):Connect(remove)
	-- A boss is tagged after it becomes a robot: refresh so its tag drops the bars.
	CollectionService:GetInstanceAddedSignal("Boss"):Connect(function(m)
		local v = views[m :: Model]
		if v then
			refresh(v)
		end
	end)

	-- One frame table, refilled for each robot (no garbage per robot per frame).
	local frame = {} :: AnimFrame
	RunService.RenderStepped:Connect(function(dt)
		local me = player.Character
		local myRoot = me and me.PrimaryPart
		for model, v in views do
			local root = model.PrimaryPart
			if not root or not model.Parent then
				continue
			end
			local scale = model:GetAttribute("VisualScale") or 1
			local body = model:FindFirstChild("Body")
			if body and v.rigBody ~= body then
				v.rigBody = body
				v.rig = scan(body)
			end
			frame.v, frame.model, frame.root, frame.body, frame.rig = v, model, root, body, v.rig
			frame.attacking = model:GetAttribute("Firing") == true
			frame.scale, frame.lift, frame.dt = scale, (scale - 1) * Config.Robot.BodyLift, dt
			frame.me, frame.myRoot = me, myRoot
			for _, animate in ANIMATORS do
				animate(frame)
			end
		end
	end)
end

return Robots
