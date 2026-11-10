-- 3D models for the Health Pack, Armor Pod, Fortify Pod and coin pickups.
--
-- Uses a Toolbox model if you add one in Studio:
--   ReplicatedStorage > PickupModels > HealthPack   (a Model, Accessory or Tool)
--   ReplicatedStorage > PickupModels > ArmorPack
--   ReplicatedStorage > PickupModels > FortifyPod
--   ReplicatedStorage > PickupModels > Coin
-- (Rojo leaves extra children of ReplicatedStorage alone, so they survive syncs.)
-- Any scripts inside a Toolbox model are removed before use, it is anchored and
-- made non-colliding, and it is scaled to fit the pickup size.
-- Without one, a simple built-in model is made from parts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PickupModels = {}

local TEMPLATE_NAMES = { health = "HealthPack", armor = "ArmorPack", fortify = "FortifyPod", coin = "Coin" }
local FIT_SIZE = { health = 2.2, armor = 2.6, fortify = 2.4, coin = 2.4 } -- largest dimension, in studs

local function part(model: Model, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- A white first-aid case with red crosses, a handle and latches.
local function builtInHealth(): Model
	local m = Instance.new("Model")
	m.Name = "HealthPack"
	local white = Color3.fromRGB(240, 240, 236)
	local red = Color3.fromRGB(215, 45, 45)
	local base = part(m, Vector3.new(2.2, 1.5, 1.2), CFrame.new(), white)
	for _, z in { -0.61, 0.61 } do
		part(m, Vector3.new(0.9, 0.28, 0.05), CFrame.new(0, 0, z), red)
		part(m, Vector3.new(0.28, 0.9, 0.05), CFrame.new(0, 0, z), red)
	end
	part(m, Vector3.new(2.24, 0.12, 1.24), CFrame.new(0, 0.35, 0), Color3.fromRGB(200, 200, 196)) -- lid seam
	part(m, Vector3.new(0.9, 0.18, 0.18), CFrame.new(0, 0.95, 0), Color3.fromRGB(60, 60, 64)) -- handle grip
	for _, x in { -0.42, 0.42 } do
		part(m, Vector3.new(0.14, 0.3, 0.14), CFrame.new(x, 0.82, 0), Color3.fromRGB(60, 60, 64))
		part(m, Vector3.new(0.18, 0.22, 0.06), CFrame.new(x * 1.9, 0.35, 0.63), Color3.fromRGB(150, 150, 155), Enum.Material.Metal) -- latches
	end
	m.PrimaryPart = base
	return m
end

-- A steel chest plate (vest) with shoulder straps and side panels.
local function builtInArmor(): Model
	local m = Instance.new("Model")
	m.Name = "ArmorPack"
	local steel = Color3.fromRGB(120, 140, 165)
	local dark = Color3.fromRGB(60, 70, 85)
	local trim = Color3.fromRGB(90, 190, 255)
	local front = part(m, Vector3.new(1.9, 2.1, 0.35), CFrame.new(0, 0, -0.5), steel, Enum.Material.Metal)
	part(m, Vector3.new(1.9, 2.1, 0.35), CFrame.new(0, 0, 0.5), dark, Enum.Material.Metal) -- back plate
	for _, x in { -0.75, 0.75 } do
		part(m, Vector3.new(0.4, 0.25, 1.35), CFrame.new(x, 1.0, 0), dark, Enum.Material.Fabric) -- shoulder straps
		part(m, Vector3.new(0.25, 1.4, 1.0), CFrame.new(x * 1.33, -0.25, 0), dark, Enum.Material.Fabric) -- side panels
	end
	part(m, Vector3.new(1.4, 0.12, 0.05), CFrame.new(0, 0.55, -0.69), trim, Enum.Material.Metal) -- chest stripe
	part(m, Vector3.new(0.9, 0.7, 0.08), CFrame.new(0, -0.35, -0.71), Color3.fromRGB(150, 168, 190), Enum.Material.DiamondPlate) -- insert plate
	m.PrimaryPart = front
	return m
end

-- A magenta heart with a white plus on both faces: extra max HP.
-- The heart is a square turned 45 degrees with a disc on each upper edge.
local function builtInFortify(): Model
	local m = Instance.new("Model")
	m.Name = "FortifyPod"
	local pink = Color3.fromRGB(230, 90, 200)
	local white = Color3.fromRGB(250, 245, 250)
	local side, depth = 1.2, 0.5
	local body = part(m, Vector3.new(side, side, depth), CFrame.Angles(0, 0, math.rad(45)), pink)
	body.Reflectance = 0.1
	local lobe = side / (2 * math.sqrt(2)) -- edge midpoint offset
	for _, x in { -lobe, lobe } do
		local disc = part(m, Vector3.new(depth, side, side), CFrame.new(x, lobe, 0) * CFrame.Angles(0, math.rad(90), 0), pink, nil, Enum.PartType.Cylinder)
		disc.Reflectance = 0.1
	end
	for _, z in { -(depth / 2 + 0.03), depth / 2 + 0.03 } do
		part(m, Vector3.new(0.75, 0.22, 0.06), CFrame.new(0, 0.12, z), white)
		part(m, Vector3.new(0.22, 0.75, 0.06), CFrame.new(0, 0.12, z), white)
	end
	m.PrimaryPart = body
	return m
end

-- A struck gold coin (D78): a raised rim, a bright field and a cog emblem on both
-- faces, with a glint of sparkle and a warm light. It stands on its edge and spins.
local function builtInCoin(): Model
	local m = Instance.new("Model")
	m.Name = "Coin"
	local rimGold = Color3.fromRGB(214, 158, 36)
	local fieldGold = Color3.fromRGB(255, 206, 72)
	local deepGold = Color3.fromRGB(176, 120, 24)
	local rim = part(m, Vector3.new(0.34, 2.2, 2.2), CFrame.identity, rimGold, Enum.Material.Metal, Enum.PartType.Cylinder)
	rim.Reflectance = 0.25
	local field = part(m, Vector3.new(0.38, 1.8, 1.8), CFrame.identity, fieldGold, Enum.Material.Metal, Enum.PartType.Cylinder)
	field.Reflectance = 0.3
	part(m, Vector3.new(0.42, 0.9, 0.9), CFrame.identity, deepGold, Enum.Material.Metal, Enum.PartType.Cylinder)
	part(m, Vector3.new(0.44, 0.4, 0.4), CFrame.identity, fieldGold, Enum.Material.Metal, Enum.PartType.Cylinder)
	for i = 0, 5 do
		local a = i * math.pi / 3
		part(m, Vector3.new(0.42, 0.26, 0.26), CFrame.new(0, math.cos(a) * 0.52, math.sin(a) * 0.52) * CFrame.Angles(a, 0, 0), deepGold, Enum.Material.Metal)
	end
	local glint = Instance.new("ParticleEmitter")
	glint.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	glint.Rate = 3
	glint.Lifetime = NumberRange.new(0.4, 0.7)
	glint.Speed = NumberRange.new(0, 0.5)
	glint.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 0) })
	glint.Color = ColorSequence.new(Color3.fromRGB(255, 240, 180))
	glint.LightEmission = 1
	glint.Parent = rim
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 80)
	light.Range = 7
	light.Brightness = 0.8
	light.Parent = rim
	m.PrimaryPart = rim
	return m
end

local BUILT_IN = { health = builtInHealth, armor = builtInArmor, fortify = builtInFortify, coin = builtInCoin }

-- Strips scripts, anchors, disables collision, and scales to fit.
local function prepare(model: Model, fit: number): Model
	for _, d in model:GetDescendants() do
		local unwanted = d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ProximityPrompt") or d:IsA("ClickDetector")
		if unwanted then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
		end
	end
	local _, size = model:GetBoundingBox()
	local largest = math.max(size.X, size.Y, size.Z)
	if largest > 0 then
		model:ScaleTo(model:GetScale() * fit / largest)
	end
	return model
end

-- A fresh, ready-to-place model for a pickup kind, or nil if the kind is not modelled.
function PickupModels.create(kind: string): Model?
	local name = TEMPLATE_NAMES[kind]
	if not name then
		return nil
	end
	local folder = ReplicatedStorage:FindFirstChild("PickupModels")
	local template = folder and folder:FindFirstChild(name)
	local model: Model
	if template then
		local copy = template:Clone()
		if copy:IsA("Model") then
			model = copy
		else
			model = Instance.new("Model") -- an Accessory or Tool: wrap it
			model.Name = name
			copy.Parent = model
		end
	else
		model = BUILT_IN[kind]()
	end
	return prepare(model, FIT_SIZE[kind])
end

return PickupModels
