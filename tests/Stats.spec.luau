local Stats = require("../src/shared/Stats")
local Config = require("../src/shared/Config")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return function(test)
	test("base stats with an empty build at level 0", function()
		local s = Stats.compute(Config, { stacks = {} }, 0)
		assert(s.maxHp == 100 and s.speed == 22 and s.damageMult == 1 and s.scale == 1)
	end)

	test("stacks and reinforce add up", function()
		local s = Stats.compute(Config, { stacks = { stat_hp = 2, stat_damage = 3, fb_reinforce = 1, stat_pickup = 4 } }, 0)
		assert(s.maxHp == 135, "hp " .. s.maxHp)
		assert(near(s.damageMult, 1.32), "dmg " .. s.damageMult)
		assert(s.pickupRadius == 12, "pickup " .. s.pickupRadius)
	end)

	test("levels grow HP, damage and size, and cost speed", function()
		local s = Stats.compute(Config, { stacks = {} }, 100)
		assert(near(s.maxHp, 300), "hp x3 at 100: " .. s.maxHp)
		assert(near(s.damageMult, 1.4), "damage +40%: " .. s.damageMult)
		assert(near(s.speed, 22 * 0.75), "speed -25%: " .. s.speed)
		assert(near(s.scale, 1.4), "scale: " .. s.scale)
		local mid = Stats.compute(Config, { stacks = { stat_speed = 6 } }, 40)
		assert(near(mid.speed, 22 * 1.3 * 0.9), "speed stacks and level loss multiply: " .. mid.speed)
	end)

	test("level speed loss has a floor", function()
		local s = Stats.compute(Config, { stacks = {} }, 1000)
		assert(near(s.speed, 22 * Config.LevelGrowth.speedFloor), "floor")
	end)

	test("weapon ranks scale damage and fire rate", function()
		local dmg, rate = Stats.weaponAtRank(Config.Weapons.gatling, 5)
		assert(near(dmg, 8) and near(rate, 8.4), `{dmg} {rate}`)
		assert(Stats.rocketCount(1) == 1 and Stats.rocketCount(3) == 2 and Stats.rocketCount(5) == 3)
	end)
end
