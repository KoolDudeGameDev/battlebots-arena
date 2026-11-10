-- Impact and explosion visuals (D75): sparks on robots, stone chips and dust on
-- walls and rocks, wood chips, falling leaves and a swaying canopy on trees, and
-- for explosions and hammer slams a flash, fire, smoke, flying debris, a
-- shockwave, a scorch or crack mark and camera shake. Client-only: every effect
-- comes from events the client already gets, so nothing new crosses the network.
-- Particles come from a few shared emitters (moved, then :Emit) and debris parts
-- are pooled, so heavy fights stay cheap.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.ClientState)

local Vfx = {}

local TEX = {
	spark = "rbxasset://textures/particles/sparkles_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
}
local MAX_DEBRIS = 90
local VIEW_RANGE = 180 -- impacts further than this from you are skipped
local GRAVITY = 70

local folder: Folder
local holder: Part
local emitters: { [string]: { att: Attachment, pe: ParticleEmitter } } = {}

local function seq(a: number, b: number): NumberSequence
	return NumberSequence.new(a, b)
end

local function makeEmitter(name: string, props: { [string]: any })
	local att = Instance.new("Attachment")
	att.Name = name
	att.Parent = holder
	local pe = Instance.new("ParticleEmitter")
	pe.Enabled = false
	pe.LockedToPart = false
	for k, v in props do
		(pe :: any)[k] = v
	end
	pe.Parent = att
	emitters[name] = { att = att, pe = pe }
end

local function emit(name: string, pos: Vector3, count: number)
	local e = emitters[name]
	if e and count > 0 then
		e.att.WorldPosition = pos
		e.pe:Emit(math.floor(count + 0.5))
	end
end

local function near(pos: Vector3): (boolean, number)
	local cam = Workspace.CurrentCamera
	local character = Players.LocalPlayer.Character
	local root = character and character.PrimaryPart
	local from = if root then root.Position elseif cam then cam.Focus.Position else pos
	local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude
	return d <= VIEW_RANGE, d
end

local function shake(d: number, strength: number, range: number)
	if d < range and ClientState.actions.shake then
		ClientState.actions.shake(strength * (1 - d / range))
	end
end

-- Debris: small chunks thrown up that bounce once and fade -------------------------

type Chunk = { part: Part, vel: Vector3, spin: Vector3, rot: CFrame, life: number, landed: boolean }
local chunks: { Chunk } = {}
local chunkPool: { Part } = {}

local function chunkPart(): Part
	local p = table.remove(chunkPool)
	if p then
		return p
	end
	p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = folder
	return p
end

local function debris(pos: Vector3, count: number, color: Color3, material: Enum.Material, size: number, power: number)
	local rng = Random.new()
	for _ = 1, count do
		if #chunks >= MAX_DEBRIS then
			return
		end
		local p = chunkPart()
		local s = size * rng:NextNumber(0.5, 1.2)
		p.Size = Vector3.new(s, s * rng:NextNumber(0.4, 1), s * rng:NextNumber(0.6, 1.2))
		p.Color = color:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.25))
		p.Material = material
		p.Transparency = 0
		local ang = rng:NextNumber(0, math.pi * 2)
		local out = rng:NextNumber(0.3, 1) * power
		local vel = Vector3.new(math.cos(ang) * out, rng:NextNumber(0.6, 1.2) * power, math.sin(ang) * out)
		local start = pos + Vector3.new(0, 0.3, 0)
		local rot = CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))
		p.CFrame = CFrame.new(start) * rot
		table.insert(chunks, { part = p, vel = vel, spin = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12)), rot = rot, life = 0, landed = false })
	end
end

local function stepChunks(dt: number)
	for i = #chunks, 1, -1 do
		local c = chunks[i]
		c.life += dt
		local pos = c.part.Position
		if not c.landed then
			c.vel -= Vector3.new(0, GRAVITY * dt, 0)
			pos += c.vel * dt
			c.rot *= CFrame.Angles(c.spin.X * dt, c.spin.Y * dt, c.spin.Z * dt)
			if pos.Y <= c.part.Size.Y / 2 then
				pos = Vector3.new(pos.X, c.part.Size.Y / 2, pos.Z)
				if c.vel.Y < -12 then
					c.vel = Vector3.new(c.vel.X * 0.4, -c.vel.Y * 0.3, c.vel.Z * 0.4) -- one small bounce
				else
					c.landed = true
				end
			end
			c.part.CFrame = CFrame.new(pos) * c.rot
		end
		if c.life > 1.6 then
			c.part.Transparency = math.clamp((c.life - 1.6) / 0.6, 0, 1)
		end
		if c.life > 2.2 then
			c.part.CFrame = CFrame.new(0, -500, 0)
			table.insert(chunkPool, c.part)
			table.remove(chunks, i)
		end
	end
end

-- Flat ground pieces: shockwave rings, scorch and crack marks -----------------------

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local function disc(x: number, z: number, diameter: number, color: Color3, material: Enum.Material, transparency: number, y: number): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(0.12, diameter, diameter)
	p.CFrame = CFrame.new(x, y, z) * UPRIGHT
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Parent = folder
	return p
end

local function shockwave(x: number, z: number, radius: number, color: Color3)
	local p = disc(x, z, 1, color, Enum.Material.Neon, 0.35, 0.35)
	local t = TweenService:Create(p, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.12, radius * 2, radius * 2), Transparency = 1 }) -- ends exactly at the hit edge (D80)
	t.Completed:Once(function()
		p:Destroy()
	end)
	t:Play()
end

-- A thin ring on the ground at the exact damage radius, held for a moment so the
-- blast's reach is readable (D80).
local function edgeRing(x: number, z: number, radius: number, color: Color3)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(x, 0.4, z)
	anchor.Parent = folder
	local ring = Instance.new("CylinderHandleAdornment")
	ring.Adornee = anchor
	ring.Radius = radius
	ring.InnerRadius = math.max(0, radius - 0.6)
	ring.Height = 0.08
	ring.CFrame = CFrame.Angles(math.rad(90), 0, 0)
	ring.Color3 = color
	ring.Transparency = 0.2
	ring.Parent = anchor
	local t = TweenService:Create(ring, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 })
	t.Completed:Once(function()
		anchor:Destroy()
	end)
	t:Play()
end

local function mark(x: number, z: number, radius: number, color: Color3, seconds: number)
	local p = disc(x, z, radius * 1.4, color, Enum.Material.SmoothPlastic, 0.3, 0.07)
	local t = TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Transparency = 1 })
	t.Completed:Once(function()
		p:Destroy()
	end)
	t:Play()
end

local function flash(pos: Vector3, radius: number, color: Color3)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = Vector3.one * radius * 0.5
	p.CFrame = CFrame.new(pos)
	p.Transparency = 0.05
	p.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = radius * 3
	light.Brightness = 3
	light.Parent = p
	local t = TweenService:Create(p, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * radius * 1.3, Transparency = 1 })
	TweenService:Create(light, TweenInfo.new(0.2), { Brightness = 0 }):Play()
	t.Completed:Once(function()
		p:Destroy()
	end)
	t:Play()
end

-- Trees: the canopy sways and drops leaves when hit ------------------------------------

type Canopy = { part: BasePart, base: CFrame, t: number, dir: Vector3 }
local canopies: { Canopy } = {}
local swaying: { [Canopy]: boolean } = {}

local function collectCanopies()
	local arena = Workspace:FindFirstChild("Arena")
	if not arena then
		return
	end
	for _, d in arena:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Canopy" then
			table.insert(canopies, { part = d, base = d.CFrame, t = math.huge, dir = Vector3.xAxis })
		end
	end
end

local function swayTreeAt(x: number, z: number, dx: number, dz: number)
	for _, c in canopies do
		local p = c.base.Position
		if (p.X - x) ^ 2 + (p.Z - z) ^ 2 < 81 then
			c.t = 0
			c.dir = Vector3.new(dx, 0, dz)
			swaying[c] = true
			emit("leaves", p + Vector3.new(0, -1, 0), 4)
		end
	end
end

local function stepCanopies(dt: number)
	for c in swaying do
		c.t += dt
		if c.t > 0.8 then
			c.part.CFrame = c.base
			swaying[c] = nil
		else
			local push = math.sin(c.t * 22) * (1 - c.t / 0.8) * 0.45
			c.part.CFrame = c.base + c.dir * push
		end
	end
end

-- Public effects ----------------------------------------------------------------------

local STONE = Color3.fromRGB(135, 135, 130)
local WOOD = Color3.fromRGB(110, 75, 45)
local METAL = Color3.fromRGB(70, 74, 82)
local DIRT = Color3.fromRGB(120, 95, 65)

-- A shot hitting something at (x, z). style: "robot", "laser", "stone", "wood".
-- (dx, dz) is the shot's direction, so chips fly back toward the shooter.
function Vfx.impact(x: number, z: number, style: string, dx: number?, dz: number?)
	local pos = Vector3.new(x, 3, z)
	if not near(pos) then
		return
	end
	if style == "robot" then
		emit("sparks", pos, 7)
	elseif style == "laser" then
		emit("laserSparks", pos, 4)
	elseif style == "wood" then
		emit("dust", pos, 1)
		debris(pos, 2, WOOD, Enum.Material.Wood, 0.35, 10)
		swayTreeAt(x, z, dx or 0, dz or 0)
	else -- stone: walls, rocks, pillars, the boundary wall
		emit("dust", pos, 2)
		emit("chips", pos, 3)
		debris(pos, 2, STONE, Enum.Material.Slate, 0.35, 10)
	end
end

-- Rockets, the Bomber's bomb and robot deaths. big = a robot blowing up.
function Vfx.explosion(x: number, z: number, radius: number, big: boolean?)
	local pos = Vector3.new(x, 2, z)
	local ok, d = near(pos)
	if not ok then
		return
	end
	local k = math.clamp(radius / 9, 0.6, 2.5)
	flash(pos, radius, Color3.fromRGB(255, 190, 90))
	emit("fire", pos, 10 * k)
	emit("smoke", pos + Vector3.new(0, 1, 0), 6 * k)
	emit("sparks", pos, 12 * k)
	shockwave(x, z, radius, Color3.fromRGB(255, 170, 90))
	edgeRing(x, z, radius, Color3.fromRGB(255, 150, 60))
	mark(x, z, radius * 0.7, Color3.fromRGB(25, 22, 20), 6)
	debris(pos, math.floor(5 * k), if big then METAL else DIRT, if big then Enum.Material.Metal else Enum.Material.Ground, 0.6, 22)
	shake(d, if big then 0.5 else 0.35, 60)
end

-- Hammer slams (Sledgehammer, Forge Titan, Edge Hammers) and the Flipper's kick.
function Vfx.slam(x: number, z: number, radius: number)
	local pos = Vector3.new(x, 0.5, z)
	local ok, d = near(pos)
	if not ok then
		return
	end
	local k = math.clamp(radius / 6, 0.6, 2.5)
	shockwave(x, z, radius, Color3.fromRGB(230, 210, 170))
	-- A ring of dust kicked out at the edge, plus a puff in the middle.
	for i = 0, 7 do
		local a = i * math.pi / 4
		emit("dust", Vector3.new(x + math.cos(a) * radius * 0.7, 0.8, z + math.sin(a) * radius * 0.7), 1.5 * k)
	end
	emit("dust", pos, 3 * k)
	mark(x, z, radius * 0.6, Color3.fromRGB(70, 60, 50), 3)
	debris(pos, math.floor(6 * k), STONE, Enum.Material.Slate, 0.55, 26)
	shake(d, 0.4, 50)
end

-- Fire bursts (the Inferno Giant's breath): flame and a little smoke, no scorch.
function Vfx.fire(x: number, z: number, radius: number)
	local pos = Vector3.new(x, 2, z)
	if not near(pos) then
		return
	end
	emit("fire", pos, math.clamp(radius, 3, 10))
	emit("smoke", pos + Vector3.new(0, 2, 0), 2)
end

-- A small puff of a given dust colour (crates breaking, nets, Earth Walls).
function Vfx.puff(x: number, z: number, radius: number, material: string)
	local pos = Vector3.new(x, 1.5, z)
	if not near(pos) then
		return
	end
	emit("dust", pos, math.clamp(radius, 2, 6))
	if material == "wood" then
		debris(pos, 6, WOOD, Enum.Material.WoodPlanks, 0.6, 18)
	elseif material == "metal" then
		debris(pos, 6, METAL, Enum.Material.CorrodedMetal, 0.6, 18)
		emit("sparks", pos, 8)
	elseif material == "stone" then
		debris(pos, 6, STONE, Enum.Material.Slate, 0.7, 16)
	end
end

-- Robot sparks with no direction (deflects, traps, melee hits).
function Vfx.sparks(x: number, z: number, count: number)
	local pos = Vector3.new(x, 3, z)
	if near(pos) then
		emit("sparks", pos, count)
	end
end

function Vfx.init(fx: Folder)
	folder = fx
	holder = Instance.new("Part")
	holder.Name = "VfxEmitters"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.CFrame = CFrame.new(0, -100, 0)
	holder.Parent = fx

	makeEmitter("sparks", {
		Texture = TEX.spark,
		Color = ColorSequence.new(Color3.fromRGB(255, 250, 210), Color3.fromRGB(255, 150, 40)),
		LightEmission = 1,
		Size = seq(0.5, 0),
		Lifetime = NumberRange.new(0.15, 0.35),
		Speed = NumberRange.new(16, 30),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -40, 0),
		Drag = 3,
	})
	makeEmitter("laserSparks", {
		Texture = TEX.spark,
		Color = ColorSequence.new(Color3.fromRGB(255, 200, 200), Color3.fromRGB(255, 40, 60)),
		LightEmission = 1,
		Size = seq(0.6, 0),
		Lifetime = NumberRange.new(0.1, 0.25),
		Speed = NumberRange.new(10, 20),
		SpreadAngle = Vector2.new(180, 180),
	})
	makeEmitter("chips", {
		Texture = TEX.spark,
		Color = ColorSequence.new(Color3.fromRGB(230, 225, 210)),
		LightEmission = 0.4,
		Size = seq(0.35, 0),
		Lifetime = NumberRange.new(0.2, 0.4),
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -50, 0),
	})
	makeEmitter("dust", {
		Texture = TEX.smoke,
		Color = ColorSequence.new(Color3.fromRGB(190, 172, 145)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 5) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(4, 9),
		SpreadAngle = Vector2.new(180, 60),
		Drag = 3,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
	})
	makeEmitter("leaves", {
		Color = ColorSequence.new(Color3.fromRGB(90, 160, 70), Color3.fromRGB(60, 120, 50)),
		Size = seq(0.45, 0.35),
		Lifetime = NumberRange.new(1.2, 1.8),
		Speed = NumberRange.new(3, 7),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -7, 0),
		Drag = 1.5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-200, 200),
	})
	makeEmitter("fire", {
		Texture = TEX.fire,
		Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 80, 20)),
		LightEmission = 1,
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(0.4, 4.5), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.3, 0.55),
		Speed = NumberRange.new(10, 22),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 4,
		Rotation = NumberRange.new(0, 360),
	})
	makeEmitter("smoke", {
		Texture = TEX.smoke,
		Color = ColorSequence.new(Color3.fromRGB(70, 66, 62), Color3.fromRGB(110, 105, 100)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(1.2, 2),
		Speed = NumberRange.new(3, 7),
		SpreadAngle = Vector2.new(180, 60),
		Acceleration = Vector3.new(0, 4, 0),
		Drag = 2,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-30, 30),
	})

	task.defer(collectCanopies) -- the arena is built by the server; it has replicated by now or soon after
	task.delay(5, function()
		if #canopies == 0 then
			collectCanopies()
		end
	end)
	RunService.RenderStepped:Connect(function(dt)
		stepChunks(dt)
		stepCanopies(dt)
	end)
end

return Vfx
