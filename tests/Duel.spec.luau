-- Robot balance: reach is paid for with toughness, and every ranged-vs-close
-- matchup stays fair in the duel model (tests/Duel.luau).
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Duel = require("./Duel")

-- In open ground the charger wins (D66), but the ranged robot makes it
-- pay: the charger ends with at most this much of its health.
local CHARGER_LEFT = 0.5

-- The Bombard is out of the D66 duels since D85: Gregory chose a full damage buff
-- over keeping chargers ahead of it in open ground.
local EXEMPT = { bombard = true }

local function pairs2(fn, all: boolean?)
	for _, r in Chassis.list do
		if not r.comingSoon and Duel.isRanged(r.id) and (all or not EXEMPT[r.id]) then
			for _, c in Chassis.list do
				if not c.comingSoon and Duel.isClose(c.id) then
					fn(r.id, c.id)
				end
			end
		end
	end
end

local function tough(id: string): number
	local s = Stats.compute(Config, { stacks = {}, chassis = Chassis.byId[id] }, 0)
	return s.maxHp + s.maxArmor
end

return function(test)
	test("ranged robots out-reach close-range robots but are less tough", function()
		pairs2(function(r, c)
			assert(tough(r) < tough(c), `{r} should be less tough than {c}`)
		end, true)
	end)

	test("standing still while a close-range robot charges loses", function()
		pairs2(function(r, c)
			for _, level in { 0, 50, 100 } do
				local winner = Duel.run(r, c, level, false)
				assert(winner == "close", `{r} standing beat {c} at Lv {level}`)
			end
		end)
	end)

	test("a charger catches a ranged robot backing off in open ground, but pays for it", function()
		pairs2(function(r, c)
			for _, level in { 0, 50, 100 } do
				local winner, left = Duel.run(r, c, level, true)
				assert(winner == "close", `{r} backing off beat {c} at Lv {level}`)
				assert(left <= CHARGER_LEFT, `{c} beat {r} at Lv {level} with {math.floor(left * 100)}% left`)
			end
		end)
	end)
end
