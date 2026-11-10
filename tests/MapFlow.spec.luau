-- The map flow (D79, D81): grassland -> warning -> boss arena -> victory -> biome ->
-- revert warning -> grassland, or arena -> escape -> grassland.
local Config = require("../src/shared/Config")
local MapFlow = require("../src/shared/MapFlow")

local B, M = Config.Bosses, Config.Maps

local function arenaAt(t0: number)
	local s = MapFlow.new(Config, t0, 0.5)
	local ev
	s, ev = MapFlow.tick(Config, s, s.nextBossAt, 2, 0.5)
	assert(ev == "warning")
	local warnEnd = s.endsAt
	s, ev = MapFlow.tick(Config, s, warnEnd, 2, 0.5)
	assert(ev == "arena")
	return s, warnEnd
end

return function(test)
	test("starts on the grassland with the boss timer inside its range", function()
		local s = MapFlow.new(Config, 100, 0.5)
		assert(s.phase == "grassland" and s.map == "grassland")
		assert(s.nextBossAt >= 100 + B.every[1] and s.nextBossAt <= 100 + B.every[2])
	end)

	test("too few players: the timer waits; enough: a 20 s warning on the grassland", function()
		local s = MapFlow.new(Config, 0, 0)
		local t = s.nextBossAt
		local s2, ev = MapFlow.tick(Config, s, t, B.minPlayers - 1, 0)
		assert(ev == nil and s2.phase == "grassland" and s2.nextBossAt > t)
		local s3, ev3 = MapFlow.tick(Config, s, t, B.minPlayers, 0)
		assert(ev3 == "warning" and s3.map == "grassland" and s3.endsAt == t + B.warning and s3.boss ~= nil)
	end)

	test("warning ends in the boss's arena for up to despawnAfter", function()
		local s, warnEnd = arenaAt(0)
		assert(s.phase == "arena" and s.map == M.arenaFor[s.boss :: string])
		assert(s.endsAt == warnEnd + B.despawnAfter)
	end)

	test("victory, then the biome for 6 min with a revert warning, then home", function()
		local s = arenaAt(0)
		local t = s.endsAt - 100
		local ev
		s, ev = MapFlow.defeated(Config, s, t)
		assert(ev == "victory" and s.phase == "victory" and s.endsAt == t + M.victory)
		local arenaMap = s.map
		assert(arenaMap == M.arenaFor[s.boss :: string], "rewards are collected in the arena")
		local victoryEnd = s.endsAt
		s, ev = MapFlow.tick(Config, s, victoryEnd, 2, 0.5)
		assert(ev == "biome" and s.map == M.biomeFor[s.boss :: string])
		local biomeEnd = s.endsAt
		assert(biomeEnd == victoryEnd + B.hazardDuration)
		s, ev = MapFlow.tick(Config, s, biomeEnd - M.revertWarning, 2, 0.5)
		assert(ev == "revert" and s.phase == "revert" and s.map == M.biomeFor[s.boss :: string])
		s, ev = MapFlow.tick(Config, s, biomeEnd, 2, 0.5)
		assert(ev == "grassland" and s.phase == "grassland" and s.map == "grassland")
		assert(s.nextBossAt >= biomeEnd + B.every[1], "the boss timer only counts on the grassland")
	end)

	test("the boss escapes when its time runs out: straight home, no biome", function()
		local s = arenaAt(0)
		local s2, ev = MapFlow.tick(Config, s, s.endsAt, 2, 0.5)
		assert(ev == "escape" and s2.phase == "grassland" and s2.map == "grassland")
	end)

	test("a kill in the same moment the timer runs out still counts as a victory", function()
		local s = arenaAt(0)
		local s2, ev = MapFlow.defeated(Config, s, s.endsAt)
		assert(ev == "victory" and s2.phase == "victory")
		local s3, ev3 = MapFlow.tick(Config, s2, s.endsAt, 2, 0.5)
		assert(ev3 == nil and s3.phase == "victory", "no escape after the kill")
	end)

	test("defeated outside the arena does nothing", function()
		local s = MapFlow.new(Config, 0, 0.5)
		local s2, ev = MapFlow.defeated(Config, s, 10)
		assert(ev == nil and s2.phase == "grassland")
	end)

	test("never the same boss twice in a row", function()
		local s = MapFlow.new(Config, 0, 0)
		local last = nil
		for i = 1, 30 do
			local roll = (i * 0.37) % 1
			s = MapFlow.tick(Config, s, s.nextBossAt, 2, roll)
			assert(s.boss ~= last, "repeated " .. tostring(s.boss))
			last = s.boss
			s = MapFlow.tick(Config, s, s.endsAt, 2, roll) -- arena
			s = MapFlow.tick(Config, s, s.endsAt, 2, roll) -- escape home
		end
	end)
end
