--!strict
-- Boss and hazard timing (Phase 4b, D39, D74). Pure, so server and tests agree.
-- A cycle is an ordered list of { name, seconds } phases that repeats forever.

export type Phase = { name: string, seconds: number }

local HazardTiming = {}

function HazardTiming.length(cycle: { Phase }): number
	local total = 0
	for _, p in cycle do
		total += p.seconds
	end
	return total
end

-- The phase at time t (seconds since the hazard started) and how far through it (0..1).
function HazardTiming.phase(cycle: { Phase }, t: number): (string, number)
	local local_t = t % HazardTiming.length(cycle)
	for _, p in cycle do
		if local_t < p.seconds then
			return p.name, local_t / p.seconds
		end
		local_t -= p.seconds
	end
	local last = cycle[#cycle]
	return last.name, 1
end

-- Distance along a track of `length` for something rolling at `speed` that turns
-- back at each end.
function HazardTiming.pingPong(length: number, speed: number, t: number): number
	local d = (speed * t) % (2 * length)
	return if d <= length then d else 2 * length - d
end

-- Boss HP for the number of players in the server.
function HazardTiming.bossHp(bosses: any, players: number): number
	return bosses.hpBase + bosses.hpPerPlayer * players
end

return HazardTiming
