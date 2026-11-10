-- Class attachment pools (D69): gun robots get guns, melee robots get pure melee
-- gear, special robots (Scorcher) get close-range gear.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

local GUNS = { "wpn_gatling", "wpn_rocket", "wpn_railgun" }
local MELEE = { "wpn_traps", "wpn_shieldgen", "wpn_spikeram", "wpn_sidesaw" }

local function mountsFor(chassisId: string): { [string]: boolean }
	local b = { stacks = {}, mounts = {}, skill = nil, skillRank = 0, tags = Chassis.byId[chassisId].tags }
	local out = {}
	for _, c in OfferGenerator.eligible(Upgrades, b, Config.MaxLevel) do
		if c.category == "Weapon" then
			out[c.id] = true
		end
	end
	return out
end

return function(test)
	test("melee robots never get guns; gun robots never get melee gear", function()
		local brawler, rookie, bombard = mountsFor("brawler"), mountsFor("rookie"), mountsFor("bombard")
		for _, id in GUNS do
			assert(not brawler[id], "brawler offered " .. id)
			assert(rookie[id] and bombard[id], "gun robots should get " .. id)
		end
		for _, id in MELEE do
			assert(brawler[id], "brawler should get " .. id)
			assert(not rookie[id] and not bombard[id], "gun robot offered " .. id)
		end
		assert(not brawler.wpn_shock, "shock is not melee")
	end)

	test("Scorcher gets close-range gear, no long-range guns", function()
		local s = mountsFor("scorcher")
		for _, id in GUNS do
			assert(not s[id], "scorcher offered " .. id)
		end
		assert(s.wpn_shock and s.wpn_traps and s.wpn_shieldgen and s.wpn_spikeram)
	end)

	test("every robot can fill all 3 mount sockets", function()
		for _, c in Chassis.list do
			if not c.comingSoon then
				local n = 0
				for _ in mountsFor(c.id) do
					n += 1
				end
				assert(n >= #Config.MountSockets, `{c.id} has only {n} mounts`)
			end
		end
	end)

	test("active mounts have damage and a fire rate; passive ones are flagged (crash fix, D72)", function()
		local Stats = require("../src/shared/Stats")
		for _, key in { "gatling", "rocket", "railgun", "shock", "spikeram", "sidesaw", "traps", "shieldgen" } do
			local def = Config.Weapons[key]
			if not def.passive then
				local damage, rate = Stats.weaponAtRank(def, 5)
				assert(type(damage) == "number" and type(rate) == "number" and rate > 0, key .. " needs damage and fireRate")
			end
		end
		assert(Config.Weapons.shieldgen.passive, "Shield Generator never fires")
	end)

	test("every mount card has its numbers in Config.Weapons", function()
		local key = { wpn_gatling = "gatling", wpn_rocket = "rocket", wpn_railgun = "railgun", wpn_shock = "shock", wpn_spikeram = "spikeram", wpn_traps = "traps", wpn_shieldgen = "shieldgen", wpn_sidesaw = "sidesaw" }
		for _, def in Upgrades.list do
			if def.category == "Weapon" then
				assert(key[def.id] and Config.Weapons[key[def.id]], def.id .. " has no Config.Weapons entry")
			end
		end
	end)
end
