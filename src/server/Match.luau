-- Match progression for every player (GDD sections 10-14): spawn, XP and levels,
-- the offer queue and picks, kills, death, respawn, the HUD state push and the
-- leaderboard. All of it lives in server memory; nothing persists in Phase 1.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local XpCurve = require(Shared.XpCurve)
local MapQuery = require(Shared.MapQuery)
local Upgrades = require(Shared.Upgrades)
local OfferGenerator = require(Shared.OfferGenerator)
local Combat2D = require(Shared.Combat2D)
local Stats = require(Shared.Stats)
local Chassis = require(Shared.Chassis)
local World = require(script.Parent.World)
local Arena = require(script.Parent.Arena)
local Guard = require(script.Parent.Guard)
local Pickups = require(script.Parent.Pickups)
local RobotBuilder = require(script.Parent.RobotBuilder)
local Combat = require(script.Parent.Combat)
local Profiles = require(script.Parent.Profiles)

local Match = {}

local DUMMY_HP = 300

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- A fresh build for a robot: its base stats and tags come from the chassis.
local function emptyBuild(chassisId: string?)
	local c = Chassis.byId[chassisId or Chassis.default] or Chassis.byId[Chassis.default]
	-- c.skill: a built-in skill (the Bomber's bomb, D70); small: the Bomber's small form.
	return { stacks = {}, mounts = {}, skill = c.skill, skillRank = if c.skill then 1 else 0, chassis = c, tags = c.tags, small = false }
end

local function newEntity(player: Player?): World.Entity
	local e: World.Entity = {
		id = World.newId(),
		player = player,
		isDummy = player == nil,
		name = if player then player.DisplayName else "Dummy",
		generation = 0,
		model = nil,
		root = nil,
		humanoid = nil,
		alive = false,
		hp = Config.Robot.MaxHp,
		armor = 0,
		tempArmor = 0,
		tempArmorUntil = 0,
		regenUntil = 0,
		regenRate = 0,
		bonusHp = 0,
		bonusHpUntil = 0,
		burnUntil = 0,
		burnDps = 0,
		burnSourceId = nil,
		burnAcc = 0,
		pushGrantAt = -math.huge,
		pushRoom = 0,
		chassisId = Chassis.default,
		visualScale = 1,
		level = 0,
		xp = 0,
		totalXp = 0,
		score = 0,
		build = emptyBuild(),
		stats = Stats.compute(Config, emptyBuild(), 0),
		rng = Random.new(),
		offer = nil,
		pendingOffers = 0,
		nextOfferId = 0,
		aim = 0,
		firing = false,
		nextFire = {},
		liveProjectiles = 0,
		protectedUntil = 0,
		shieldUntil = 0,
		fieldUntil = 0,
		fieldRadius = 0,
		slowFactor = 1,
		rootedUntil = 0,
		netUntil = 0,
		stunnedUntil = 0,
		guardHp = 0,
		guardHitAt = -math.huge,
		skillReadyAt = 0,
		dashGrantAt = -math.huge,
		lastHitAt = -math.huge,
		lastDamagerId = nil,
		lastDamageAt = -math.huge,
		comebackTarget = nil,
		god = false,
		lastValidPos = nil,
		dirty = true,
	}
	return e
end

local function markDirty(e: World.Entity)
	e.dirty = true
end

-- How far the robot's main weapon reaches, measured from its centre.
local function attackRange(e: World.Entity): number
	local c = Chassis.byId[e.chassisId] or Chassis.byId[Chassis.default]
	return Stats.attackRange(Config, Upgrades.primaryFor(e.build.stacks) or c.primary, e.stats, e.build)
end

-- Stats, walk speed, HP clamp and the attributes clients read.
function Match.refreshStats(e: World.Entity)
	e.stats = Stats.compute(Config, e.build, e.level)
	if e.isDummy then
		e.stats.maxHp = DUMMY_HP
	elseif e.isBoss then
		-- Bosses (D74): giant, heavy, with HP set by the player count.
		local scale = e.bossScale or 3
		e.stats.maxHp = e.bossMaxHp or 1500
		e.stats.scale = scale
		e.stats.hitRadius = Config.Robot.HitboxRadius * scale
		e.stats.mass = 50
	end
	e.stats.maxHp += e.bonusHp -- Fortify Pod
	e.hp = math.min(e.hp, e.stats.maxHp)
	e.armor = math.min(e.armor, e.stats.maxArmor)
	Combat.applyWalkSpeed(e)
	local model = e.model
	if model then
		model:SetAttribute("MaxHP", e.stats.maxHp)
		model:SetAttribute("MaxArmor", e.stats.maxArmor)
		Combat.syncArmor(e)
		model:SetAttribute("Level", e.level)
		model:SetAttribute("Chassis", e.chassisId)
		model:SetAttribute("VisualScale", e.visualScale)
		-- Shown to everyone as a disc (hitbox) and a faint ring (attack range).
		model:SetAttribute("HitRadius", e.stats.hitRadius)
		model:SetAttribute("AttackRange", attackRange(e))
		model:SetAttribute("Ricochet", (e.build.stacks.mod_ricochet or 0) > 0)
		model:SetAttribute("Scavenger", (e.build.stacks.mod_scavenger or 0) > 0)
		Combat.syncHp(e)
	end
	markDirty(e)
end

local function setupModel(e: World.Entity, model: Model, color: Color3)
	model:SetAttribute("EntityId", e.id)
	model:SetAttribute("UserId", if e.player then e.player.UserId else 0)
	model:SetAttribute("DisplayName", e.name)
	model:SetAttribute("Color", color)
	model:SetAttribute("Protected", false)
	model:SetAttribute("Shield", false)
	model:SetAttribute("Field", 0) -- Null Field radius while active
	model:SetAttribute("Flipped", false) -- Flipper stun (D72)
	model:SetAttribute("HP", math.floor(e.hp + 0.5))
	e.model = model
	e.root = model.PrimaryPart
	e.humanoid = model:FindFirstChildOfClass("Humanoid")
	Match.refreshStats(e)
	model:AddTag("Robot")
end

local function randomColor(rng: Random): Color3
	local c = Config.Robot.Colors[rng:NextInteger(1, #Config.Robot.Colors)]
	return Color3.fromRGB(c[1], c[2], c[3])
end

-- Rebuilds the robot's visible parts. Only the cosmetic Body folder changes;
-- the physical root never resizes, so levelling up no longer glitches.
local function redress(e: World.Entity)
	local model = e.model
	if model then
		local color = model:GetAttribute("Color") or Color3.new(1, 1, 1)
		RobotBuilder.dress(model, e.build, color, e.visualScale, e.chassisId, e.level)
		model:SetAttribute("VisualScale", e.visualScale)
	end
end

-- Bomber forms (D70): small and fast after detonating, big again once healed.
function Match.setSmall(e: World.Entity, small: boolean)
	if e.build.small == small then
		return
	end
	e.build.small = small
	Match.refreshStats(e)
	e.visualScale = Stats.visualScale(Config, e.level) * Stats.bodySize(e.build)
	redress(e)
	markDirty(e)
end

-- Swaps the robot type in place (the /robot command; the garage in Phase 4).
function Match.setChassis(e: World.Entity, chassisId: string)
	local c = Chassis.byId[chassisId]
	if not c or c.comingSoon then
		return false
	end
	e.chassisId = chassisId
	e.build.chassis, e.build.tags = c, c.tags
	-- Drop what the new robot can't use: weapon variants, and cards outside its
	-- tags (e.g. guns on a melee robot, D69).
	local function fits(def): boolean
		if def.primary or (def.requiresTag and not table.find(c.tags, def.requiresTag)) then
			return false
		end
		if def.requiresAnyTag then
			for _, tag in def.requiresAnyTag do
				if table.find(c.tags, tag) then
					return true
				end
			end
			return false
		end
		return true
	end
	for _, def in Upgrades.list do
		if e.build.stacks[def.id] and not fits(def) then
			e.build.stacks[def.id] = nil
			local i = table.find(e.build.mounts, def.id)
			if i then
				table.remove(e.build.mounts, i)
			end
		end
	end
	-- Built-in skills come and go with the robot (the Bomber's bomb, D70).
	local current = e.build.skill and Upgrades.byId[e.build.skill]
	if c.skill then
		e.build.skill, e.build.skillRank = c.skill, 1
	elseif current and not fits(current) then
		e.build.skill, e.build.skillRank = nil, 0
	end
	e.build.small = false
	e.visualScale = Stats.visualScale(Config, e.level) * Stats.bodySize(e.build)
	local oldMax = e.stats.maxHp
	Match.refreshStats(e)
	e.hp = math.clamp(e.hp + e.stats.maxHp - oldMax, 1, e.stats.maxHp)
	Combat.syncHp(e)
	redress(e)
	return true
end

-- Spawn protection: a few seconds where nothing can hurt the robot.
local function protect(e: World.Entity)
	local gen = e.generation
	e.protectedUntil = now() + Config.Combat.SpawnProtection
	if e.model then
		e.model:SetAttribute("Protected", true)
	end
	task.delay(Config.Combat.SpawnProtection, function()
		if e.generation == gen and e.model then
			e.model:SetAttribute("Protected", false)
		end
	end)
end

-- Spawns (or respawns) a player at Level 0 at a spawn point of the current map.
-- keep = true (dying in a boss arena, Q2): same robot, level and build, full HP.
local function spawnPlayer(e: World.Entity, keep: boolean?)
	local player = e.player :: Player
	e.generation += 1
	local gen = e.generation
	e.alive = false
	if keep then
		e.build.small = false -- a Bomber comes back big
		e.stats = Stats.compute(Config, e.build, e.level)
		e.visualScale = Stats.visualScale(Config, e.level) * Stats.bodySize(e.build)
	else
		e.level, e.xp, e.totalXp, e.score = 0, 0, 0, 0
		-- The robot equipped in the Garage drives from each new spawn (D73).
		local saved = Profiles.data(player)
		if saved then
			e.chassisId = saved.equipped
		end
		e.build = emptyBuild(e.chassisId)
		e.stats = Stats.compute(Config, e.build, 0)
		e.visualScale = Stats.visualScale(Config, 0) * Stats.bodySize(e.build)
	end
	e.hp = e.stats.maxHp
	e.armor, e.tempArmor, e.tempArmorUntil = 0, 0, 0
	e.regenUntil, e.regenRate = 0, 0
	e.bonusHp, e.bonusHpUntil = 0, 0
	e.burnUntil, e.burnAcc, e.burnSourceId = 0, 0, nil
	if not keep then
		e.offer, e.pendingOffers = nil, 0
	end
	e.nextFire = {}
	e.firing = false
	e.shieldUntil, e.skillReadyAt = 0, 0
	e.fieldUntil, e.slowFactor, e.rootedUntil, e.netUntil, e.stunnedUntil = 0, 1, 0, 0, 0
	e.guardHp, e.guardHitAt = 0, -math.huge
	e.dashGrantAt, e.lastHitAt, e.lastDamageAt = -math.huge, -math.huge, -math.huge
	e.lastDamagerId = nil
	-- comebackTarget is kept on purpose: it was set by the death that led here.

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn("LoadCharacter failed for", player.Name, err)
		return
	end
	if World.byPlayer[player] ~= e or e.generation ~= gen then
		return -- left or respawned again while loading
	end
	local model = player.Character
	if not model or not model.PrimaryPart then
		warn("Character missing its root for", player.Name)
		return
	end

	local x, z = Arena.findSpawn(e.rng, Pickups.cratePositions())
	local y = Config.Robot.HipHeight + Config.Robot.RootSize[2] / 2
	model:PivotTo(CFrame.new(x, y, z))
	local color = randomColor(e.rng)
	RobotBuilder.dress(model, e.build, color, if keep then e.visualScale else 1, e.chassisId, if keep then e.level else 0)
	setupModel(e, model, color)
	if keep then
		model:SetAttribute("VisualScale", e.visualScale)
		e.hp = e.stats.maxHp
		Combat.syncHp(e)
	end

	pcall(function()
		(model.PrimaryPart :: BasePart):SetNetworkOwner(player)
	end)
	e.lastValidPos = Vector3.new(x, y, z)
	protect(e)
	e.alive = true
	markDirty(e)
end

-- Offers ----------------------------------------------------------------------

local function ensureOffer(e: World.Entity)
	if e.offer or e.pendingOffers <= 0 then
		return
	end
	e.nextOfferId += 1
	local rng = e.rng
	local cards = OfferGenerator.generate(Upgrades, e.build, e.level, function()
		return rng:NextNumber()
	end)
	e.offer = { id = e.nextOfferId, cards = cards }
	markDirty(e)
end

local function onLevelChanged(e: World.Entity)
	-- Level growth raises max HP (D26); the new HP arrives filled, not empty.
	local oldMax = e.stats.maxHp
	Match.refreshStats(e)
	e.hp = math.min(e.stats.maxHp, e.hp + math.max(0, e.stats.maxHp - oldMax))
	Combat.syncHp(e)
	local scale = Stats.visualScale(Config, e.level) * Stats.bodySize(e.build)
	local dressed = (if e.model then e.model:GetAttribute("DressedLevel") else 0) :: number?
	local bandChanged = math.floor(e.level / 20) ~= math.floor((dressed or 0) / 20) -- level-band look (Lv 20, 40, ...)
	if scale ~= e.visualScale or bandChanged then
		e.visualScale = scale
		redress(e)
	end
end

function Match.addXp(e: World.Entity, amount: number, source: string)
	if not e.alive or not e.player or amount <= 0 then
		return
	end
	if e.comebackTarget and (source == "orb") then
		if e.totalXp < e.comebackTarget then
			amount *= Config.Death.ComebackMultiplier
		end
	end
	amount = math.floor(amount + 0.5)
	e.totalXp += amount
	e.score += amount
	if e.comebackTarget and e.totalXp >= e.comebackTarget then
		e.comebackTarget = nil
	end
	local level, xp, gained = XpCurve.add(e.level, e.xp, amount)
	e.xp = xp
	if gained > 0 then
		e.pendingOffers += XpCurve.offersFor(e.level, level) -- cards on even levels only (D26)
		e.level = level
		onLevelChanged(e)
		ensureOffer(e)
	end
	markDirty(e)
end

-- Applies one picked card to the build.
function Match.applyCard(e: World.Entity, card)
	local b = e.build
	local id = card.id
	if card.category == "Stat" or card.category == "Modifier" then
		b.stacks[id] = (b.stacks[id] or 0) + 1
		if id == "stat_hp" then
			e.hp += Config.StatPerStack.stat_hp
		end
	elseif card.category == "Weapon" then
		if (b.stacks[id] or 0) == 0 then
			table.insert(b.mounts, id)
		end
		b.stacks[id] = (b.stacks[id] or 0) + 1
	elseif card.category == "Skill" then
		if b.skill == id then
			b.skillRank += 1
		else
			b.skill = id
			b.skillRank = 1
			e.skillReadyAt = 0
			e.shieldUntil = 0
			e.fieldUntil = 0
			if e.model then
				e.model:SetAttribute("Shield", false)
				e.model:SetAttribute("Field", 0)
			end
		end
	elseif id == "fb_supply" then
		local x, z = World.position(e)
		World.hooks.spawnPod("health", x + 4, z) -- health only comes from the map (D33)
	elseif id == "fb_reinforce" then
		b.stacks[id] = (b.stacks[id] or 0) + 1
		e.hp += Config.StatPerStack.fb_reinforce_hp
	elseif id == "fb_cache" then
		Match.addXp(e, math.floor(XpCurve.toNext(e.level) * Config.StatPerStack.fb_cache_fraction), "cache")
	end
	local oldMaxArmor = e.stats.maxArmor
	Match.refreshStats(e)
	if id == "stat_armor" then -- new plating arrives fully charged
		e.armor = math.min(e.stats.maxArmor, e.armor + e.stats.maxArmor - oldMaxArmor)
		Combat.syncArmor(e)
	end
	redress(e)
end

local function onPick(player: Player, offerId: any, cardIndex: any)
	if not Guard.allow(player, "PickUpgrade") then
		return
	end
	local e = World.byPlayer[player]
	if not e or not e.alive or not e.offer then
		return
	end
	if type(offerId) ~= "number" or type(cardIndex) ~= "number" or cardIndex % 1 ~= 0 then
		return
	end
	if offerId ~= e.offer.id or cardIndex < 1 or cardIndex > #e.offer.cards then
		return
	end
	local card = e.offer.cards[cardIndex]
	e.offer = nil
	e.pendingOffers -= 1
	Match.applyCard(e, card)
	ensureOffer(e) -- generated only now, so it reflects the pick just made
	markDirty(e)
end

-- Kills and death -------------------------------------------------------------

function Match.onKill(victim: World.Entity, killer: World.Entity?)
	if not victim.alive then
		return
	end
	victim.alive = false
	victim.firing = false
	local x, z = World.position(victim)
	Remotes.Effect:FireAllClients("death", x, z, 6 * victim.stats.scale)

	local killerName = "the arena"
	if killer and killer ~= victim then
		killerName = killer.name
	end
	if killer and killer ~= victim and killer.player then
		Match.addXp(killer, Combat2D.killReward(victim.totalXp, victim.level, killer.level, Config.Death.KillShare, Config.Death.KillMinimum), "kill")
	end

	if victim.model then
		victim.model:Destroy()
	end
	victim.model, victim.root, victim.humanoid = nil, nil, nil

	if victim.isDummy then
		World.entities[victim.id] = nil
		Remotes.KillFeed:FireAllClients(killerName, victim.name, victim.level)
		return
	end
	if victim.isBoss then
		World.entities[victim.id] = nil
		Remotes.KillFeed:FireAllClients(killerName, victim.name, victim.level)
		World.hooks.bossDied(victim, x, z) -- rewards everyone who hit it (D39)
		return
	end

	-- Dying in a boss arena (Q2): keep your level and build, lose a quarter of the XP
	-- toward your next level, drop nothing, and come back in the arena.
	if Arena.isArena() and victim.player then
		local lost = math.min(victim.xp, math.floor(Config.Maps.arenaDeath.xpLoss * XpCurve.toNext(victim.level)))
		victim.xp -= lost
		victim.totalXp = math.max(0, victim.totalXp - lost)
		Remotes.KillFeed:FireAllClients(killerName, victim.name, victim.level)
		local arenaPlayer = victim.player :: Player
		Remotes.Death:FireClient(arenaPlayer, {
			killerName = killerName,
			killerLevel = if killer then killer.level else 0,
			level = victim.level,
			score = victim.score,
			respawnAt = now() + Config.Maps.arenaDeath.respawn,
			keepsLevel = true,
		})
		markDirty(victim)
		local arenaGen = victim.generation
		task.delay(Config.Maps.arenaDeath.respawn, function()
			if World.byPlayer[arenaPlayer] == victim and victim.generation == arenaGen then
				spawnPlayer(victim, Arena.isArena()) -- the fight may have ended meanwhile
			end
		end)
		return
	end

	local count, value = Combat2D.deathSpill(victim.totalXp, victim.level, Config.Death.SpillFraction)
	if count > 0 then
		Pickups.spill(x, z, count, value)
	end
	if victim.totalXp > 0 then
		victim.comebackTarget = math.floor(victim.totalXp * Config.Death.ComebackTargetFraction)
	end

	Remotes.KillFeed:FireAllClients(killerName, victim.name, victim.level)
	local player = victim.player :: Player
	Remotes.Death:FireClient(player, {
		killerName = killerName,
		killerLevel = if killer then killer.level else 0,
		level = victim.level,
		score = victim.score,
		respawnAt = now() + Config.Combat.RespawnDelay,
	})
	victim.offer, victim.pendingOffers = nil, 0
	markDirty(victim)

	local gen = victim.generation
	task.delay(Config.Combat.RespawnDelay, function()
		if World.byPlayer[player] == victim and victim.generation == gen then
			spawnPlayer(victim)
		end
	end)
end

-- A map swap (D81): every living robot (players and dummies) moves to a spawn point
-- of the new map, spread out from each other, with fresh spawn protection.
function Match.placeEveryone(rng: Random)
	local placed: { { number } } = {}
	local map = Arena.map()
	local y = Config.Robot.HipHeight + Config.Robot.RootSize[2] / 2
	for _, e in World.entities do
		if e.alive and e.model and not e.isBoss then
			local x, z = MapQuery.pickSpawn(map, placed, Config.Arena.SpawnMinEnemyDistance, rng:NextInteger(1, #map.spawns))
			table.insert(placed, { x, z })
			e.model:PivotTo(CFrame.new(x, y, z))
			e.lastValidPos = Vector3.new(x, y, z)
			e.pushGrantAt = -math.huge
			protect(e)
		end
	end
end

export type DummyOptions = {
	armor: number?, -- Armor Plating stacks
	chassis: string?,
	level: number?,
	stacks: { [string]: number }?,
	mounts: { string }?,
	skill: string?,
	name: string?,
}

-- A stationary target that never shoots back. Options build a sample robot
-- for /dummy armor and /showcase.
function Match.spawnDummy(x: number, z: number, opts: DummyOptions?)
	local o: DummyOptions = opts or {}
	local e = newEntity(nil)
	e.chassisId = o.chassis or Chassis.default
	e.build = emptyBuild(e.chassisId)
	if o.stacks then
		for id, n in o.stacks do
			e.build.stacks[id] = n
		end
	end
	if o.armor and o.armor > 0 then
		e.build.stacks.stat_armor = o.armor
	end
	if o.mounts then
		for _, weaponId in o.mounts do
			table.insert(e.build.mounts, weaponId)
			e.build.stacks[weaponId] = e.build.stacks[weaponId] or 1
		end
	end
	if o.skill then
		e.build.skill, e.build.skillRank = o.skill, 1
	end
	e.level = o.level or 0
	e.name = o.name or "Dummy"
	e.visualScale = Stats.visualScale(Config, e.level) * Stats.bodySize(e.build)
	e.hp = DUMMY_HP
	local model = RobotBuilder.buildDummy(x, z, e.build, e.visualScale, e.chassisId, e.level)
	World.entities[e.id] = e
	setupModel(e, model, Color3.fromRGB(118, 122, 116)) -- bare primer grey
	e.hp = DUMMY_HP
	e.armor = e.stats.maxArmor
	Combat.syncHp(e)
	Combat.syncArmor(e)
	e.alive = true
end

-- A boss (Phase 4b, D74): a giant robot body that the Bosses service moves and
-- fights with. It is an entity, so every weapon, net, trap and flip works on it.
function Match.spawnBoss(def, x: number, z: number, maxHp: number): World.Entity
	local e = newEntity(nil)
	e.isDummy = false
	e.isBoss = true
	e.hitBy = {}
	e.bossScale = def.scale
	e.bossMaxHp = maxHp
	e.chassisId = def.chassis
	e.build = emptyBuild(e.chassisId)
	for id, n in def.stacks or {} do
		e.build.stacks[id] = n
	end
	for _, weaponId in def.mounts or {} do
		table.insert(e.build.mounts, weaponId)
		e.build.stacks[weaponId] = 3
	end
	e.level = 100 -- the gold Lv 100 look; bosses give no underdog bonus
	e.name = def.name
	e.visualScale = def.scale
	e.hp = maxHp
	local model = RobotBuilder.buildDummy(x, z, e.build, e.visualScale, e.chassisId, e.level)
	model.Name = def.name
	World.entities[e.id] = e
	setupModel(e, model, Color3.fromRGB(def.color[1], def.color[2], def.color[3]))
	e.hp = maxHp
	e.armor = e.stats.maxArmor
	Combat.syncHp(e)
	Combat.syncArmor(e)
	model:SetAttribute("BossName", def.name)
	model:AddTag("Boss")
	e.alive = true
	return e
end

-- Removes every debug dummy (the /clear command).
function Match.removeDummies()
	for id, e in World.entities do
		if e.isDummy then
			e.alive = false
			if e.model then
				e.model:Destroy()
			end
			World.entities[id] = nil
		end
	end
end

-- HUD state -------------------------------------------------------------------

local function skillCooldown(e: World.Entity): number
	local skill = e.build.skill
	local def = skill and Config.Skills[skill]
	if def then
		return def.cooldown + (def.cooldownPerRank or 0) * (e.build.skillRank - 1)
	end
	return 0
end

local function pushState(e: World.Entity)
	local player = e.player
	if not player then
		return
	end
	local offer = nil
	if e.offer then
		local cards = {}
		for _, c in e.offer.cards do
			table.insert(cards, {
				id = c.id,
				kind = c.kind,
				rank = c.rank,
				replaces = c.replaces,
				category = c.category,
				rarity = c.rarity,
				name = c.name,
				text = c.text,
			})
		end
		offer = { id = e.offer.id, cards = cards }
	end
	local comeback = nil
	if e.comebackTarget and e.totalXp < e.comebackTarget then
		comeback = { mult = Config.Death.ComebackMultiplier, progress = e.totalXp / e.comebackTarget }
	end
	local saved = Profiles.data(player)
	Remotes.State:FireClient(player, {
		alive = e.alive,
		level = e.level,
		xp = e.xp,
		xpNeed = if e.level >= Config.MaxLevel then 0 else XpCurve.toNext(e.level),
		score = e.score,
		maxHp = e.stats.maxHp,
		comeback = comeback,
		skill = e.build.skill,
		skillRank = e.build.skillRank,
		skillReadyAt = e.skillReadyAt,
		skillCooldown = skillCooldown(e),
		skillNote = if e.build.small then `Heal to {math.floor(Config.Bomber.rebuildAt * 100)}%` else nil,
		offer = offer,
		pending = e.pendingOffers,
		mounts = e.build.mounts,
		-- Garage (D73): the saved coins and robots.
		coins = if saved then saved.coins else 0,
		owned = if saved then saved.owned else { rookie = true },
		equipped = if saved then saved.equipped else e.chassisId,
	})
end

-- Boot ------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if World.byPlayer[player] then
		return
	end
	-- The save loads first, so you spawn in the robot you equipped (D73).
	task.spawn(function()
		if not Profiles.load(player) or player.Parent ~= Players or World.byPlayer[player] then
			return
		end
		local e = newEntity(player)
		World.entities[e.id] = e
		World.byPlayer[player] = e
		spawnPlayer(e)
	end)
end

function Match.init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		Profiles.release(player)
		local e = World.byPlayer[player]
		if not e then
			return
		end
		World.byPlayer[player] = nil
		World.entities[e.id] = nil
		e.alive = false
		e.generation += 1
		if e.model then
			e.model:Destroy()
		end
	end)

	Remotes.PickUpgrade.OnServerEvent:Connect(onPick)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		for _, e in World.entities do
			if e.dirty and e.player then
				e.dirty = false
				pushState(e)
			end
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			local rows = {}
			for player, e in World.byPlayer do
				table.insert(rows, { name = e.name, score = e.score, level = e.level, userId = player.UserId })
			end
			table.sort(rows, function(a, b)
				return a.score > b.score
			end)
			Remotes.Leaderboard:FireAllClients(rows)
		end
	end)
end

return Match
