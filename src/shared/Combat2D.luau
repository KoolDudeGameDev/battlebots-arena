--!strict
-- 2D (X/Z) geometry and combat formulas shared by the server simulation and the
-- client renderer. Pure, no Roblox APIs.

local Combat2D = {}

-- First t in [0, 1] where segment (x1,z1)->(x2,z2) enters a circle, or nil.
function Combat2D.segmentCircle(x1: number, z1: number, x2: number, z2: number, cx: number, cz: number, r: number): number?
	local dx, dz = x2 - x1, z2 - z1
	local fx, fz = x1 - cx, z1 - cz
	local c = fx * fx + fz * fz - r * r
	if c <= 0 then
		return 0 -- starts inside
	end
	local a = dx * dx + dz * dz
	if a == 0 then
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

-- First t in [0, 1] where the segment enters an axis-aligned box, or nil (slab method).
function Combat2D.segmentBox(x1: number, z1: number, x2: number, z2: number, minX: number, minZ: number, maxX: number, maxZ: number): number?
	local tMin, tMax = 0, 1
	local dx, dz = x2 - x1, z2 - z1
	for axis = 1, 2 do
		local p, d, lo, hi
		if axis == 1 then
			p, d, lo, hi = x1, dx, minX, maxX
		else
			p, d, lo, hi = z1, dz, minZ, maxZ
		end
		if math.abs(d) < 1e-9 then
			if p < lo or p > hi then
				return nil
			end
		else
			local t1 = (lo - p) / d
			local t2 = (hi - p) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin = math.max(tMin, t1)
			tMax = math.min(tMax, t2)
			if tMin > tMax then
				return nil
			end
		end
	end
	return tMin
end

-- First t where the segment enters a rotated box (an Earth Wall), or nil.
-- (ux, uz) is the unit axis of the box's thickness; halfU and halfV are the
-- half-thickness and half-width.
function Combat2D.segmentOBB(x1: number, z1: number, x2: number, z2: number, cx: number, cz: number, ux: number, uz: number, halfU: number, halfV: number): number?
	local vx, vz = -uz, ux
	local function toLocal(x: number, z: number): (number, number)
		local dx, dz = x - cx, z - cz
		return dx * ux + dz * uz, dx * vx + dz * vz
	end
	local a1, b1 = toLocal(x1, z1)
	local a2, b2 = toLocal(x2, z2)
	return Combat2D.segmentBox(a1, b1, a2, b2, -halfU, -halfV, halfU, halfV)
end

function Combat2D.pointInBox(x: number, z: number, minX: number, minZ: number, maxX: number, maxZ: number, margin: number?): boolean
	local m = margin or 0
	return x >= minX - m and x <= maxX + m and z >= minZ - m and z <= maxZ + m
end

function Combat2D.chebyshev(x: number, z: number): number
	return math.max(math.abs(x), math.abs(z))
end


-- Fire-rate scheduling. Returns whether a shot fires at time t and the time the
-- next shot is allowed. Holding fire keeps an exact rhythm (no drift from frame
-- timing); starting fresh fires once, never a double shot.
function Combat2D.nextShot(nextAt: number, t: number, interval: number): (boolean, number)
	if t < nextAt then
		return false, nextAt
	end
	if nextAt < t - interval then
		nextAt = t -- idle for a while: this shot starts a new rhythm
	end
	return true, nextAt + interval
end

-- Splash damage multiplier at `dist` from the blast centre: 1 at the centre,
-- `edge` at the rim (D45).
function Combat2D.splashFactor(dist: number, radius: number, edge: number): number
	local f = math.clamp(dist / radius, 0, 1)
	return 1 - (1 - edge) * f
end

-- Knockback distance after mass: heavier (bigger) robots move less. Mass grows
-- with volume, so scale^3, times the robot's own mass (Chassis, default 1).
function Combat2D.knockback(force: number, scale: number, mass: number?): number
	return force / ((mass or 1) * scale * scale * scale)
end

-- Null Field (D68): speed factor for a shot or robot at (x, z) owned by ownerId.
-- Inside any other robot's field it moves at `slow`; your own field never slows you.
-- fields = { { x, z, r, owner } }. Server and client both use this, so shots stay in sync.
function Combat2D.fieldFactor(x: number, z: number, ownerId: number, fields: { any }, slow: number): number
	for _, f in fields do
		if f.owner ~= ownerId and (x - f.x) ^ 2 + (z - f.z) ^ 2 <= f.r * f.r then
			return slow
		end
	end
	return 1
end

-- Rocket speed after accelerating for dt, capped at maxSpeed.
function Combat2D.rocketSpeed(speed: number, accel: number, maxSpeed: number, dt: number): number
	return math.min(maxSpeed, speed + accel * dt)
end

-- Smallest difference between two angles, in radians (0..pi).
function Combat2D.angleDiff(a: number, b: number): number
	return math.abs((a - b + math.pi) % (2 * math.pi) - math.pi)
end

-- Is (tx, tz) within `reach` of (ox, oz) and inside the arc of `halfAngle`
-- around `aim`? `targetRadius` lets big robots be hit at the edge of the arc.
function Combat2D.inArc(ox: number, oz: number, aim: number, halfAngle: number, reach: number, tx: number, tz: number, targetRadius: number): boolean
	local dx, dz = tx - ox, tz - oz
	local dist = math.sqrt(dx * dx + dz * dz)
	if dist > reach + targetRadius then
		return false
	end
	if dist <= targetRadius then
		return true -- overlapping: always in front enough
	end
	local slack = math.asin(math.min(1, targetRadius / dist))
	return Combat2D.angleDiff(math.atan2(dz, dx), aim) <= halfAngle + slack
end

-- Direct XP the killer gets (GDD section 11).
function Combat2D.killReward(victimTotal: number, victimLevel: number, killerLevel: number, share: number, minimum: number): number
	local ratio = math.clamp((victimLevel + 5) / (killerLevel + 5), 0.25, 1.5)
	return math.max(minimum, math.floor(victimTotal * share * ratio))
end

-- How many red orbs a death spills and the value of each.
function Combat2D.deathSpill(victimTotal: number, victimLevel: number, fraction: number): (number, number)
	local spill = math.floor(victimTotal * fraction)
	if spill <= 0 then
		return 0, 0
	end
	local count = math.clamp(5 + math.floor(victimLevel / 3), 5, 25)
	count = math.min(count, spill) -- never spill orbs worth 0
	return count, math.floor(spill / count)
end

return Combat2D
