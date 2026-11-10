--!strict
-- Geometry questions against one map layout (MapLayouts.luau, D81). Pure: the map,
-- the zone table and the random generator are passed in, so Lune can test it and
-- both server and clients use the same answers.
--
-- Boxes are oriented (OBB): centre (cx, cz), unit axis (ux, uz), half extents hu
-- along u and hv along v = (-uz, ux). Circles are (x, z, r). `broken` holds the keys
-- of destructible pieces that are gone: a box's id, or CIRCLE_KEY + a circle's id.

local MapQuery = {}

MapQuery.CIRCLE_KEY = 10000

-- Entry fraction (0..1) of the segment into a box grown by pad, or nil.
local function segmentBox(x1: number, z1: number, x2: number, z2: number, b: any, pad: number): number?
	local hu, hv = b.hu + pad, b.hv + pad
	local ax, az = x1 - b.cx, z1 - b.cz
	local dx, dz = x2 - x1, z2 - z1
	-- Into box space.
	local pu, pv = ax * b.ux + az * b.uz, -ax * b.uz + az * b.ux
	local du, dv = dx * b.ux + dz * b.uz, -dx * b.uz + dz * b.ux
	local tmin, tmax = 0, 1
	for _, axis in { { pu, du, hu }, { pv, dv, hv } } do
		local p, d, h = axis[1], axis[2], axis[3]
		if math.abs(d) < 1e-9 then
			if p < -h or p > h then
				return nil
			end
		else
			local t1, t2 = (-h - p) / d, (h - p) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

local function segmentCircle(x1: number, z1: number, x2: number, z2: number, cx: number, cz: number, r: number): number?
	local dx, dz = x2 - x1, z2 - z1
	local fx, fz = x1 - cx, z1 - cz
	local a = dx * dx + dz * dz
	local c = fx * fx + fz * fz - r * r
	if c <= 0 then
		return 0 -- starts inside
	end
	if a < 1e-12 then
		return nil
	end
	local b = 2 * (fx * dx + fz * dz)
	local disc = b * b - 4 * a * c
	if disc < 0 then
		return nil
	end
	local t = (-b - math.sqrt(disc)) / (2 * a)
	if t >= 0 and t <= 1 then
		return t
	end
	return nil
end

local function inBox(x: number, z: number, b: any, margin: number): boolean
	local ax, az = x - b.cx, z - b.cz
	local u, v = ax * b.ux + az * b.uz, -ax * b.uz + az * b.ux
	return math.abs(u) <= b.hu + margin and math.abs(v) <= b.hv + margin
end

-- How far along (0..1) the segment first meets cover grown by pad, or nil if clear.
function MapQuery.blockedAt(map: any, x1: number, z1: number, x2: number, z2: number, pad: number, broken: { [number]: boolean }?): number?
	local best: number? = nil
	for _, b in map.boxes do
		if not (broken and broken[b.id]) then
			local t = segmentBox(x1, z1, x2, z2, b, pad)
			if t and (best == nil or t < best) then
				best = t
			end
		end
	end
	for _, c in map.circles do
		if not (broken and broken[MapQuery.CIRCLE_KEY + c.id]) then
			local t = segmentCircle(x1, z1, x2, z2, c.x, c.z, c.r + pad)
			if t and (best == nil or t < best) then
				best = t
			end
		end
	end
	return best
end

function MapQuery.inCover(map: any, x: number, z: number, margin: number, broken: { [number]: boolean }?): boolean
	for _, b in map.boxes do
		if not (broken and broken[b.id]) and inBox(x, z, b, margin) then
			return true
		end
	end
	for _, c in map.circles do
		if not (broken and broken[MapQuery.CIRCLE_KEY + c.id]) and (x - c.x) ^ 2 + (z - c.z) ^ 2 < (c.r + margin) ^ 2 then
			return true
		end
	end
	return false
end

function MapQuery.inLava(map: any, x: number, z: number): boolean
	for _, b in map.lava do
		if inBox(x, z, b, 0) then
			return true
		end
	end
	return false
end

-- Does a robot's circle overlap this piece? (Bosses smashing destructible cover.)
function MapQuery.touchesBox(b: any, x: number, z: number, r: number): boolean
	local ax, az = x - b.cx, z - b.cz
	local u, v = ax * b.ux + az * b.uz, -ax * b.uz + az * b.ux
	local du = math.max(0, math.abs(u) - b.hu)
	local dv = math.max(0, math.abs(v) - b.hv)
	return du * du + dv * dv <= r * r
end

-- The map's spawn point farthest from danger (E5): starting at index `start`, the
-- first spawn whose nearest enemy is at least minDist away, else the one whose
-- nearest enemy is farthest. Enemies are { x, z } pairs.
function MapQuery.pickSpawn(map: any, enemies: { { number } }, minDist: number, start: number): (number, number)
	local list = map.spawns
	local n = #list
	local best, bestD = list[1], -1
	for k = 0, n - 1 do
		local s = list[(start + k - 1) % n + 1]
		local nearest = math.huge
		for _, e in enemies do
			nearest = math.min(nearest, math.sqrt((e[1] - s.x) ^ 2 + (e[2] - s.z) ^ 2))
		end
		if nearest >= minDist then
			return s.x, s.z
		end
		if nearest > bestD then
			best, bestD = s, nearest
		end
	end
	return best.x, best.z
end

-- A random clear point in a zone. Overworld maps use the Chebyshev zones; arenas
-- have no zones and use their whole fight floor (a circle 10 studs inside the wall).
function MapQuery.randomInZone(map: any, zones: any, zone: string, rng: Random, margin: number, broken: { [number]: boolean }?): (number, number)
	local lo, hi = 0, map.inner - 10
	if map.kind == "overworld" and zones[zone] then
		lo, hi = zones[zone].min, zones[zone].max
	end
	for _ = 1, 50 do
		local x, z = rng:NextNumber(-hi, hi), rng:NextNumber(-hi, hi)
		local inside = if map.kind == "overworld" then math.max(math.abs(x), math.abs(z)) >= lo else x * x + z * z <= hi * hi
		if inside and math.max(math.abs(x), math.abs(z)) < hi and not MapQuery.inCover(map, x, z, margin, broken) and not MapQuery.inLava(map, x, z) then
			return x, z
		end
	end
	return (lo + hi) / 2, 0
end

return MapQuery
