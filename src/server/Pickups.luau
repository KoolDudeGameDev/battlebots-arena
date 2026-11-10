-- XP orbs (server-side data in a spatial grid, rendered by clients) and
-- destructible scrap crates (real Parts). GDD section 11.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local World = require(script.Parent.World)
local Arena = require(script.Parent.Arena)
local Guard = require(script.Parent.Guard)

local Pickups = {}

local KIND_CODE = { small = 1, medium = 2, core = 3, death = 4 }
for kind, pod in Config.Pods do
	KIND_CODE[kind] = pod.code -- booster pods ride the same grid and batches (D34)
end
KIND_CODE.coin = Config.Coins.code -- coins too (D73)
local mapCoins = 0
local podCounts: { [string]: number } = {}
local CELL = Config.OrbCellSize
local rng = Random.new()

type Orb = { id: number, kind: string, x: number, z: number, value: number, zone: string?, cell: number, despawnAt: number?, mapCoin: boolean? }

local orbs: { [number]: Orb } = {}
local grid: { [number]: { [number]: Orb } } = {}
local zoneCounts: { [string]: { [string]: number } } = {}
local nextOrbId = 0
local spawnedBatch = {}
local collectedBatch = {}

local function cellKey(cx: number, cz: number): number
	return (cx + 1000) * 4096 + (cz + 1000)
end

local function cellOf(x: number, z: number): number
	return cellKey(math.floor(x / CELL), math.floor(z / CELL))
end

local function encode(o: Orb)
	if o.kind == "death" or o.kind == "coin" then
		return { o.id, KIND_CODE[o.kind], o.x, o.z, o.value }
	end
	return { o.id, KIND_CODE[o.kind], o.x, o.z }
end

local function spawnOrb(kind: string, x: number, z: number, value: number?, zone: string?)
	nextOrbId += 1
	local half = Arena.half() - 2
	x = math.clamp(x, -half, half)
	z = math.clamp(z, -half, half)
	local o: Orb = {
		id = nextOrbId,
		kind = kind,
		x = x,
		z = z,
		value = value or (if Config.Orbs[kind] then Config.Orbs[kind].value else 0),
		zone = zone,
		cell = cellOf(x, z),
		despawnAt = if kind == "death" then os.clock() + Config.Death.DeathOrbDespawn else nil,
	}
	orbs[o.id] = o
	local bucket = grid[o.cell]
	if not bucket then
		bucket = {}
		grid[o.cell] = bucket
	end
	bucket[o.id] = o
	if zone then
		zoneCounts[zone][kind] = (zoneCounts[zone][kind] or 0) + 1
	end
	if Config.Pods[kind] then
		podCounts[kind] = (podCounts[kind] or 0) + 1
	end
	table.insert(spawnedBatch, encode(o))
end

-- A coin worth Config.Coins.value; map coins count toward the map's cap (D73).
function Pickups.spawnCoin(x: number, z: number, isMapCoin: boolean?)
	spawnOrb("coin", x, z, Config.Coins.value)
	if isMapCoin then
		local o = orbs[nextOrbId]
		o.mapCoin = true
		mapCoins += 1
	end
end

-- Drops a booster pod (also used by Supply Drop and /pod).
function Pickups.spawnPod(kind: string, x: number, z: number)
	if Config.Pods[kind] then
		spawnOrb(kind, x, z)
	end
end

local function removeOrb(o: Orb, collectorUserId: number)
	orbs[o.id] = nil
	local bucket = grid[o.cell]
	if bucket then
		bucket[o.id] = nil
		if next(bucket) == nil then
			grid[o.cell] = nil
		end
	end
	if o.zone then
		zoneCounts[o.zone][o.kind] -= 1
	end
	if Config.Pods[o.kind] then
		podCounts[o.kind] -= 1
	end
	if o.mapCoin then
		mapCoins -= 1
	end
	table.insert(collectedBatch, o.id)
	table.insert(collectedBatch, collectorUserId)
end

-- Spills `count` red death orbs worth `value` each around (x, z).
function Pickups.spill(x: number, z: number, count: number, value: number)
	for _ = 1, count do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(1, 7)
		spawnOrb("death", x + math.cos(a) * r, z + math.sin(a) * r, value)
	end
end

local function drop(x: number, z: number, drops: { [string]: number }, spread: number)
	for kind, n in drops do
		for _ = 1, n do
			local a = rng:NextNumber(0, math.pi * 2)
			local r = rng:NextNumber(1, spread)
			spawnOrb(kind, x + math.cos(a) * r, z + math.sin(a) * r)
		end
	end
end

-- Scrap (shoot to break, drops XP) -----------------------------------------------
-- "small" = a Scrap Heap of bent metal, "large" = a Robot Wreck in the centre.
-- Each is a Model: an invisible cylinder is the solid hitbox, the rest is cosmetic.

export type Crate = { id: number, kind: string, x: number, z: number, radius: number, hp: number, maxHp: number, part: Model?, alive: boolean }

Pickups.crates = {} :: { Crate }
Pickups.chest = nil :: Crate?
local crateFolder: Folder

local RUST = Color3.fromRGB(150, 92, 56)
local METAL = Color3.fromRGB(120, 124, 130)
local DARK = Color3.fromRGB(55, 58, 64)

local function scrapPart(model: Model, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	if shape then
		p.Shape = shape
	end
	p.Parent = model
end

-- Scrap heaps and wrecks come from Config.Crates; the coin chest from Config.Coins (D73).
local function defOf(kind: string): any
	return if kind == "chest" then Config.Coins.chest else Config.Crates[kind]
end

local function buildScrap(kind: string, x: number, z: number, radius: number): Model
	local model = Instance.new("Model")
	model.Name = if kind == "large" then "RobotWreck" elseif kind == "chest" then "CoinChest" else "ScrapHeap"
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Shape = Enum.PartType.Cylinder
	hitbox.Anchored = true
	hitbox.Transparency = 1
	hitbox.Size = Vector3.new(3, radius * 2, radius * 2)
	hitbox.CFrame = CFrame.new(x, 1.5, z) * CFrame.Angles(0, 0, math.rad(90))
	hitbox.Parent = model
	model.PrimaryPart = hitbox

	local base = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local function tilt(): CFrame
		return CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, math.pi), rng:NextNumber(-0.5, 0.5))
	end
	if kind == "chest" then
		-- A wooden chest with gold bands, a lid and a glowing gold lock.
		local wood, gold = Color3.fromRGB(120, 72, 36), Color3.fromRGB(255, 196, 40)
		scrapPart(model, Vector3.new(5, 2.6, 3.4), base * CFrame.new(0, 1.3, 0), wood, Enum.Material.WoodPlanks)
		scrapPart(model, Vector3.new(5.1, 1.3, 3.5), base * CFrame.new(0, 3.1, 0), wood:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.WoodPlanks)
		for _, bx in { -1.6, 1.6 } do
			scrapPart(model, Vector3.new(0.35, 3.95, 3.6), base * CFrame.new(bx, 1.98, 0), gold, Enum.Material.Metal)
		end
		scrapPart(model, Vector3.new(0.8, 0.9, 0.3), base * CFrame.new(0, 2.6, -1.8), gold, Enum.Material.Neon)
	elseif kind == "large" then
		-- A wrecked robot: tipped chassis, loose wheel, bent turret and barrel, sparks.
		scrapPart(model, Vector3.new(6, 2, 5), base * CFrame.new(0, 1.2, 0) * CFrame.Angles(0.15, 0, 0.25), DARK, Enum.Material.DiamondPlate)
		scrapPart(model, Vector3.new(3, 1.3, 3), base * CFrame.new(0.6, 2.6, -0.4) * CFrame.Angles(0.4, 0.6, 0.2), RUST, Enum.Material.CorrodedMetal)
		scrapPart(model, Vector3.new(0.7, 0.7, 4), base * CFrame.new(1.2, 2.9, -2.6) * CFrame.Angles(0.5, 0.3, 0), METAL, Enum.Material.Metal)
		scrapPart(model, Vector3.new(0.9, 2.6, 2.6), base * CFrame.new(-3.6, 1.3, 1.8) * CFrame.Angles(0, 0.4, 0), DARK, Enum.Material.Slate, Enum.PartType.Cylinder)
		scrapPart(model, Vector3.new(0.9, 2.6, 2.6), base * CFrame.new(3.4, 0.5, 2.5) * CFrame.Angles(0, 0, math.rad(90)), DARK, Enum.Material.Slate, Enum.PartType.Cylinder)
		for _ = 1, 3 do
			scrapPart(model, Vector3.new(rng:NextNumber(1, 2), 0.4, rng:NextNumber(1, 2)), base * CFrame.new(rng:NextNumber(-4, 4), 0.3, rng:NextNumber(-4, 4)) * tilt(), METAL, Enum.Material.CorrodedMetal)
		end
		scrapPart(model, Vector3.new(0.5, 0.5, 0.5), base * CFrame.new(-0.8, 2.5, 1.2), Color3.fromRGB(255, 150, 40), Enum.Material.Neon, Enum.PartType.Ball)
	else
		-- A heap of bent plates, a gear and a pipe.
		for _ = 1, 5 do
			scrapPart(model, Vector3.new(rng:NextNumber(1.2, 2.4), rng:NextNumber(0.4, 1), rng:NextNumber(1.2, 2.4)), base * CFrame.new(rng:NextNumber(-1.3, 1.3), rng:NextNumber(0.4, 1.4), rng:NextNumber(-1.3, 1.3)) * tilt(), if rng:NextNumber() < 0.5 then RUST else METAL, Enum.Material.CorrodedMetal)
		end
		scrapPart(model, Vector3.new(0.4, 1.8, 1.8), base * CFrame.new(0.3, 1.9, 0.2) * CFrame.Angles(0.3, 0, math.rad(80)), METAL, Enum.Material.Metal, Enum.PartType.Cylinder)
		scrapPart(model, Vector3.new(2.6, 0.45, 0.45), base * CFrame.new(-0.6, 1.5, -0.6) * CFrame.Angles(0, 0.7, 0.4), DARK, Enum.Material.Metal, Enum.PartType.Cylinder)
	end
	return model
end

local function placeCrate(c: Crate)
	if c.alive then
		return -- already placed (e.g. /chest moved it here before the respawn timer)
	end
	local def = defOf(c.kind)
	local zone = def.zones[rng:NextInteger(1, #def.zones)]
	local x, z = Arena.randomPointInZone(zone, rng, def.size)
	c.x, c.z = x, z
	c.hp, c.maxHp = def.hp, def.hp
	c.alive = true

	local model = buildScrap(c.kind, x, z, def.radius)
	model:SetAttribute("HP", c.hp)
	model:SetAttribute("MaxHP", c.maxHp)
	model:AddTag("Crate")
	model.Parent = crateFolder
	c.part = model
end

-- Applies damage to scrap; breaks it and schedules the respawn at 0 HP.
-- The attacker sees damage numbers, so players learn scrap can be destroyed.
function Pickups.damageCrate(c: Crate, amount: number, attacker: World.Entity?)
	if not c.alive then
		return
	end
	if attacker and attacker.player and amount > 0 then
		-- Negative target id: scrap, never confused with a robot's id.
		Remotes.HitFeedback:FireClient(attacker.player, -c.id, c.x, c.z, math.floor(amount + 0.5), "dealt")
	end
	c.hp -= amount
	if c.part then
		c.part:SetAttribute("HP", math.max(0, c.hp))
	end
	if c.hp <= 0 then
		c.alive = false
		local def = defOf(c.kind)
		if c.kind == "chest" then
			-- Coins burst out for anyone to grab (D73); the next chest comes minutes later.
			for _ = 1, rng:NextInteger(def.pieces[1], def.pieces[2]) do
				local a, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(2, def.radius + 3)
				Pickups.spawnCoin(c.x + math.cos(a) * r, c.z + math.sin(a) * r)
			end
		else
			drop(c.x, c.z, def.drops, def.radius + 2)
		end
		Remotes.Effect:FireAllClients("crate", c.x, c.z, def.size)
		if c.part then
			c.part:Destroy()
			c.part = nil
		end
		local wait = if type(def.respawn) == "table" then rng:NextNumber(def.respawn[1], def.respawn[2]) else def.respawn
		task.delay(wait, placeCrate, c)
	end
end

-- Collection -----------------------------------------------------------------

local function collectFor(e: World.Entity)
	local x, z = World.position(e)
	local r = e.stats.pickupRadius
	local r2 = r * r
	local c0x, c1x = math.floor((x - r) / CELL), math.floor((x + r) / CELL)
	local c0z, c1z = math.floor((z - r) / CELL), math.floor((z + r) / CELL)
	local userId = if e.player then e.player.UserId else 0
	for cx = c0x, c1x do
		for cz = c0z, c1z do
			local bucket = grid[cellKey(cx, cz)]
			if bucket then
				for _, o in bucket do
					if (o.x - x) ^ 2 + (o.z - z) ^ 2 <= r2 then
						if o.kind == "coin" then
							removeOrb(o, userId)
							World.hooks.addCoins(e, o.value) -- banked to the save at once (D38)
							continue
						end
						if Config.Pods[o.kind] then
							-- Healing pods wait on the floor until you are actually hurt.
							local full = e.hp >= e.stats.maxHp - 0.5
							if not (full and (o.kind == "health" or o.kind == "regen")) then
								removeOrb(o, userId)
								World.hooks.applyPod(e, o.kind)
							end
							continue
						end
						removeOrb(o, userId)
						World.hooks.addXp(e, o.value, "orb")
						if (e.build.stacks.mod_scavenger or 0) > 0 then
							e.hp = math.min(e.stats.maxHp, e.hp + Config.Orbs[o.kind].heal)
							World.hooks.markDirty(e)
						end
					end
				end
			end
		end
	end
end

local function chunked(list, size: number, fn)
	for i = 1, #list, size do
		fn(table.move(list, i, math.min(i + size - 1, #list), 1, {}))
	end
end

function Pickups.init()
	for zone in Config.Arena.Zones do
		zoneCounts[zone] = {}
	end

	crateFolder = Instance.new("Folder")
	crateFolder.Name = "Crates"
	crateFolder.Parent = Workspace
	for kind, def in Config.Crates do
		for _ = 1, def.count do
			local c: Crate = { id = #Pickups.crates + 1, kind = kind, x = 0, z = 0, radius = def.radius, hp = 0, maxHp = 0, part = nil, alive = false }
			table.insert(Pickups.crates, c)
			placeCrate(c)
		end
	end

	-- The coin chest: one at a time (D73).
	local chest: Crate = { id = #Pickups.crates + 1, kind = "chest", x = 0, z = 0, radius = Config.Coins.chest.radius, hp = 0, maxHp = 0, part = nil, alive = false }
	table.insert(Pickups.crates, chest)
	placeCrate(chest)
	Pickups.chest = chest

	-- Map coins: rare, topped up to mapMax one at a time (D38).
	task.spawn(function()
		local C = Config.Coins
		while true do
			task.wait(rng:NextNumber(C.mapEvery[1], C.mapEvery[2]))
			if mapCoins < C.mapMax then
				local x, z = Arena.randomPointInZone(C.zones[rng:NextInteger(1, #C.zones)], rng)
				Pickups.spawnCoin(x, z, true)
			end
		end
	end)

	-- Fill every zone at boot so the first players see a full arena.
	for zone, targets in Config.OrbTargets do
		for kind, n in targets do
			for _ = 1, n do
				local x, z = Arena.randomPointInZone(zone, rng)
				spawnOrb(kind, x, z, nil, zone)
			end
		end
	end
	table.clear(spawnedBatch)

	Remotes.ClientReady.OnServerEvent:Connect(function(player: Player)
		if not Guard.allow(player, "ClientReady") then
			return
		end
		local all = {}
		for _, o in orbs do
			table.insert(all, encode(o))
		end
		Remotes.OrbsSnapshot:FireClient(player, all)
	end)

	-- Pods: start full, then each kind tops up one pod every `every` seconds.
	for kind, pod in Config.Pods do
		for _ = 1, pod.count do
			local x, z = Arena.randomPointInZone(pod.zones[rng:NextInteger(1, #pod.zones)], rng)
			spawnOrb(kind, x, z)
		end
		task.spawn(function()
			while true do
				task.wait(pod.every)
				if (podCounts[kind] or 0) < pod.count then
					local x, z = Arena.randomPointInZone(pod.zones[rng:NextInteger(1, #pod.zones)], rng)
					spawnOrb(kind, x, z)
				end
			end
		end)
	end
	table.clear(spawnedBatch)

	-- Refill: each zone tops up toward its targets at OrbRefillPerSecond.
	task.spawn(function()
		local interval = 1 / Config.OrbRefillPerSecond
		while true do
			task.wait(interval)
			for zone, targets in Config.OrbTargets do
				for kind, n in targets do
					if (zoneCounts[zone][kind] or 0) < n then
						local x, z = Arena.randomPointInZone(zone, rng)
						spawnOrb(kind, x, z, nil, zone)
						break -- one orb per zone per tick
					end
				end
			end
		end
	end)

	-- Collection, despawn and batched replication every PickupInterval.
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < Config.PickupInterval then
			return
		end
		acc = 0
		for _, e in World.entities do
			if e.alive and e.player and e.root then
				collectFor(e)
			end
		end
		local now = os.clock()
		for _, o in orbs do
			if o.despawnAt and now >= o.despawnAt then
				removeOrb(o, 0)
			end
		end
		if #spawnedBatch > 0 then
			chunked(spawnedBatch, 200, function(chunk)
				Remotes.OrbsSpawned:FireAllClients(chunk)
			end)
			table.clear(spawnedBatch)
		end
		if #collectedBatch > 0 then
			chunked(collectedBatch, 400, function(chunk)
				Remotes.OrbsCollected:FireAllClients(chunk)
			end)
			table.clear(collectedBatch)
		end
	end)
end

-- Debug (/chest): a fresh, full chest at (x, z).
function Pickups.placeChestAt(x: number, z: number)
	local c = Pickups.chest
	if not c then
		return
	end
	local def = Config.Coins.chest
	c.x, c.z, c.hp, c.maxHp, c.alive = x, z, def.hp, def.hp, true
	local model = buildScrap("chest", x, z, def.radius)
	model:SetAttribute("HP", c.hp)
	model:SetAttribute("MaxHP", c.maxHp)
	model:AddTag("Crate")
	model.Parent = crateFolder
	c.part = model
end

-- Positions of live crates, used by the spawn finder.
function Pickups.cratePositions(): { Vector3 }
	local out = {}
	for _, c in Pickups.crates do
		if c.alive then
			table.insert(out, Vector3.new(c.x, 0, c.z))
		end
	end
	return out
end

return Pickups
