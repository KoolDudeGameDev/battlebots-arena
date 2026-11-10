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

local Robots = {}

local player = Players.LocalPlayer
local fxFolder: Folder
local RING_SHOW_MARGIN = 25 -- studs outside an enemy's range where its ring appears

type View = {
	model: Model,
	gui: BillboardGui,
	levelLabel: TextLabel,
	hpBack: Frame,
	hpFill: Frame,
	armorBack: Frame,
	armorFill: Frame,
	highlight: Highlight,
	hitDisc: CylinderHandleAdornment,
	rangeRing: CylinderHandleAdornment,
	bubble: Part?,
	field: Part?, -- Null Field disc
	net: Part?, -- Bomber net
	fadeBody: Instance?, -- the Body the fade list was built for
	fadeParts: { BasePart },
	stars: Part?, -- Flipper stun marker
	lastFlips: number,
	flipT: number,
	sideSpin: number,
	smash: { [string]: { last: number, t: number } }, -- per hammer hub
	angle: number,
	spin: number,
	lastHp: number,
	conns: { RBXScriptConnection },
}

local views: { [Model]: View } = {}
local sawBase: { [Motor6D]: CFrame } = {} -- each saw's resting C0
local SMASH_HUBS = { "SmashHub" } -- the Sledgehammer main weapon
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
	v.hpBack.Visible = hp < maxHp or hasArmor
	v.armorBack.Visible = hasArmor
	v.armorFill.Size = UDim2.fromScale(math.clamp(armor / math.max(maxArmor, armor, 1), 0, 1), 1)

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

local function flash(v: View)
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
	gui.Size = UDim2.fromOffset(170, 58)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = root
	gui.ResetOnSpawn = false
	local name = (model:GetAttribute("DisplayName") or model.Name) :: string
	label(gui, name, 14, UDim2.fromOffset(0, 0), 16)
	local levelLabel = label(gui, "Lv 0", 14, UDim2.fromOffset(0, 16), 16)
	local hpBack = Instance.new("Frame")
	hpBack.Size = UDim2.fromOffset(130, 11)
	hpBack.Position = UDim2.new(0.5, -65, 0, 35)
	hpBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hpBack.BorderSizePixel = 0
	hpBack.Parent = gui
	local hpFill = Instance.new("Frame")
	hpFill.BackgroundColor3 = if model == player.Character then Color3.fromRGB(90, 220, 110) else Color3.fromRGB(235, 80, 70)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBack
	local armorBack = Instance.new("Frame")
	armorBack.Size = UDim2.fromOffset(130, 6)
	armorBack.Position = UDim2.new(0.5, -65, 0, 48)
	armorBack.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	armorBack.BorderSizePixel = 0
	armorBack.Visible = false
	armorBack.Parent = gui
	local armorFill = Instance.new("Frame")
	armorFill.BackgroundColor3 = Color3.fromRGB(110, 170, 255)
	armorFill.BorderSizePixel = 0
	armorFill.Parent = armorBack
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

	local v: View = {
		model = model,
		gui = gui,
		levelLabel = levelLabel,
		hpBack = hpBack,
		hpFill = hpFill,
		armorBack = armorBack,
		armorFill = armorFill,
		highlight = highlight,
		hitDisc = hitDisc,
		rangeRing = rangeRing,
		bubble = nil,
		field = nil,
		net = nil,
		fadeBody = nil,
		fadeParts = {},
		stars = nil,
		lastFlips = 0,
		flipT = math.huge,
		sideSpin = 0,
		smash = {},
		angle = 0,
		spin = 0,
		lastHp = model:GetAttribute("HP") or 0,
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
	for _, attr in { "MaxHP", "Armor", "MaxArmor", "HitRadius", "AttackRange" } do
		table.insert(v.conns, model:GetAttributeChangedSignal(attr):Connect(function()
			refresh(v)
		end))
	end
	table.insert(v.conns, model:GetAttributeChangedSignal("Level"):Connect(function()
		refresh(v)
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

function Robots.init(folder: Folder)
	fxFolder = folder
	for _, m in CollectionService:GetTagged("Robot") do
		task.spawn(add, m)
	end
	CollectionService:GetInstanceAddedSignal("Robot"):Connect(add)
	CollectionService:GetInstanceRemovedSignal("Robot"):Connect(remove)

	RunService.RenderStepped:Connect(function(dt)
		local me = player.Character
		local myRoot = me and me.PrimaryPart
		for model, v in views do
			local root = model.PrimaryPart
			if not root or not model.Parent then
				continue
			end
			local scale = model:GetAttribute("VisualScale") or 1
			local lift = (scale - 1) * Config.Robot.BodyLift

			-- With up to 20 robots, an enemy's range ring only shows once you are
			-- near its edge, so the ground never fills up with circles.
			local range = model:GetAttribute("AttackRange") or 0
			if model == me then
				v.rangeRing.Visible = range > 0
			elseif myRoot then
				local d = (root.Position - myRoot.Position).Magnitude
				v.rangeRing.Visible = range > 0 and d < range + RING_SHOW_MARGIN
			else
				v.rangeRing.Visible = false
			end

			-- Turret: your own follows your aim instantly; others ease toward the
			-- 10 Hz angles the server rebroadcasts.
			local userId = model:GetAttribute("UserId") or 0
			local target = if model == player.Character then ClientState.localAim else ClientState.aims[userId]
			if target then
				v.angle = if model == player.Character then target else shortestLerp(v.angle, target, math.min(1, dt * 15))
			end
			local body = model:FindFirstChild("Body")
			-- Third-person clarity (D72): your own name tag is hidden (the HUD shows it)
			-- and your big weapons fade so they never block the view ahead.
			local third = model == me and ClientState.camMode == "third"
			v.gui.Enabled = not third
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
			local turret = body and body:FindFirstChild("Turret")
			local motor = turret and turret:FindFirstChild("TurretMotor") :: Motor6D?
			if motor then
				local pos = root.Position + Vector3.new(0, Config.Robot.TurretHeight * scale + lift, 0)
				local dir = Vector3.new(math.cos(v.angle), 0, math.sin(v.angle))
				motor.C0 = root.CFrame:ToObjectSpace(CFrame.lookAt(pos, pos + dir))
			end

			-- Attack visuals: the Brawler's saw spins and the Scorcher's flame jets
			-- while the robot is attacking.
			local attacking = model:GetAttribute("Firing") == true
			local saw = body and body:FindFirstChild("Saw")
			local sawMotor = saw and saw:FindFirstChild("SawMotor") :: Motor6D?
			if sawMotor then
				local base = sawBase[sawMotor]
				if not base then
					base = sawMotor.C0
					sawBase[sawMotor] = base
				end
				v.spin += dt * (if attacking then 30 else 2)
				sawMotor.C0 = base * CFrame.Angles(v.spin, 0, 0)
			end
			-- Battle Axe: a full 360 sweep round the robot per swing while attacking (D71).
			local swing = body and body:FindFirstChild("Swing")
			local swingMotor = swing and swing:FindFirstChild("SwingMotor") :: Motor6D?
			if swing and swingMotor then
				local base = sawBase[swingMotor]
				if not base then
					base = swingMotor.C0
					sawBase[swingMotor] = base
				end
				if attacking then
					v.spin += dt * (swing:GetAttribute("SwingRate") or 1) * 2 * math.pi
				end
				swingMotor.C0 = base * CFrame.Angles(0, v.spin, 0)
			end
			-- Vertical Saw on the back: always spinning.
			local sideSaw = body and body:FindFirstChild("SideSaw")
			local sideMotor = sideSaw and sideSaw:FindFirstChild("SideSawMotor") :: Motor6D?
			if sideMotor then
				local base = sawBase[sideMotor]
				if not base then
					base = sideMotor.C0
					sawBase[sideMotor] = base
				end
				v.sideSpin += dt * 25
				sideMotor.C0 = base * CFrame.Angles(v.sideSpin, 0, 0)
			end
			-- Sledgehammer (D71): raised behind at rest (180 degrees);
			-- each smash swings over the top onto the ground in front in 0.2 s (the
			-- server's windup), holds, then lifts back up for the next one.
			for _, hubName in SMASH_HUBS do
				local hub = body and body:FindFirstChild(hubName)
				local hubMotor = hub and hub:FindFirstChild(hubName .. "Motor") :: Motor6D?
				if hub and hubMotor then
					local base = sawBase[hubMotor]
					if not base then
						base = hubMotor.C0
						sawBase[hubMotor] = base
					end
					local counter = hub:GetAttribute("SmashCounter") or ""
					local st = v.smash[hubName]
					if not st then
						st = { last = model:GetAttribute(counter) or 0, t = math.huge }
						v.smash[hubName] = st
					end
					local n = model:GetAttribute(counter) or 0
					if n ~= st.last then
						st.last, st.t = n, 0
					end
					st.t += dt
					local t = st.t
					local a = if t < 0.2 then math.pi * (1 - (t / 0.2) ^ 2) elseif t < 0.35 then 0 elseif t < 0.85 then math.pi * ((t - 0.35) / 0.5) else math.pi
					hubMotor.C0 = base * CFrame.Angles(a, 0, 0)
				end
			end
			local guard = body and body:FindFirstChild("GuardShield") :: BasePart?
			if guard then
				local g = model:GetAttribute("Guard") or 0
				guard.Transparency = if g > 0 then 0.15 + 0.6 * (1 - g) else 1
			end
			local nozzle = body and body:FindFirstChild("Nozzle")
			local flame = nozzle and nozzle:FindFirstChild("Flame") :: ParticleEmitter?
			if flame and flame.Enabled ~= attacking then
				flame.Enabled = attacking
			end

			-- Shield bubble
			local shielded = model:GetAttribute("Shield") == true
			if shielded and not v.bubble then
				local b = Instance.new("Part")
				b.Shape = Enum.PartType.Ball
				b.Material = Enum.Material.ForceField
				b.Color = Color3.fromRGB(140, 220, 255)
				b.Anchored = true
				b.CanCollide = false
				b.CanQuery = false
				b.CanTouch = false
				b.CastShadow = false
				b.Parent = fxFolder
				v.bubble = b
			elseif not shielded and v.bubble then
				v.bubble:Destroy()
				v.bubble = nil
			end
			if v.bubble then
				v.bubble.Size = Vector3.one * 9 * scale
				v.bubble.CFrame = CFrame.new(root.Position + Vector3.new(0, lift, 0))
			end

			-- Bomber net: a brown mesh over a netted robot (D70).
			local netted = model:GetAttribute("Netted") == true
			if netted and not v.net then
				local n = Instance.new("Part")
				n.Shape = Enum.PartType.Ball
				n.Material = Enum.Material.Fabric
				n.Color = Color3.fromRGB(150, 120, 80)
				n.Transparency = 0.55
				n.Anchored = true
				n.CanCollide = false
				n.CanQuery = false
				n.CanTouch = false
				n.CastShadow = false
				n.Parent = fxFolder
				v.net = n
			elseif not netted and v.net then
				v.net:Destroy()
				v.net = nil
			end
			if v.net then
				v.net.Size = Vector3.one * 7 * scale
				v.net.CFrame = CFrame.new(root.Position + Vector3.new(0, lift, 0))
			end

			-- Flipped (D72): a spinning yellow ring over the stunned robot.
			local flipped = model:GetAttribute("Flipped") == true
			if flipped and not v.stars then
				local st = Instance.new("Part")
				st.Shape = Enum.PartType.Cylinder
				st.Material = Enum.Material.Neon
				st.Color = Color3.fromRGB(255, 220, 60)
				st.Transparency = 0.3
				st.Anchored = true
				st.CanCollide = false
				st.CanQuery = false
				st.CanTouch = false
				st.CastShadow = false
				st.Parent = fxFolder
				v.stars = st
			elseif not flipped and v.stars then
				v.stars:Destroy()
				v.stars = nil
			end
			if v.stars then
				v.stars.Size = Vector3.new(0.2, 3.5 * scale, 3.5 * scale)
				v.stars.CFrame = CFrame.new(root.Position + Vector3.new(0, 4 * scale + lift, 0)) * CFrame.Angles(0, os.clock() * 6, math.rad(90))
			end
			-- Flipper plate kicks up on each flip, then settles.
			local flipHub = body and body:FindFirstChild("FlipperHub")
			local flipMotor = flipHub and flipHub:FindFirstChild("FlipperHubMotor") :: Motor6D?
			if flipMotor then
				local base = sawBase[flipMotor]
				if not base then
					base = flipMotor.C0
					sawBase[flipMotor] = base
				end
				local flips = model:GetAttribute("Flips") or 0
				if flips ~= v.lastFlips then
					v.lastFlips, v.flipT = flips, 0
				end
				v.flipT += dt
				local up = if v.flipT < 0.1 then v.flipT / 0.1 elseif v.flipT < 0.5 then 1 - (v.flipT - 0.1) / 0.4 else 0
				flipMotor.C0 = base * CFrame.Angles(math.rad(70) * up, 0, 0)
			end

			-- Null Field: a big purple disc on the ground while it is up (D68).
			local fieldR = model:GetAttribute("Field")
			local fieldOn = type(fieldR) == "number" and fieldR > 0
			if fieldOn and not v.field then
				local d = Instance.new("Part")
				d.Shape = Enum.PartType.Cylinder
				d.Material = Enum.Material.ForceField
				d.Color = Color3.fromRGB(170, 110, 255)
				d.Anchored = true
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
				d.CastShadow = false
				d.Parent = fxFolder
				v.field = d
			elseif not fieldOn and v.field then
				v.field:Destroy()
				v.field = nil
			end
			if v.field and type(fieldR) == "number" then
				v.field.Size = Vector3.new(3, fieldR * 2, fieldR * 2)
				v.field.CFrame = CFrame.new(root.Position.X, 0.6, root.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
			end
		end
	end)
end

return Robots
