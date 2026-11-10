-- Bosses and hazards (Phase 4b, D39, D74): timing cycles, boss HP and rewards.
local Config = require("../src/shared/Config")
local HazardTiming = require("../src/shared/HazardTiming")
local Chassis = require("../src/shared/Chassis")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return function(test)
	test("flame vents: 3 s idle, 1 s glow, 2 s flame, then repeat", function()
		local cycle = Config.Hazards.vents.cycle
		assert(HazardTiming.phase(cycle, 0) == "idle")
		assert(HazardTiming.phase(cycle, 2.99) == "idle")
		assert(HazardTiming.phase(cycle, 3.5) == "glow")
		assert(HazardTiming.phase(cycle, 4.5) == "flame")
		assert(HazardTiming.phase(cycle, 6.1) == "idle", "wraps after 6 s")
		local _, progress = HazardTiming.phase(cycle, 5)
		assert(near(progress, 0.5), "half way through the flame")
		assert(near(HazardTiming.length(cycle), 6))
	end)

	test("edge hammers: 4 s raise, 1 s shake, then the slam", function()
		local cycle = Config.Hazards.hammers.cycle
		assert(HazardTiming.phase(cycle, 1) == "raise")
		assert(HazardTiming.phase(cycle, 4.5) == "shake")
		assert(HazardTiming.phase(cycle, 5.1) == "slam")
	end)

	test("floor saws roll to the end of their track and back", function()
		assert(near(HazardTiming.pingPong(100, 20, 0), 0))
		assert(near(HazardTiming.pingPong(100, 20, 2.5), 50))
		assert(near(HazardTiming.pingPong(100, 20, 5), 100))
		assert(near(HazardTiming.pingPong(100, 20, 7.5), 50), "on the way back")
		assert(near(HazardTiming.pingPong(100, 20, 10), 0))
	end)

	test("boss HP: 1500 + 400 per player", function()
		assert(HazardTiming.bossHp(Config.Bosses, 2) == 2300)
		assert(HazardTiming.bossHp(Config.Bosses, 20) == 9500)
	end)

	test("boss rules from the roadmap", function()
		local B = Config.Bosses
		assert(B.minPlayers == 2 and B.every[1] == 420 and B.every[2] == 600)
		assert(B.warning == 20 and B.despawnAfter == 240 and B.hazardDuration == 360)
		assert(B.reward.coins == 60 and B.reward.xp == 600)
		assert(B.reward.scatterCoins * Config.Coins.value == 40, "40 coins scatter")
	end)

	test("three bosses, each with a body, an attack and a hazard", function()
		local n = 0
		for _, def in Config.Bosses.list do
			n += 1
			assert(Chassis.byId[def.chassis], def.name .. " body")
			assert(Config.Hazards[def.hazard], def.name .. " hazard")
			assert(def.attack and def.attack.every > 0, def.name .. " attack")
		end
		assert(n == 3)
	end)
end
