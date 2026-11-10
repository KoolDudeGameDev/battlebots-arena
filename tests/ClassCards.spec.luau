-- Stat cards that fit each robot (D71): no Fire Rate for robots that attack at a
-- fixed pace, card wording per weapon, Wider Flames for the Scorcher.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

local function cards(chassisId: string): { [string]: any }
	local c = Chassis.byId[chassisId]
	local b = { stacks = {}, mounts = {}, skill = c.skill, skillRank = if c.skill then 1 else 0, tags = c.tags }
	local out = {}
	for _, card in OfferGenerator.eligible(Upgrades, b, Config.MaxLevel) do
		out[card.id] = card
	end
	return out
end

return function(test)
	test("Fire Rate only for robots that shoot (guns and nets)", function()
		assert(cards("rookie").stat_firerate and cards("bombard").stat_firerate and cards("bomber").stat_firerate)
		assert(not cards("brawler").stat_firerate, "melee swings at a fixed pace")
		assert(not cards("scorcher").stat_firerate, "the flame sprays at a fixed pace")
	end)

	test("the Range card is worded for each weapon", function()
		local gun, melee, flame = cards("rookie").stat_range.text, cards("brawler").stat_range.text, cards("scorcher").stat_range.text
		assert(gun ~= melee and melee ~= flame and gun ~= flame, "three different wordings")
		assert(melee:lower():find("reach"), melee)
		assert(flame:lower():find("flame"), flame)
	end)

	test("Wider Flames: Scorcher only, and it widens the cone", function()
		assert(cards("scorcher").stat_cone and not cards("rookie").stat_cone and not cards("brawler").stat_cone)
		local s0 = Stats.compute(Config, { stacks = {}, chassis = Chassis.byId.scorcher }, 0)
		local s3 = Stats.compute(Config, { stacks = { stat_cone = 3 }, chassis = Chassis.byId.scorcher }, 0)
		assert(s3.coneBonus == 3 * Config.StatPerStack.stat_cone and s0.coneBonus == 0)
	end)

	test("Flipper: a defensive skill for everyone but the Bomber (D72)", function()
		local S = Config.Skills.skl_flipper
		assert(Upgrades.byId.skl_flipper and Upgrades.byId.skl_flipper.category == "Skill")
		assert(S and S.flipTime > 0 and S.cooldown > S.flipTime and S.reach > 0)
		assert(cards("brawler").skl_flipper and cards("rookie").skl_flipper)
		assert(not cards("bomber").skl_flipper, "the Bomber's bomb is its only skill")
	end)

	test("the net opens up wide in flight (D72)", function()
		local n = Config.Weapons.netgun
		assert(n.openRadius >= 4 and n.openRadius > n.radius and n.openPerStud > 0)
	end)

	test("Battle Axe sweeps all the way round; the net is wide", function()
		assert(Config.Weapons.axe.arcDegrees == 360)
		assert(Config.Weapons.hammer.smashRadius, "the Sledgehammer smashes an area in front")
		assert(not Config.Weapons.slam, "the hammer is a main weapon only, not an attachment (D72)")
	end)
end
