-- Explosions, deflect sparks, Earth Wall dust, and floating damage numbers
-- for every hit (D43): yellow = you dealt it, red = you took it, blue = your
-- armor took it, BLOCK = it deflected.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Vfx = require(script.Parent.Vfx)
local Sfx = require(script.Parent.Sfx)

local Effects = {}

local folder: Folder

local COLORS = {
	explosion = Color3.fromRGB(255, 140, 50),
	death = Color3.fromRGB(255, 90, 60),
	crate = Color3.fromRGB(220, 180, 110),
	deflect = Color3.fromRGB(255, 245, 200),
	wall = Color3.fromRGB(150, 115, 80),
	slam = Color3.fromRGB(190, 165, 120), -- Sledgehammer ground smash, Flipper kick
	trap = Color3.fromRGB(220, 60, 50), -- a Spike Trap snapping shut
	net = Color3.fromRGB(170, 140, 90), -- a Bomber net landing
	warn = Color3.fromRGB(255, 50, 40), -- a boss attack about to land here
}

local NUMBER_COLORS = {
	dealt = Color3.fromRGB(255, 235, 110),
	taken = Color3.fromRGB(255, 85, 75),
	armor = Color3.fromRGB(110, 170, 255),
	block = Color3.fromRGB(240, 240, 240),
}
local MERGE_WINDOW = 0.15 -- hits on one target this close together share a number
local NUMBER_LIFE = 0.7

-- A boss warning (D74): a flat red circle on the ground where the hit will land.
local function warnCircle(x: number, z: number, radius: number)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	p.Material = Enum.Material.Neon
	p.Color = COLORS.warn
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(0.2, radius * 2, radius * 2)
	p.CFrame = CFrame.new(x, 0.25, z) * CFrame.Angles(0, 0, math.rad(90))
	p.Transparency = 0.6
	p.Parent = folder
	local tween = TweenService:Create(p, TweenInfo.new(0.8), { Transparency = 0.2 })
	tween.Completed:Once(function()
		p:Destroy()
	end)
	tween:Play()
end

-- Richer effects (D75) for the events that have them; the plain neon burst below
-- is the fallback for anything else.
local RICH: { [string]: (x: number, z: number, radius: number) -> () } = {
	explosion = function(x, z, r)
		Vfx.explosion(x, z, r)
	end,
	death = function(x, z, r)
		Vfx.explosion(x, z, r, true)
	end,
	slam = Vfx.slam,
	fire = Vfx.fire,
	crate = function(x, z, r)
		Vfx.puff(x, z, r, "metal")
	end,
	wall = function(x, z, r)
		Vfx.puff(x, z, r, "stone")
	end,
	net = function(x, z, r)
		Vfx.puff(x, z, r, "none")
	end,
	trap = function(x, z)
		Vfx.sparks(x, z, 10)
	end,
	deflect = function(x, z)
		Vfx.sparks(x, z, 5)
	end,
}

-- What each event sounds like (D78).
local SOUND_OF = {
	explosion = "Explosion",
	death = "BigExplosion",
	slam = "Slam",
	fire = "FireBurst",
	crate = "HeavyHit",
	wall = "Rubble",
	net = "NetLand",
	trap = "TrapSnap",
	deflect = "Deflect",
}

local function burst(kind: string, x: number, z: number, radius: number)
	local sound = SOUND_OF[kind]
	if sound then
		Sfx.at(sound, Vector3.new(x, 3, z))
	end
	if kind == "warn" then
		warnCircle(x, z, radius)
		return
	end
	local rich = RICH[kind]
	if rich then
		rich(x, z, radius)
		return
	end
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Material = Enum.Material.Neon
	p.Color = COLORS[kind] or COLORS.explosion
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.one
	p.Transparency = 0.2
	p.CFrame = CFrame.new(x, 2, z)
	p.Parent = folder
	local duration = if kind == "deflect" then 0.15 else 0.3
	local tween = TweenService:Create(p, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.one * radius * 2,
		Transparency = 1,
	})
	tween.Completed:Once(function()
		p:Destroy()
	end)
	tween:Play()
end

type Floating = { anchor: Part, label: TextLabel, amount: number, at: number }
local active: { [string]: Floating } = {}

local function show(targetId: number, x: number, z: number, amount: number, kind: string)
	local key = targetId .. ":" .. kind
	local now = os.clock()
	local f = active[key]
	if f and f.anchor.Parent and now - f.at < MERGE_WINDOW then
		f.amount += amount
		f.at = now
		f.label.Text = if kind == "block" then "BLOCK" else tostring(f.amount)
		return
	end

	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.CFrame = CFrame.new(x + math.random() - 0.5, 4, z)
	anchor.Parent = folder

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(70, 26)
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = if kind == "taken" then 20 else 18
	label.TextColor3 = NUMBER_COLORS[kind] or NUMBER_COLORS.dealt
	label.TextStrokeTransparency = 0.3
	label.Text = if kind == "block" then "BLOCK" else tostring(amount)
	label.Parent = gui
	gui.Parent = anchor

	f = { anchor = anchor, label = label, amount = amount, at = now }
	active[key] = f
	local rise = TweenService:Create(anchor, TweenInfo.new(NUMBER_LIFE), { CFrame = anchor.CFrame + Vector3.new(0, 3, 0) })
	TweenService:Create(label, TweenInfo.new(NUMBER_LIFE, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	rise.Completed:Once(function()
		if active[key] == f then
			active[key] = nil
		end
		anchor:Destroy()
	end)
	rise:Play()
end

-- A Shock Coil lightning segment (or a Laser Gun beam) between two points.
local function beam(x1: number, z1: number, x2: number, z2: number, color: Color3?, width: number?)
	local a, b = Vector3.new(x1, 3, z1), Vector3.new(x2, 3, z2)
	local length = (b - a).Magnitude
	if length < 0.1 then
		return
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color or Color3.fromRGB(150, 220, 255)
	p.Size = Vector3.new(width or 0.35, width or 0.35, length)
	p.CFrame = CFrame.lookAt((a + b) / 2, b)
	p.Parent = folder
	local tween = TweenService:Create(p, TweenInfo.new(0.18), { Transparency = 1, Size = Vector3.new(0.05, 0.05, length) })
	tween.Completed:Once(function()
		p:Destroy()
	end)
	tween:Play()
end

function Effects.init(fx: Folder)
	folder = fx
	Remotes.Effect.OnClientEvent:Connect(function(kind, x, z, radius, x2, z2)
		if type(x) ~= "number" or type(z) ~= "number" or type(radius) ~= "number" then
			return
		end
		if kind == "beam" or kind == "laser" then
			if type(x2) == "number" and type(z2) == "number" then
				if kind == "laser" then
					beam(x, z, x2, z2, Color3.fromRGB(255, 50, 70), 0.6)
					Vfx.impact(x2, z2, "laser")
					Sfx.at("Laser", Vector3.new(x, 3, z))
				else
					beam(x, z, x2, z2)
					Sfx.at("Zap", Vector3.new(x2, 3, z2))
				end
			end
		else
			burst(kind, x, z, radius)
		end
	end)
	Remotes.HitFeedback.OnClientEvent:Connect(function(targetId, x, z, amount, kind)
		if type(targetId) == "number" and type(x) == "number" and type(z) == "number" and type(amount) == "number" and type(kind) == "string" then
			show(targetId, x, z, amount, kind)
			if kind ~= "block" then
				Vfx.sparks(x, z, 3) -- melee and flame hits spark too
			end
			if kind == "dealt" then
				Sfx.ui("HitConfirm") -- a small tick: your hit landed
			elseif kind == "block" then
				Sfx.at("Deflect", Vector3.new(x, 3, z))
			end
		end
	end)
end

return Effects
