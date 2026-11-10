-- Pacing model: how long a strong player takes to reach each level under the
-- assumed income below. These assumptions are provisional; replace them with
-- playtest data (time to Lv 10, kills per minute) once the game is live.

local Config = require("../src/shared/Config")
local Combat2D = require("../src/shared/Combat2D")

local Pacing = {}

Pacing.targets = { [1] = 20, [10] = 240, [50] = 1200, [100] = 2400 } -- seconds

-- XP per second from orbs and crates while roaming the zones this level unlocks.
local function orbRate(level: number): number
	if level < 10 then
		return 2 -- outer ring
	elseif level < 30 then
		return 4.5 -- middle ring, small crates
	end
	return 7 -- centre: core orbs and large crates
end

local KILL_INTERVAL = 120 -- a strong player lands a kill every 2 minutes from Lv 10
local VICTIM_FRACTION = 0.7 -- victims average 70% of the killer's level
local SPILL_COLLECTED = 0.5 -- the killer picks up half of the death orbs

local function totalTo(toNext: (number) -> number, level: number): number
	local sum = 0
	for l = 0, level - 1 do
		sum += toNext(l)
	end
	return sum
end

-- Returns seconds to reach each level, up to maxLevel.
function Pacing.simulate(toNext: (number) -> number, maxLevel: number): { [number]: number }
	local times = {}
	local t, level, xp = 0, 0, 0
	while level < maxLevel and t < 4 * 3600 do
		t += 1
		local gain = orbRate(level)
		if level >= 10 and t % KILL_INTERVAL == 0 then
			local vl = math.floor(level * VICTIM_FRACTION)
			local vt = totalTo(toNext, vl)
			gain += Combat2D.killReward(vt, vl, level, Config.Death.KillShare, Config.Death.KillMinimum)
			gain += vt * Config.Death.SpillFraction * SPILL_COLLECTED
		end
		xp += gain
		while level < maxLevel and xp >= toNext(level) do
			xp -= toNext(level)
			level += 1
			times[level] = t
		end
	end
	return times
end

return Pacing
