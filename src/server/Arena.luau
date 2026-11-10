-- The current map (D79, D81): builds any map from MapLayouts (greybox primitives
-- until the art exists), owns its cover lists for the hit tests, picks spawn points
-- and breaks destructible cover. The grassland keeps its terrain painting, trees,
-- rocks and flowers; biomes and boss arenas get FillBlock floors.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Combat2D = require(Shared.Combat2D)
local MapLayouts = require(Shared.MapLayouts)
local MapQuery = require(Shared.MapQuery)
local Remotes = require(Shared.Remotes)
local World = require(script.Parent.World)

local Arena = {}

local A = Config.Arena
Arena.folder = nil :: Folder?

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
	for _, c in MapLayouts.grassland.circles do
		if c.kind == "stone" and c.h < c.r * 2.5 then
			patch(c.x, c.z, c.r + 2.5, Enum.Material.Slate)
		end
	end
	return grass
end

-- Warm daylight with a soft haze, so the arena reads less flat.

local function color(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

-- Lighting per map (Config.Maps.lighting, bible section 10). Snapped during the fade.
local function setLighting(name: string)
	local L = Config.Maps.lighting[name] or Config.Maps.lighting.grassland
	Lighting.ClockTime = L.clock
	Lighting.Brightness = L.brightness
	Lighting.OutdoorAmbient = color(L.ambient)
	Lighting.GlobalShadows = true
	local function ensure(className: string, props: { [string]: any })
		local existing = Lighting:FindFirstChildOfClass(className)
		local inst = existing or Instance.new(className)
		for k, v in props do
			(inst :: any)[k] = v
		end
		inst.Parent = Lighting
	end
	local a = L.atmosphere
	ensure("Atmosphere", { Density = a.density, Offset = a.offset, Color = color(a.color), Decay = color(a.decay), Glare = a.glare, Haze = a.haze })
	ensure("ColorCorrectionEffect", { Brightness = L.cc.brightness, Contrast = L.cc.contrast, Saturation = L.cc.saturation, TintColor = color(L.cc.tint) })
	ensure("BloomEffect", { Intensity = L.bloom.intensity, Size = L.bloom.size, Threshold = L.bloom.threshold })
	ensure("SunRaysEffect", { Intensity = L.sunRays, Spread = 0.6 })
end

-- Biome and arena floors (E6): FillBlock squares, no TerrainRegion paste.
-- { material, colour } for the outer, middle and centre squares (arenas: floor, outside).
local FLOORS = {
	forge_highlands = { { Enum.Material.Slate, { 111, 106, 99 } }, { Enum.Material.Pebble, { 142, 133, 122 } }, { Enum.Material.Ground, { 183, 174, 159 } } },
	inferno_fields = { { Enum.Material.Basalt, { 52, 48, 46 } }, { Enum.Material.Ground, { 90, 84, 80 } }, { Enum.Material.Basalt, { 76, 69, 66 } } },
	grinder_scrapyard = { { Enum.Material.Asphalt, { 92, 82, 72 } }, { Enum.Material.Ground, { 124, 116, 106 } }, { Enum.Material.Concrete, { 154, 150, 142 } } },
	arena_forge = { { Enum.Material.Basalt, { 58, 54, 52 } }, { Enum.Material.CrackedLava, { 255, 120, 40 } } },
	arena_inferno = { { Enum.Material.Basalt, { 46, 42, 40 } }, { Enum.Material.CrackedLava, { 255, 90, 26 } } },
	arena_grinder = { { Enum.Material.Concrete, { 110, 106, 100 } }, { Enum.Material.Asphalt, { 60, 56, 54 } } },
}

local function paintFloor(map: any)
	local terrain = Workspace.Terrain
	local f = FLOORS[map.name]
	terrain:Clear()
	for _, m in f do
		terrain:SetMaterialColor(m[1], color(m[2]))
	end
	local size = map.half * 2 + 80
	local function square(side: number, material: Enum.Material)
		terrain:FillBlock(CFrame.new(0, -4, 0), Vector3.new(side, 8, side), material) -- top at Y = 0
	end
	if map.kind == "overworld" then
		square(size, f[1][1])
		square(A.Zones.middle.max * 2, f[2][1])
		square(A.Zones.centre.max * 2, f[3][1])
	else
		square(size + 160, f[2][1]) -- glowing or dark ground outside the arena walls
		square(map.half * 2, f[1][1])
	end
end

-- Map state ----------------------------------------------------------------------

local current: any = MapLayouts.grassland
Arena.broken = {} :: { [number]: boolean }
local pieceParts: { [number]: { Instance } } = {}

function Arena.map(): any
	return current
end

function Arena.half(): number
	return current.half
end

function Arena.isArena(): boolean
	return current.kind == "arena"
end

-- First fraction (0..1) of the segment that meets cover grown by pad, or nil.
function Arena.blockedAt(x1: number, z1: number, x2: number, z2: number, pad: number): number?
	return MapQuery.blockedAt(current, x1, z1, x2, z2, pad, Arena.broken)
end

function Arena.inCover(x: number, z: number, margin: number): boolean
	return MapQuery.inCover(current, x, z, margin, Arena.broken)
end

-- A random clear point in a zone (arenas: anywhere on the fight floor).
function Arena.randomPointInZone(zone: string, rng: Random, margin: number?): (number, number)
	return MapQuery.randomInZone(current, A.Zones, zone, rng, margin or 2, Arena.broken)
end

-- The map's Spawn point farthest from every living robot (E5), never on a crate.
function Arena.findSpawn(rng: Random, avoid: { Vector3 }): (number, number)
	local enemies = {}
	for _, e in World.entities do
		if e.alive and e.root then
			local p = e.root.Position
			table.insert(enemies, { p.X, p.Z })
		end
	end
	for _, p in avoid do -- crates count as "close": never spawn inside one
		table.insert(enemies, { p.X, p.Z })
	end
	return MapQuery.pickSpawn(current, enemies, A.SpawnMinEnemyDistance, rng:NextInteger(1, #current.spawns))
end

-- Greybox pieces ------------------------------------------------------------------

local KIND = {
	stone = { Enum.Material.Cobblestone, Color3.fromRGB(128, 124, 116) },
	metal = { Enum.Material.DiamondPlate, Color3.fromRGB(70, 80, 92) },
	scrap = { Enum.Material.CorrodedMetal, Color3.fromRGB(128, 92, 60) },
	obsidian = { Enum.Material.Basalt, Color3.fromRGB(38, 34, 44) },
	wood = { Enum.Material.Wood, Color3.fromRGB(110, 78, 48) },
}
local CONTAINER = { Color3.fromRGB(47, 110, 142), Color3.fromRGB(184, 73, 46), Color3.fromRGB(94, 122, 58) }

local function obbFrame(b: any, y: number): CFrame
	return CFrame.fromMatrix(Vector3.new(b.cx, y, b.cz), Vector3.new(b.ux, 0, b.uz), Vector3.yAxis)
end

-- Destructible cover shows a glowing crack band, so players learn it breaks.
local function crackBand(size: Vector3, cf: CFrame, parent: Instance): Part
	local p = block("Cracks", size, cf, Color3.fromRGB(255, 120, 40), Enum.Material.Neon, parent, false)
	p.Transparency = 0.35
	return p
end

local function buildBox(b: any, parent: Instance, rng: Random): { Instance }
	local style = KIND[b.kind] or KIND.stone
	local col = style[2]
	if b.name == "ContainerStack" or b.name == "SortingBin" then
		col = CONTAINER[(b.id % #CONTAINER) + 1]
	elseif b.kind == "stone" then
		local shade = rng:NextInteger(-12, 12)
		col = Color3.fromRGB(128 + shade, 124 + shade, 116 + shade)
	end
	local size = Vector3.new(b.hu * 2, b.h, b.hv * 2)
	local parts: { Instance } = {}
	table.insert(parts, block(b.name, size, obbFrame(b, b.h / 2), col, style[1], parent))
	if b.kind == "stone" and current.name == "grassland" then
		table.insert(parts, block("WallTop", size + Vector3.new(0.6, 0.5 - b.h, 0.6), obbFrame(b, b.h + 0.25), DARK_STONE, Enum.Material.Slate, parent, false))
		table.insert(parts, block("Moss", size + Vector3.new(0.2, 0.8 - b.h, 0.2), obbFrame(b, 0.4), Color3.fromRGB(80, 110, 60), Enum.Material.Grass, parent, false))
	end
	if b.d then
		table.insert(parts, crackBand(size + Vector3.new(0.3, 0.4 - b.h, 0.3), obbFrame(b, b.h * 0.6), parent))
	end
	return parts
end

local function buildCircle(c: any, parent: Instance, rng: Random): { Instance }
	if c.kind == "wood" and c.r < 3 then
		buildTree(c, parent, rng)
		return {}
	end
	if c.kind == "stone" and c.h < c.r * 2.5 then
		buildRock(c, parent, rng)
		return {}
	end
	local style = KIND[c.kind] or KIND.stone
	local parts: { Instance } = {}
	local post = block(c.name, Vector3.new(c.h, c.r * 2, c.r * 2), CFrame.new(c.x, c.h / 2, c.z) * CFrame.Angles(0, 0, math.rad(90)), style[2], style[1], parent)
	post.Shape = Enum.PartType.Cylinder
	table.insert(parts, post)
	if c.kind == "wood" then -- a big old tree: the canopy is overhead decor
		local green = Color3.fromRGB(rng:NextInteger(60, 90), rng:NextInteger(120, 150), rng:NextInteger(50, 70))
		ball("Canopy", c.r * 7, Vector3.new(c.x, c.h + c.r * 2.5, c.z), green, Enum.Material.Grass, parent, false)
	end
	if c.d then
		local band = crackBand(Vector3.new(0.4, c.r * 2 + 0.3, c.r * 2 + 0.3), CFrame.new(c.x, c.h * 0.6, c.z) * CFrame.Angles(0, 0, math.rad(90)), parent)
		band.Shape = Enum.PartType.Cylinder
		table.insert(parts, band)
	end
	return parts
end

local function disc(name: string, x: number, z: number, radius: number, col: Color3, parent: Instance): Part
	local p = block(name, Vector3.new(0.12, radius * 2, radius * 2), CFrame.new(x, 0.08, z) * CFrame.Angles(0, 0, math.rad(90)), col, Enum.Material.Neon, parent, false)
	p.Shape = Enum.PartType.Cylinder
	p.Transparency = 0.6
	return p
end

-- Destroys a destructible piece: no longer blocks anything, server or client.
-- kind is "box" or "circle"; returns its centre so the caller can play debris.
function Arena.breakPiece(kind: string, id: number): (number?, number?)
	local key = if kind == "circle" then MapQuery.CIRCLE_KEY + id else id
	if Arena.broken[key] then
		return nil, nil
	end
	Arena.broken[key] = true
	local parts = pieceParts[key]
	if parts then
		for _, p in parts do
			p:Destroy()
		end
	end
	pieceParts[key] = nil
	Remotes.CoverBroken:FireAllClients(kind, id)
	local list = if kind == "circle" then current.circles else current.boxes
	for _, piece in list do
		if piece.id == id then
			return piece.cx or piece.x, piece.cz or piece.z
		end
	end
	return nil, nil
end

-- Builds a map (D81): floor, lighting, boundary wall, cover, lava, spawn pads and the
-- boss gate. Replaces whatever map was up. Sets Workspace attribute Map.
function Arena.load(name: string)
	local map = MapLayouts[name]
	assert(map, "no map " .. tostring(name))
	current = map
	Arena.broken = {}
	pieceParts = {}
	local old = Arena.folder
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "Arena"
	local rng = Random.new(7) -- fixed seed: every server looks the same

	local grass: { { number } } = {}
	if name == "grassland" then
		grass = paintGround(A.HalfSize * 2, rng)
	else
		paintFloor(map)
	end
	setLighting(name)

	-- Boundary: a wall at the map's edge (arenas: tall, closed in). Posts on the overworld.
	local h, t = map.wallHeight, A.WallThickness
	local half = map.half
	local full = half * 2
	local edge = half + t / 2
	local wallColor = if map.kind == "arena" then Color3.fromRGB(70, 66, 62) else STONE
	for _, side in { { 0, -edge, full + 2 * t, t }, { 0, edge, full + 2 * t, t }, { -edge, 0, t, full }, { edge, 0, t, full } } do
		block("BoundaryWall", Vector3.new(side[3], h, side[4]), CFrame.new(side[1], h / 2, side[2]), wallColor, Enum.Material.Cobblestone, folder)
	end
	if map.kind == "overworld" then
		for i = -half, half, 38 do
			for _, p in { { i, -edge }, { i, edge }, { -edge, i }, { edge, i } } do
				block("WallPost", Vector3.new(t + 1.5, h + 2, t + 1.5), CFrame.new(p[1], (h + 2) / 2, p[2]), DARK_STONE, Enum.Material.Cobblestone, folder)
			end
		end
	end

	for _, b in map.boxes do
		pieceParts[b.id] = buildBox(b, folder, rng)
	end
	for _, c in map.circles do
		pieceParts[MapQuery.CIRCLE_KEY + c.id] = buildCircle(c, folder, rng)
	end
	for _, l in map.lava do
		local p = block("Lava", Vector3.new(l.hu * 2, 0.2, l.hv * 2), obbFrame(l, 0.06), Color3.fromRGB(255, 96, 20), Enum.Material.Neon, folder, false)
		p.Transparency = 0.05
	end
	for _, s in map.spawns do
		disc("SpawnPad", s.x, s.z, 3, Color3.fromRGB(47, 214, 232), folder)
	end
	for _, p in map.pads do
		disc("HealthPad", p.x, p.z, 3, Color3.fromRGB(60, 200, 90), folder)
	end
	if map.gate then -- the boss gate: a glowing doorway on the inside face of the wall
		local g = map.gate
		local onX = math.abs(g.x) > math.abs(g.z)
		local size = if onX then Vector3.new(1, 22, 26) else Vector3.new(26, 22, 1)
		local pos = Vector3.new(if onX then math.sign(g.x) * (half - 0.5) else g.x, 11, if onX then g.z else math.sign(g.z) * (half - 0.5))
		local door = block("BossGate", size, CFrame.new(pos), Color3.fromRGB(255, 110, 40), Enum.Material.Neon, folder, false)
		door.Transparency = 0.25
	end

	-- Grassland: bushes and flower clusters in the tall-grass patches (cosmetic).
	if name == "grassland" then
		local flowers = { Color3.fromRGB(240, 220, 90), Color3.fromRGB(240, 130, 170), Color3.fromRGB(235, 235, 245), Color3.fromRGB(160, 120, 230) }
		for _ = 1, 70 do
			local blob = grass[rng:NextInteger(1, #grass)]
			local a, d = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, blob[3])
			local x, z = blob[1] + math.cos(a) * d, blob[2] + math.sin(a) * d
			local inside = math.abs(x) < half - 2 and math.abs(z) < half - 2
			if inside and not Arena.inCover(x, z, 4) then
				if rng:NextNumber() < 0.55 then
					local g = Color3.fromRGB(rng:NextInteger(60, 80), rng:NextInteger(115, 140), rng:NextInteger(50, 65))
					ball("Bush", rng:NextNumber(2, 3.5), Vector3.new(x, 0.6, z), g, Enum.Material.Grass, folder, false)
					ball("Bush", rng:NextNumber(1.5, 2.5), Vector3.new(x + rng:NextNumber(-1.2, 1.2), 0.5, z + rng:NextNumber(-1.2, 1.2)), g:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Grass, folder, false)
				else
					local fc = flowers[rng:NextInteger(1, #flowers)]
					for _ = 1, 6 do
						ball("Flower", rng:NextNumber(0.4, 0.7), Vector3.new(x + rng:NextNumber(-1.5, 1.5), 0.3, z + rng:NextNumber(-1.5, 1.5)), fc, Enum.Material.SmoothPlastic, folder, false)
					end
				end
			end
		end
	end

	folder.Parent = Workspace
	Arena.folder = folder
	Workspace:SetAttribute("Map", name)
	Workspace:SetAttribute("MapDisplay", map.displayName)
end

-- Boot: clear the template's Baseplate and SpawnLocation, then build the grassland.
function Arena.build()
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") or (child:IsA("BasePart") and child.Name == "Baseplate") then
			child:Destroy()
		end
	end
	Arena.load("grassland")
end

return Arena
