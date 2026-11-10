-- Builds the battlefield from MapLayout: grass with zone tints, the boundary
-- wall, inner walls and ruined pillars, tree groves and boulders. Also finds
-- clear spawn points.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Combat2D = require(Shared.Combat2D)
local MapLayout = require(Shared.MapLayout)
local World = require(script.Parent.World)

local Arena = {}

local A = Config.Arena
local boxes = MapLayout.boxes()
local circles = MapLayout.circles()
-- Bullets stop at these. Boxes are {minX, minZ, maxX, maxZ} for the hit tests.
Arena.coverBoxes = {} :: { { number } }
for _, b in boxes do
	table.insert(Arena.coverBoxes, { b.minX, b.minZ, b.maxX, b.maxZ })
end
Arena.circles = circles

local STONE = Color3.fromRGB(128, 126, 120) -- boundary wall
local DARK_STONE = Color3.fromRGB(92, 90, 86)

local function block(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance, collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = collide ~= false
	p.CanQuery = collide ~= false
	p.CanTouch = false
	p.Parent = parent
	return p
end

local function ball(name: string, diameter: number, pos: Vector3, color: Color3, material: Enum.Material, parent: Instance, collide: boolean?): Part
	local p = block(name, Vector3.one * diameter, CFrame.new(pos), color, material, parent, collide)
	p.Shape = Enum.PartType.Ball
	return p
end

local function buildTree(c, parent: Instance, rng: Random)
	local height = rng:NextNumber(9, 14)
	local trunkColor = Color3.fromRGB(rng:NextInteger(95, 115), rng:NextInteger(68, 82), rng:NextInteger(45, 55))
	local trunk = block("Trunk", Vector3.new(height, c.r * 2, c.r * 2), CFrame.new(c.x, height / 2, c.z) * CFrame.Angles(0, 0, math.rad(90)), trunkColor, Enum.Material.Wood, parent)
	trunk.Shape = Enum.PartType.Cylinder
	-- Canopy is cosmetic (no collision). Three shapes so groves don't look cloned.
	local green = Color3.fromRGB(rng:NextInteger(50, 78), rng:NextInteger(115, 155), rng:NextInteger(50, 70))
	local style = rng:NextInteger(1, 3)
	if style == 1 then -- round oak
		ball("Canopy", rng:NextNumber(8, 10), Vector3.new(c.x, height, c.z), green, Enum.Material.Grass, parent, false)
		ball("Canopy", rng:NextNumber(5, 7), Vector3.new(c.x + rng:NextNumber(-3, 3), height + 3, c.z + rng:NextNumber(-3, 3)), green:Lerp(Color3.new(1, 1, 1), 0.08), Enum.Material.Grass, parent, false)
	elseif style == 2 then -- bushy cluster
		for _ = 1, 4 do
			ball("Canopy", rng:NextNumber(5, 7), Vector3.new(c.x + rng:NextNumber(-3, 3), height + rng:NextNumber(-1.5, 2), c.z + rng:NextNumber(-3, 3)), green:Lerp(Color3.new(0, 0, 0), rng:NextNumber(0, 0.15)), Enum.Material.Grass, parent, false)
		end
	else -- tall pine: stacked shrinking discs
		local dark = green:Lerp(Color3.fromRGB(20, 60, 40), 0.35)
		for i = 0, 3 do
			local d = 8 - i * 1.8
			local tier = block("Canopy", Vector3.new(2.2, d, d), CFrame.new(c.x, height - 3 + i * 2.4, c.z) * CFrame.Angles(0, 0, math.rad(90)), dark, Enum.Material.Grass, parent, false)
			tier.Shape = Enum.PartType.Cylinder
		end
	end
end

local function buildRock(c, parent: Instance, rng: Random)
	local tint = rng:NextInteger(-10, 10)
	ball("Boulder", c.r * 2, Vector3.new(c.x, c.r * 0.55, c.z), Color3.fromRGB(110 + tint, 108 + tint, 104 + tint), Enum.Material.Slate, parent)
	ball("Boulder", c.r * 1.2, Vector3.new(c.x + c.r * 0.6, c.r * 0.35, c.z - c.r * 0.5), Color3.fromRGB(96, 94, 90), Enum.Material.Slate, parent, false)
	for _ = 1, 4 do -- pebbles around the base
		local a = rng:NextNumber(0, math.pi * 2)
		local d = c.r + rng:NextNumber(0.8, 2.5)
		ball("Pebble", rng:NextNumber(0.6, 1.3), Vector3.new(c.x + math.cos(a) * d, 0.2, c.z + math.sin(a) * d), Color3.fromRGB(120, 118, 112), Enum.Material.Slate, parent, false)
	end
end

-- The ground is Roblox Terrain, so materials blend into each other instead of
-- meeting at hard square edges: grass everywhere, leafy grass patches, a dirt
-- plaza with a ragged edge, worn dirt paths out to each side, rock beds under
-- the boulders.
-- The play field uses Leafy Grass, which is flat: Roblox's Grass material grows
-- 3D blades that hide orbs and pods, so real Grass only frames the map edges.
local function paintGround(full: number, rng: Random): { { number } }
	local terrain = Workspace.Terrain
	terrain:Clear()
	terrain:SetMaterialColor(Enum.Material.Grass, Color3.fromRGB(84, 140, 64))
	terrain:SetMaterialColor(Enum.Material.LeafyGrass, Color3.fromRGB(104, 160, 80))
	terrain:SetMaterialColor(Enum.Material.Ground, Color3.fromRGB(150, 124, 90))
	terrain:SetMaterialColor(Enum.Material.Mud, Color3.fromRGB(124, 100, 74))

	local size = full + 80
	terrain:FillBlock(CFrame.new(0, -4, 0), Vector3.new(size, 8, size), Enum.Material.LeafyGrass) -- top at Y = 0

	local function patch(x: number, z: number, radius: number, material: Enum.Material)
		terrain:FillCylinder(CFrame.new(x, -2, z), 4, radius, material)
	end

	-- Tall grass near the edges, deliberately uneven: each side gets its own
	-- random wave for how far the grass reaches in (a thin strip in places, deep
	-- tongues in others), plus loose clumps scattered further out.
	local grass: { { number } } = {} -- {x, z, r} of every grass blob, for bushes
	local function grassBlob(x: number, z: number, r: number)
		patch(x, z, r, Enum.Material.Grass)
		table.insert(grass, { x, z, r })
	end
	for _, s in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local f1, f2 = rng:NextNumber(0.02, 0.05), rng:NextNumber(0.07, 0.13)
		local p1, p2 = rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3)
		local t = -A.HalfSize - 10
		while t <= A.HalfSize + 10 do
			local wave = 0.5 + 0.5 * math.sin(t * f1 + p1)
			local ripple = 0.5 + 0.5 * math.sin(t * f2 + p2)
			local depth = 4 + 22 * wave * wave + 8 * ripple + rng:NextNumber(0, 5)
			local inward = A.HalfSize - depth / 2
			local along = t + rng:NextNumber(-3, 3)
			local x = if s[1] == 0 then along else s[1] * inward
			local z = if s[2] == 0 then along else s[2] * inward
			grassBlob(x, z, depth / 2 + rng:NextNumber(2, 5))
			t += rng:NextNumber(5, 11)
		end
	end
	-- Loose clumps: mostly near the edges, a few further in (never on the plaza).
	for _ = 1, 40 do
		local x, z = rng:NextNumber(-A.HalfSize, A.HalfSize), rng:NextNumber(-A.HalfSize, A.HalfSize)
		local d = Combat2D.chebyshev(x, z)
		if d > A.Zones.centre.max + 10 and rng:NextNumber() < (d - A.Zones.centre.max) / (A.HalfSize - A.Zones.centre.max) then
			grassBlob(x, z, rng:NextNumber(2.5, 7))
		end
	end

	-- The dirt plaza: a big core, then overlapping blobs for a soft, ragged edge.
	local plaza = A.Zones.centre.max - 4
	patch(0, 0, plaza - 10, Enum.Material.Ground)
	for i = 1, 32 do
		local a = i / 32 * math.pi * 2 + rng:NextNumber(-0.1, 0.1)
		local d = rng:NextNumber(plaza - 16, plaza - 2)
		patch(math.cos(a) * d, math.sin(a) * d, rng:NextNumber(7, 13), if rng:NextNumber() < 0.25 then Enum.Material.Mud else Enum.Material.Ground)
	end
	-- A few small dirt spots out on the field, so the green isn't one flat sheet.
	for _ = 1, 14 do
		local x, z = rng:NextNumber(-A.HalfSize + 30, A.HalfSize - 30), rng:NextNumber(-A.HalfSize + 30, A.HalfSize - 30)
		if Combat2D.chebyshev(x, z) > plaza + 12 then
			patch(x, z, rng:NextNumber(3, 6), Enum.Material.Ground)
		end
	end
	-- Worn paths from the plaza toward each side
	for k = 0, 3 do
		local ax, az = math.cos(k * math.pi / 2), math.sin(k * math.pi / 2)
		for d = plaza, A.HalfSize - 25, 9 do
			local wobble = math.sin(d * 0.07 + k) * 6
			local px, pz = ax * d - az * wobble, az * d + ax * wobble
			patch(px, pz, rng:NextNumber(3.5, 5), Enum.Material.Ground)
		end
	end
	-- Rock beds under the boulders
	for _, c in circles do
		if c.kind == "rock" then
			patch(c.x, c.z, c.r + 2.5, Enum.Material.Slate)
		end
	end
	return grass
end

-- Warm daylight with a soft haze, so the arena reads less flat.
local function setLighting()
	Lighting.ClockTime = 14.5
	Lighting.Brightness = 2.4
	Lighting.OutdoorAmbient = Color3.fromRGB(135, 140, 150)
	Lighting.GlobalShadows = true
	local function ensure(className: string, props: { [string]: any })
		local existing = Lighting:FindFirstChildOfClass(className)
		local inst = existing or Instance.new(className)
		for k, v in props do
			(inst :: any)[k] = v
		end
		inst.Parent = Lighting
	end
	ensure("Atmosphere", { Density = 0.3, Offset = 0.2, Color = Color3.fromRGB(205, 200, 185), Decay = Color3.fromRGB(110, 130, 160), Glare = 0.15, Haze = 1.4 })
	ensure("ColorCorrectionEffect", { Saturation = 0.12, Contrast = 0.06, Brightness = 0.02 })
	ensure("BloomEffect", { Intensity = 0.5, Size = 24, Threshold = 1.6 })
	ensure("SunRaysEffect", { Intensity = 0.06, Spread = 0.6 })
end

function Arena.build()
	-- The template place's Baseplate would z-fight with the ground, and a
	-- SpawnLocation would sit in the arena as an obstacle. Remove both at runtime.
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") or (child:IsA("BasePart") and child.Name == "Baseplate") then
			child:Destroy()
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = "Arena"
	local rng = Random.new(7) -- fixed seed: every server looks the same

	local full = A.HalfSize * 2
	local grass = paintGround(full, rng)
	setLighting()

	-- Boundary: a stone wall with posts, so the edge reads clearly in third-person.
	local h, t = A.WallHeight, A.WallThickness
	local edge = A.HalfSize + t / 2
	for _, side in { { 0, -edge, full + 2 * t, t }, { 0, edge, full + 2 * t, t }, { -edge, 0, t, full }, { edge, 0, t, full } } do
		block("BoundaryWall", Vector3.new(side[3], h, side[4]), CFrame.new(side[1], h / 2, side[2]), STONE, Enum.Material.Cobblestone, folder)
	end
	for i = -A.HalfSize, A.HalfSize, 38 do
		for _, p in { { i, -edge }, { i, edge }, { -edge, i }, { edge, i } } do
			block("WallPost", Vector3.new(t + 1.5, h + 2, t + 1.5), CFrame.new(p[1], (h + 2) / 2, p[2]), DARK_STONE, Enum.Material.Cobblestone, folder)
		end
	end

	-- Inner walls (weathered stone, each a slightly different shade) and ruined pillars
	for _, b in boxes do
		local sx, sz = b.maxX - b.minX, b.maxZ - b.minZ
		local cx, cz = (b.minX + b.maxX) / 2, (b.minZ + b.maxZ) / 2
		if b.kind == "pillar" then
			block("Pillar", Vector3.new(sx, b.height, sz), CFrame.new(cx, b.height / 2, cz), Color3.fromRGB(170, 160, 140), Enum.Material.Limestone, folder)
			block("PillarBase", Vector3.new(sx + 1.4, 1, sz + 1.4), CFrame.new(cx, 0.5, cz), Color3.fromRGB(150, 140, 122), Enum.Material.Limestone, folder, false)
			block("PillarCap", Vector3.new(sx + 1, 0.8, sz + 1), CFrame.new(cx, b.height + 0.4, cz), Color3.fromRGB(150, 140, 122), Enum.Material.Limestone, folder, false)
		else
			local shade = rng:NextInteger(-12, 12)
			local stone = Color3.fromRGB(128 + shade, 124 + shade, 116 + shade)
			block("Wall", Vector3.new(sx, b.height, sz), CFrame.new(cx, b.height / 2, cz), stone, Enum.Material.Cobblestone, folder)
			block("WallTop", Vector3.new(sx + 0.6, 0.5, sz + 0.6), CFrame.new(cx, b.height + 0.25, cz), DARK_STONE, Enum.Material.Slate, folder, false)
			-- A mossy band at the foot of the wall
			block("Moss", Vector3.new(sx + 0.2, 0.8, sz + 0.2), CFrame.new(cx, 0.4, cz), Color3.fromRGB(80, 110, 60), Enum.Material.Grass, folder, false)
		end
	end

	-- Trees and boulders
	for _, c in circles do
		if c.kind == "tree" then
			buildTree(c, folder, rng)
		else
			buildRock(c, folder, rng)
		end
	end

	-- Cosmetic bushes and flower clusters, only inside the tall-grass patches so
	-- the open field stays clean.
	local flowers = { Color3.fromRGB(240, 220, 90), Color3.fromRGB(240, 130, 170), Color3.fromRGB(235, 235, 245), Color3.fromRGB(160, 120, 230) }
	for _ = 1, 70 do
		local blob = grass[rng:NextInteger(1, #grass)]
		local a, d = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, blob[3])
		local x, z = blob[1] + math.cos(a) * d, blob[2] + math.sin(a) * d
		local inside = math.abs(x) < A.HalfSize - 2 and math.abs(z) < A.HalfSize - 2
		if inside and not Arena.inCover(x, z, 4) then
			if rng:NextNumber() < 0.55 then
				local g = Color3.fromRGB(rng:NextInteger(60, 80), rng:NextInteger(115, 140), rng:NextInteger(50, 65))
				ball("Bush", rng:NextNumber(2, 3.5), Vector3.new(x, 0.6, z), g, Enum.Material.Grass, folder, false)
				ball("Bush", rng:NextNumber(1.5, 2.5), Vector3.new(x + rng:NextNumber(-1.2, 1.2), 0.5, z + rng:NextNumber(-1.2, 1.2)), g:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Grass, folder, false)
			else
				local color = flowers[rng:NextInteger(1, #flowers)]
				for _ = 1, 6 do
					ball("Flower", rng:NextNumber(0.4, 0.7), Vector3.new(x + rng:NextNumber(-1.5, 1.5), 0.3, z + rng:NextNumber(-1.5, 1.5)), color, Enum.Material.SmoothPlastic, folder, false)
				end
			end
		end
	end

	folder.Parent = Workspace
	Arena.folder = folder
end

function Arena.inCover(x: number, z: number, margin: number): boolean
	for _, b in Arena.coverBoxes do
		if Combat2D.pointInBox(x, z, b[1], b[2], b[3], b[4], margin) then
			return true
		end
	end
	for _, c in circles do
		if (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + margin) ^ 2 then
			return true
		end
	end
	return false
end

-- A random point whose Chebyshev distance from the centre is in [min, max), clear of obstacles.
function Arena.randomPointInZone(zone: string, rng: Random, margin: number?): (number, number)
	local z = A.Zones[zone]
	local m = margin or 2
	for _ = 1, 50 do
		local x = rng:NextNumber(-z.max, z.max)
		local y = rng:NextNumber(-z.max, z.max)
		local d = Combat2D.chebyshev(x, y)
		if d >= z.min and d < z.max and not Arena.inCover(x, y, m) then
			return x, y
		end
	end
	return (z.min + z.max) / 2, 0
end

-- Outer-zone spawn at least SpawnMinEnemyDistance from every living robot;
-- after SpawnTries, the candidate farthest from everyone.
function Arena.findSpawn(rng: Random, avoid: { Vector3 }): (number, number)
	local bestX, bestZ = Arena.randomPointInZone("outer", rng, 5)
	local bestDist = -1
	for _ = 1, A.SpawnTries do
		local x, z = Arena.randomPointInZone("outer", rng, 5)
		local nearest = math.huge
		for _, e in World.entities do
			if e.alive and e.root then
				local p = e.root.Position
				nearest = math.min(nearest, math.sqrt((p.X - x) ^ 2 + (p.Z - z) ^ 2))
			end
		end
		local blocked = false
		for _, p in avoid do -- scrap piles: never spawn inside one
			if math.sqrt((p.X - x) ^ 2 + (p.Z - z) ^ 2) < 7 then
				blocked = true
			end
		end
		if blocked then
			continue
		end
		if nearest >= A.SpawnMinEnemyDistance then
			return x, z
		end
		if nearest > bestDist then
			bestX, bestZ, bestDist = x, z, nearest
		end
	end
	return bestX, bestZ
end

return Arena
