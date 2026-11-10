-- Checks that the numbers really add up: fire rate, damage, range and the map.
local Config = require("../src/shared/Config")
local Combat2D = require("../src/shared/Combat2D")
local Stats = require("../src/shared/Stats")
local MapLayouts = require("../src/shared/MapLayouts")

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) < (eps or 1e-6)
end

-- Shots fired in `seconds` of holding the trigger at 60 fps.
local function shotsIn(rate: number, seconds: number): number
	local nextAt, shots = 0, 0
	local interval = 1 / rate
	local t = 100 -- start well after time 0, like a real server clock
	for _ = 1, math.floor(seconds * 60) do
		t += 1 / 60
		local fire
		fire, nextAt = Combat2D.nextShot(nextAt, t, interval)
		if fire then
			shots += 1
		end
	end
	return shots
end

return function(test)
	test("fire rate = shots per second, with no frame drift", function()
		assert(math.abs(shotsIn(4, 10) - 40) <= 1, "4/s for 10 s: " .. shotsIn(4, 10))
		assert(math.abs(shotsIn(14, 10) - 140) <= 1, "14/s for 10 s: " .. shotsIn(14, 10))
	end)

	test("starting to fire gives one shot, not a double shot", function()
		local fire1, nextAt = Combat2D.nextShot(0, 100, 0.25)
		local fire2 = Combat2D.nextShot(nextAt, 100 + 1 / 60, 0.25)
		assert(fire1 and not fire2)
	end)

	test("each Fire Rate stack really adds 10% more shots", function()
		local base = Config.Weapons.blaster.fireRate
		for stacks = 0, 8 do
			local s = Stats.compute(Config, { stacks = { stat_firerate = stacks } }, 0)
			local expected = 40 * (1 + 0.1 * stacks)
			local got = shotsIn(base * s.fireRateMult, 10)
			assert(math.abs(got - expected) <= 1, `{stacks} stacks: {got} shots, expected {expected}`)
		end
	end)

	test("damage and range stacks multiply as the cards say", function()
		local s = Stats.compute(Config, { stacks = { stat_damage = 5, stat_range = 6 } }, 0)
		assert(near(Config.Weapons.blaster.damage * s.damageMult, 18), "12 x 1.5")
		assert(near(s.rangeMult, 1.48), "range x 1.48")
	end)

	test("underdog bonus: lower levels hit higher levels harder, capped", function()
		assert(Stats.underdogFactor(Config, 50, 50) == 1, "same level")
		assert(Stats.underdogFactor(Config, 60, 20) == 1, "no bonus downward")
		assert(near(Stats.underdogFactor(Config, 10, 30), 1.3), "20 levels: +30%")
		assert(near(Stats.underdogFactor(Config, 0, 100), 1.6), "capped at +60%")
	end)

	test("maps: every cover piece sits inside its map's walls (D81)", function()
		for name, m in MapLayouts do
			for _, b in m.boxes do
				if b.name ~= "ArenaCornerWall" then -- the octagon corners overhang on purpose
					local ex = math.abs(b.ux) * b.hu + math.abs(b.uz) * b.hv
					local ez = math.abs(b.uz) * b.hu + math.abs(b.ux) * b.hv
					assert(math.abs(b.cx) + ex <= m.inner + 0.01 and math.abs(b.cz) + ez <= m.inner + 0.01, `{name} {b.name} outside`)
				end
			end
			for _, c in m.circles do
				assert(math.max(math.abs(c.x), math.abs(c.z)) + c.r <= m.inner + 0.01, `{name} {c.name} outside`)
			end
		end
	end)
end
