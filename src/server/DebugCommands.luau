-- Chat commands for testing. Open to everyone in Studio and to
-- Config.DebugUserIds in live servers. Type /help in game for the list.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local XpCurve = require(Shared.XpCurve)
local Upgrades = require(Shared.Upgrades)
local OfferGenerator = require(Shared.OfferGenerator)
local Chassis = require(Shared.Chassis)
local Condition = require(Shared.Condition)
local World = require(script.Parent.World)
local Match = require(script.Parent.Match)
local Combat = require(script.Parent.Combat)
local Pickups = require(script.Parent.Pickups)
local Profiles = require(script.Parent.Profiles)
local Bosses = require(script.Parent.Bosses)

local DebugCommands = {}

local HELP = {
	"/lvl 50 — set your level (queues the offers)",
	"/xp 500 — add XP",
	"/give <id> — apply an upgrade, e.g. stat_barrels, wpn_railgun, skl_nullfield, var_laser, var_axe, var_hammer",
	"/god — toggle taking no damage",
	"/dummy — target robot  ·  /dummy armor — with 3 armor stacks  ·  /dummy 5 — five in a row",
	"/clear — remove all dummies",
	"/heal — full health  ·  /hurt 40 — take 40 damage",
	"/pod health | regen | armor | fortify — drop a booster pod in front of you",
	"/robot rookie | brawler | scorcher | bombard | bomber — swap your robot (drops gear it can't use)",
	"/showcase — line up sample robots for a visual check",
	"/coins 500 — add coins to your save  ·  /resetprofile — back to a new player",
	"/coin — drop a coin  ·  /chest — move the coin chest in front of you (and refill it)",
	"/boss inferno | forge | grinder — go to that boss's arena now  ·  /boss — flow status",
	"/killboss — beat the boss (rewards, then its biome)  ·  /hazard on | off — this map's hazard",
	"/map grassland | forge_highlands | inferno_fields | grinder_scrapyard | arena_forge | arena_inferno | arena_grinder — load a map now",
}

local function allowed(userId: number): boolean
	return RunService:IsStudio() or table.find(Config.DebugUserIds, userId) ~= nil
end

local function notify(e: World.Entity, text: string)
	if e.player then
		Remotes.Notice:FireClient(e.player, text)
	end
end

-- A point `distance` studs in front of the robot.
local function ahead(e: World.Entity, distance: number): (number, number)
	local root = e.root :: BasePart
	local p = root.Position + root.CFrame.LookVector * distance
	return p.X, p.Z
end

local handlers = {}

handlers["/help"] = function(e: World.Entity)
	for _, line in HELP do
		notify(e, line)
	end
end

handlers["/lvl"] = function(e: World.Entity, arg: string?)
	local target = math.clamp(tonumber(arg) or 0, 0, Config.MaxLevel)
	if target <= e.level then
		return
	end
	local need = XpCurve.totalTo(target) - XpCurve.totalTo(e.level) - e.xp
	World.hooks.addXp(e, need, "debug")
end

handlers["/xp"] = function(e: World.Entity, arg: string?)
	World.hooks.addXp(e, math.max(0, tonumber(arg) or 0), "debug")
end

handlers["/give"] = function(e: World.Entity, arg: string?)
	if not arg then
		return
	end
	for _, card in OfferGenerator.eligible(Upgrades, e.build, Config.MaxLevel) do
		if card.id == arg then
			Match.applyCard(e, card)
			return
		end
	end
	local def = Upgrades.byId[arg]
	if def and def.category == "Fallback" then
		Match.applyCard(e, { id = def.id, category = def.category })
	else
		notify(e, "Can't give '" .. arg .. "' (unknown, or already maxed)")
	end
end

handlers["/dummy"] = function(e: World.Entity, arg: string?)
	if arg == "armor" then
		local x, z = ahead(e, 15)
		World.hooks.spawnDummy(x, z, { armor = 3, name = "Armored dummy" })
		return
	end
	local count = math.clamp(tonumber(arg) or 1, 1, 10)
	local root = e.root :: BasePart
	local right = root.CFrame.RightVector
	for i = 1, count do
		local x, z = ahead(e, 15)
		local offset = (i - (count + 1) / 2) * 9
		World.hooks.spawnDummy(x + right.X * offset, z + right.Z * offset)
	end
end

handlers["/clear"] = function()
	Match.removeDummies()
end

handlers["/robot"] = function(e: World.Entity, arg: string?)
	if not arg or not Match.setChassis(e, arg) then
		local names = {}
		for _, c in Chassis.list do
			if not c.comingSoon then
				table.insert(names, c.id)
			end
		end
		notify(e, "Robots: " .. table.concat(names, ", "))
	end
end

-- Lines up sample robots for a visual check of every robot type, level band and mount.
handlers["/showcase"] = function(e: World.Entity)
	Match.removeDummies()
	local samples = {
		{ name = "Rookie Lv 0" },
		{ name = "Rookie Lv 50 offence", level = 50, stacks = { stat_damage = 6, stat_firerate = 6, stat_range = 6, stat_barrels = 2 }, mounts = { "wpn_gatling", "wpn_railgun" } },
		{ name = "Rookie Lv 100 tank", level = 100, armor = 5, stacks = { stat_hp = 8, stat_speed = 6, stat_pickup = 4 }, mounts = { "wpn_shock", "wpn_rocket", "wpn_gatling" }, skill = "skl_earthwall" },
		{ name = "Rookie spreader", level = 30, stacks = { stat_barrels = 4, mod_spread = 1 } },
		{ name = "Brawler melee kit", chassis = "brawler", level = 20, mounts = { "wpn_sidesaw", "wpn_shieldgen", "wpn_traps" } },
		{ name = "Minotaur Brawler", chassis = "brawler", level = 40, mounts = { "wpn_spikeram", "wpn_traps" } },
		{ name = "Scorcher kit", chassis = "scorcher", level = 40, mounts = { "wpn_shock", "wpn_traps", "wpn_shieldgen" } },
		{ name = "Bombard", chassis = "bombard", level = 60, stacks = { stat_barrels = 2 } },
		{ name = "Bomber", chassis = "bomber", level = 20, mounts = { "wpn_traps" } },
		{ name = "Laser Gun", level = 20, stacks = { var_laser = 1 } },
		{ name = "Battle Axe", chassis = "brawler", level = 20, stacks = { var_axe = 1 } },
		{ name = "Sledgehammer", chassis = "brawler", level = 20, stacks = { var_hammer = 1 } },
		{ name = "All mounts rank 5", level = 80, stacks = { wpn_gatling = 5, wpn_rocket = 5, wpn_railgun = 5 }, mounts = { "wpn_gatling", "wpn_rocket", "wpn_railgun" } },
	}
	local root = e.root :: BasePart
	local right = root.CFrame.RightVector
	for i, sample in samples do
		local x, z = ahead(e, 22)
		local offset = (i - (#samples + 1) / 2) * 11
		World.hooks.spawnDummy(x + right.X * offset, z + right.Z * offset, sample)
	end
	notify(e, "Showcase: " .. #samples .. " sample robots. /clear removes them.")
end

handlers["/coins"] = function(e: World.Entity, arg: string?)
	if e.player then
		Profiles.addCoins(e.player, math.clamp(tonumber(arg) or 100, 1, 100000))
	end
end

handlers["/resetprofile"] = function(e: World.Entity)
	if e.player then
		Profiles.reset(e.player)
		notify(e, "Profile reset: 0 coins, Rookie only.")
	end
end

handlers["/coin"] = function(e: World.Entity)
	local x, z = ahead(e, 8)
	Pickups.spawnCoin(x, z)
end

handlers["/chest"] = function(e: World.Entity)
	local c = Pickups.chest
	if not c then
		return
	end
	if c.part then
		c.part:Destroy()
		c.part = nil
	end
	local x, z = ahead(e, 14)
	Pickups.placeChestAt(x, z)
end

handlers["/boss"] = function(e: World.Entity, arg: string?)
	if not arg then
		notify(e, Bosses.status())
	elseif not Bosses.summon(arg) then
		notify(e, "Bosses: inferno, forge, grinder (only from the grassland)")
	end
end

handlers["/killboss"] = function(e: World.Entity)
	Bosses.killActive(e)
end

handlers["/hazard"] = function(e: World.Entity, arg: string?)
	if arg == "off" then
		Bosses.stopHazard()
	elseif arg == "on" then
		notify(e, Bosses.startMapHazard() or "This map has no hazard")
	else
		notify(e, "/hazard on | off")
	end
end

handlers["/map"] = function(e: World.Entity, arg: string?)
	if not arg or not Bosses.debugLoad(arg) then
		notify(e, "Maps: grassland, forge_highlands, inferno_fields, grinder_scrapyard, arena_forge, arena_inferno, arena_grinder")
	end
end

handlers["/god"] = function(e: World.Entity)
	e.god = not e.god
	notify(e, "God mode " .. (if e.god then "ON" else "OFF"))
end

handlers["/heal"] = function(e: World.Entity)
	Condition.set(e.condition, { hp = e.stats.maxHp })
	Combat.syncHp(e)
end

handlers["/hurt"] = function(e: World.Entity, arg: string?)
	local x, z = World.position(e)
	local wasGod = e.god
	e.god = false
	Combat.damage(e, math.max(1, tonumber(arg) or 20), nil, false, x, z)
	e.god = wasGod
end

handlers["/pod"] = function(e: World.Entity, arg: string?)
	if not arg or not Config.Pods[arg] then
		notify(e, "Pods: health, regen, armor, fortify")
		return
	end
	local x, z = ahead(e, 8)
	Pickups.spawnPod(arg, x, z)
end

function DebugCommands.init()
	for alias, handler in handlers do
		local command = Instance.new("TextChatCommand")
		command.Name = "Debug" .. alias:sub(2)
		command.PrimaryAlias = alias
		command.Triggered:Connect(function(source: TextSource, text: string)
			if not allowed(source.UserId) then
				return
			end
			local player = Players:GetPlayerByUserId(source.UserId)
			local e = player and World.byPlayer[player]
			if not e or not e.alive then
				return
			end
			local arg = text:match("^%S+%s+(%S+)")
			handler(e, arg)
		end)
		command.Parent = TextChatService
	end
end

return DebugCommands
