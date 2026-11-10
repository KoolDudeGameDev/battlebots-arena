local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Combat2D = require("../src/shared/Combat2D")
local Stats = require("../src/shared/Stats")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function build(tags)
	return { stacks = {}, mounts = {}, skill = nil, skillRank = 0, tags = tags }
end

local function offered(b, level: number, id: string): boolean
	for _, c in OfferGenerator.eligible(Upgrades, b, level) do
		if c.id == id then
			return true
		end
	end
	return false
end

return function(test)
	test("every playable robot has a real primary weapon", function()
		local playable = 0
		for _, c in Chassis.list do
			if not c.comingSoon then
				playable += 1
				assert(c.primary and Config.Weapons[c.primary.weapon], c.id .. " primary weapon missing")
				assert(c.hp > 0 and c.speed > 0, c.id .. " stats")
			end
		end
		assert(playable == 5, "Rookie, Brawler, Scorcher, Bombard, Bomber")
		assert(Chassis.byId.rookie.price == 0 and Chassis.byId[Chassis.default], "free default robot")
	end)

	test("every robot attacks at its own speed", function()
		local seen = {}
		for _, c in Chassis.list do
			if c.primary then
				local rate = Config.Weapons[c.primary.weapon].fireRate
				assert(not seen[rate], "two robots share attack speed " .. rate)
				seen[rate] = true
			end
		end
	end)

	test("robot base stats flow into Stats", function()
		local c = Chassis.byId.brawler
		local s = Stats.compute(Config, { stacks = {}, chassis = c }, 0)
		assert(s.maxHp == c.hp and s.speed == c.speed and s.maxArmor == c.armor and s.mass == c.mass)
		assert(near(s.hitRadius, Config.Robot.HitboxRadius * c.size))
		assert(s.deflectChance == 0, "built-in armor does not deflect; only Armor Plating does")
	end)

	test("built-in armor grows with level like HP, and Armor Plating adds on top", function()
		local c = Chassis.byId.brawler
		local s = Stats.compute(Config, { stacks = { stat_armor = 1 }, chassis = c }, 50)
		assert(near(s.maxArmor, c.armor * 2 + Config.Armor.firstStack), "armor " .. s.maxArmor)
	end)

	test("recoil: ranged robots slow down while firing, close-range robots do not", function()
		local rookie = Stats.compute(Config, { stacks = {}, chassis = Chassis.byId.rookie }, 0)
		local brawler = Stats.compute(Config, { stacks = {}, chassis = Chassis.byId.brawler }, 0)
		assert(Stats.moveSpeed(rookie, false) == rookie.speed)
		assert(Stats.moveSpeed(rookie, true) < rookie.speed)
		assert(Stats.moveSpeed(brawler, true) == brawler.speed)
	end)

	test("splash falls off from 100% to 40% at the rim", function()
		assert(near(Combat2D.splashFactor(0, 9, 0.4), 1))
		assert(near(Combat2D.splashFactor(9, 9, 0.4), 0.4))
		assert(near(Combat2D.splashFactor(4.5, 9, 0.4), 0.7))
		assert(near(Combat2D.splashFactor(20, 9, 0.4), 0.4), "clamped beyond the rim")
	end)

	test("knockback shrinks with mass (scale cubed)", function()
		assert(near(Combat2D.knockback(14, 1), 14))
		assert(near(Combat2D.knockback(14, 1.4), 14 / 2.744))
		assert(near(Combat2D.knockback(14, 1, 2), 7), "a robot twice as heavy moves half as far")
	end)

	test("rockets accelerate to their top speed", function()
		local w = Config.Weapons.launcher
		local speed = w.launchSpeed
		speed = Combat2D.rocketSpeed(speed, w.accel, w.speed, 0.1)
		assert(near(speed, 56), tostring(speed))
		for _ = 1, 20 do
			speed = Combat2D.rocketSpeed(speed, w.accel, w.speed, 0.1)
		end
		assert(speed == w.speed, "capped")
	end)

	test("melee arc and flame cone checks", function()
		local half = math.rad(50)
		assert(Combat2D.inArc(0, 0, 0, half, 5.5, 5, 0, 3), "straight ahead")
		assert(not Combat2D.inArc(0, 0, 0, half, 5.5, -5, 0, 3), "behind")
		assert(not Combat2D.inArc(0, 0, 0, half, 5.5, 12, 0, 3), "too far")
		assert(Combat2D.inArc(0, 0, 0, half, 5.5, 1, 0, 3), "overlapping counts")
	end)

	test("barrels and kiting accuracy", function()
		assert(Stats.barrelFactor(Config, 1) == 1 and near(Stats.barrelFactor(Config, 5), 0.55))
		assert(near(5 * Stats.barrelFactor(Config, 5), 2.75), "5 barrels = 2.75x total")
		assert(near(Stats.inaccuracy(Config, 0), 1) and near(Stats.inaccuracy(Config, 1), 9))
	end)

	test("visual size steps every 5 levels", function()
		assert(Stats.visualScale(Config, 0) == 1 and Stats.visualScale(Config, 4) == 1)
		assert(near(Stats.visualScale(Config, 5), 1.02) and near(Stats.visualScale(Config, 100), 1.4))
	end)

	test("barrels and Ricochet need a projectile main gun", function()
		assert(offered(build({ "projectile_primary" }), 20, "stat_barrels"), "rookie gets barrels")
		assert(not offered(build({ "melee_primary" }), 20, "stat_barrels"), "brawler does not")
		assert(not offered(build({ "cone_primary" }), 20, "mod_ricochet"), "scorcher has no ricochet")
	end)

	test("Spreader Choke needs an extra barrel first", function()
		local b = build({ "projectile_primary" })
		assert(not offered(b, 20, "mod_spread"), "no barrels yet")
		b.stacks.stat_barrels = 1
		assert(offered(b, 20, "mod_spread"), "after one extra barrel")
	end)
end
