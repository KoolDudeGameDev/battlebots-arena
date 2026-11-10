--!strict
-- Which map is up and what happens next (D79, D81). Pure: Config, the time and the
-- random rolls are passed in, so Lune can test every transition.
--
--   grassland --(boss timer, enough players)--> warning (still on the grassland)
--   warning   --(warning over)----------------> arena (the boss's own map)
--   arena     --(boss beaten: defeated())------> victory (rewards, still in the arena)
--   arena     --(time out)-------------------> grassland ("escape": no biome)
--   victory   --(victory window over)--------> biome (the boss's biome on the overworld)
--   biome     --(revertWarning before the end)> revert (same map, countdown)
--   revert    --(biome time over)------------> grassland
--
-- The boss timer only counts on the grassland.

export type State = {
	phase: string,
	map: string,
	boss: string?,
	lastBoss: string?,
	endsAt: number,
	nextBossAt: number,
}

local MapFlow = {}

function MapFlow.bossKeys(cfg: any): { string }
	local keys = {}
	for key in cfg.Bosses.list do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function nextBossAt(cfg: any, t: number, roll: number): number
	local every = cfg.Bosses.every
	return t + every[1] + (every[2] - every[1]) * roll
end

local function home(cfg: any, s: State, t: number, roll: number): State
	return { phase = "grassland", map = "grassland", boss = nil, lastBoss = s.boss or s.lastBoss, endsAt = math.huge, nextBossAt = nextBossAt(cfg, t, roll) }
end

function MapFlow.new(cfg: any, t: number, roll: number): State
	return { phase = "grassland", map = "grassland", boss = nil, lastBoss = nil, endsAt = math.huge, nextBossAt = nextBossAt(cfg, t, roll) }
end

-- Advances by time. Returns the new state and the event when the phase changed:
-- "warning", "arena", "escape", "biome", "revert" or "grassland".
function MapFlow.tick(cfg: any, s: State, t: number, players: number, roll: number): (State, string?)
	local B, M = cfg.Bosses, cfg.Maps
	if s.phase == "grassland" then
		if t < s.nextBossAt then
			return s, nil
		end
		if players < B.minPlayers then
			local n = table.clone(s)
			n.nextBossAt = nextBossAt(cfg, t, roll)
			return n, nil
		end
		local choices = {}
		for _, key in MapFlow.bossKeys(cfg) do
			if key ~= s.lastBoss then
				table.insert(choices, key)
			end
		end
		local boss = choices[math.clamp(math.floor(roll * #choices) + 1, 1, #choices)]
		return { phase = "warning", map = "grassland", boss = boss, lastBoss = s.lastBoss, endsAt = t + B.warning, nextBossAt = math.huge }, "warning"
	end
	if t < s.endsAt and not (s.phase == "biome" and t >= s.endsAt - M.revertWarning) then
		return s, nil
	end
	local boss = s.boss :: string
	if s.phase == "warning" then
		return { phase = "arena", map = M.arenaFor[boss], boss = boss, lastBoss = s.lastBoss, endsAt = t + B.despawnAfter, nextBossAt = math.huge }, "arena"
	elseif s.phase == "arena" then
		return home(cfg, s, t, roll), "escape"
	elseif s.phase == "victory" then
		return { phase = "biome", map = M.biomeFor[boss], boss = boss, lastBoss = s.lastBoss, endsAt = t + B.hazardDuration, nextBossAt = math.huge }, "biome"
	elseif s.phase == "biome" then
		local n = table.clone(s)
		n.phase = "revert"
		return n, "revert"
	elseif s.phase == "revert" then
		return home(cfg, s, t, roll), "grassland"
	end
	return s, nil
end

-- The boss died. Only counts in the arena, and before the escape has happened
-- (call this before tick() in the same frame).
function MapFlow.defeated(cfg: any, s: State, t: number): (State, string?)
	if s.phase ~= "arena" then
		return s, nil
	end
	local n = table.clone(s)
	n.phase = "victory"
	n.endsAt = t + cfg.Maps.victory
	return n, "victory"
end

return MapFlow
