--!strict
-- What a mount does when its fire timer is ready (D92). One entry per mount kind,
-- all with the same interface: given the robot, its targets and the weapon at its
-- rank, did it fire, and what happened? Pure: the snapshot and the geometry helpers
-- are passed in, so Lune tests every mount. Combat carries out the actions (damage,
-- projectiles, lightning, trap parts) and starts the fire timer.

export type Target = { x: number, z: number, r: number, crate: boolean }

export type Robot = {
	x: number,
	z: number,
	facing: number, -- the hull's heading (mounts swivel within its front arc, D82)
	scale: number,
	hitRadius: number,
	speedFraction: number, -- of top speed
	vx: number, -- velocity on the ground
	vz: number,
	hasRoot: boolean,
	rangeMult: number,
	shotSpeedMult: number,
	damageMult: number,
	liveProjectiles: number,
}

export type Context = {
	robot: Robot,
	def: any, -- Config.Weapons entry
	rank: number,
	damage: number, -- at this rank, with damage cards
	targets: { Target }, -- every enemy robot and crate
	arcHalf: number, -- radians either side of the facing a mount can turn
	projectileCap: number,
	rocketCount: number, -- Rocket Pod rockets at this rank
	geom: any, -- Combat2D (inArc)
}

-- kind: "shot" (a projectile), "hit" (damage on targets[target], knocked back by
-- `knockback` when set), "beam" (a lightning segment; first = it leaves the coil)
-- or "trap" (a spike trap at x, z). Combat runs them in order.
export type Action = {
	kind: string,
	target: number?,
	amount: number?,
	knockback: number?,
	x: number?,
	z: number?,
	angle: number?,
	speed: number?,
	range: number?,
	radius: number?,
	code: number?,
	opts: { [string]: any }?,
	x1: number?,
	z1: number?,
	x2: number?,
	z2: number?,
	first: boolean?,
}

type Fire = (c: Context) -> (boolean, { Action })

local MountFire = {}

local function inFront(x: number, z: number, facing: number, half: number, tx: number, tz: number): boolean
	local d = (math.atan2(tz - z, tx - x) - facing + math.pi) % (2 * math.pi) - math.pi
	return math.abs(d) <= half
end

-- Nearest target in range and in the front arc: robots first, crates only if no
-- robot and the weapon shoots crates.
local function nearestInArc(c: Context, range: number): Target?
	local r = c.robot
	local best: Target? = nil
	for pass = 1, 2 do
		if pass == 2 and (best or not c.def.targetsCrates) then
			break
		end
		local bestD = math.huge
		for _, tg in c.targets do
			if tg.crate == (pass == 1) or not inFront(r.x, r.z, r.facing, c.arcHalf, tg.x, tg.z) then
				continue
			end
			local d = math.sqrt((tg.x - r.x) ^ 2 + (tg.z - r.z) ^ 2) - tg.r
			if d <= range and d < bestD then
				best, bestD = tg, d
			end
		end
	end
	return best
end

-- Gun mounts: aim at the nearest target in the arc and fire from 2 studs out.
local function gun(build: (c: Context, angle: number, x: number, z: number, range: number) -> { Action }): Fire
	return function(c: Context)
		local r = c.robot
		if r.liveProjectiles >= c.projectileCap then
			return false, {}
		end
		local range = c.def.range * r.rangeMult
		local tg = nearestInArc(c, range)
		if not tg then
			return false, {}
		end
		local angle = math.atan2(tg.z - r.z, tg.x - r.x)
		local ox, oz = r.x + math.cos(angle) * 2 * r.scale, r.z + math.sin(angle) * 2 * r.scale
		return true, build(c, angle, ox, oz, range)
	end
end

local function shot(c: Context, angle: number, x: number, z: number, speed: number, range: number, opts: { [string]: any }?): Action
	return { kind = "shot", angle = angle, x = x, z = z, speed = speed, range = range, radius = c.def.radius, code = c.def.code, opts = opts }
end

local gatling = gun(function(c, angle, x, z, range)
	return { shot(c, angle, x, z, c.def.speed * c.robot.shotSpeedMult, range + 2) }
end)

-- Rocket Pod: 1-3 accelerating rockets fanned by spreadDegrees, with splash.
local rocket = gun(function(c, angle, x, z, range)
	local d, r = c.def, c.robot
	local out = {}
	local n = c.rocketCount
	for k = 1, n do
		local a = angle + math.rad((k - (n + 1) / 2) * d.spreadDegrees)
		table.insert(out, shot(c, a, x, z, d.launchSpeed * r.shotSpeedMult, range, {
			accel = d.accel * r.shotSpeedMult,
			maxSpeed = d.speed * r.shotSpeedMult,
			splashDamage = d.splashDamage * r.damageMult * (1 + d.damagePerRank * (c.rank - 1)),
			splashRadius = d.splashRadius,
			knockback = d.knockback,
		}))
	end
	return out
end)

-- Railgun: one shot that pierces every robot in line.
local railgun = gun(function(c, angle, x, z, range)
	return { shot(c, angle, x, z, c.def.speed * c.robot.shotSpeedMult, range, { pierce = true, hitIds = {} }) }
end)

-- Shock Coil: the nearest target in the arc, then jumps to the nearest ones left
-- (any direction), weaker each jump. +1 jump at ranks 3 and 5.
local function shock(c: Context): (boolean, { Action })
	local d, r = c.def, c.robot
	local out: { Action } = {}
	local hit: { [number]: boolean } = {}
	local jumps = d.chains + (if c.rank >= 3 then 1 else 0) + (if c.rank >= 5 then 1 else 0)
	local fromX, fromZ, reach = r.x, r.z, d.range * r.rangeMult
	for k = 0, jumps do
		local best: number? = nil
		local bestD = math.huge
		for i, tg in c.targets do
			if (tg.crate and not d.targetsCrates) or hit[i] then
				continue
			end
			if k == 0 and not inFront(r.x, r.z, r.facing, c.arcHalf, tg.x, tg.z) then
				continue
			end
			local dist = math.sqrt((tg.x - fromX) ^ 2 + (tg.z - fromZ) ^ 2) - tg.r
			if dist <= reach and dist < bestD then
				best, bestD = i, dist
			end
		end
		if not best then
			break
		end
		hit[best] = true
		local tg = c.targets[best]
		table.insert(out, { kind = "beam", x1 = fromX, z1 = fromZ, x2 = tg.x, z2 = tg.z, first = k == 0 })
		table.insert(out, { kind = "hit", target = best, amount = c.damage * d.chainFalloff ^ k })
		fromX, fromZ, reach = tg.x, tg.z, d.chainRange
	end
	return #out > 0, out
end

-- Minotaur Horns: robots in the front arc within reach, while you drive; tossed back.
local function spikeram(c: Context): (boolean, { Action })
	local d, r = c.def, c.robot
	if r.speedFraction < d.minSpeedFraction or not r.hasRoot then
		return false, {}
	end
	local reach = r.hitRadius + d.reach * r.scale
	local out: { Action } = {}
	for i, tg in c.targets do
		if not tg.crate and c.geom.inArc(r.x, r.z, r.facing, math.rad(d.arcDegrees / 2), reach, tg.x, tg.z, tg.r) then
			table.insert(out, { kind = "hit", target = i, amount = c.damage, knockback = d.knockback })
		end
	end
	return #out > 0, out
end

-- Vertical Saw: every robot touching your hitbox, from any side.
local function sidesaw(c: Context): (boolean, { Action })
	local r = c.robot
	local reach = r.hitRadius + c.def.reach * r.scale
	local out: { Action } = {}
	for i, tg in c.targets do
		if not tg.crate and (tg.x - r.x) ^ 2 + (tg.z - r.z) ^ 2 <= (reach + tg.r) ^ 2 then
			table.insert(out, { kind = "hit", target = i, amount = c.damage })
		end
	end
	return #out > 0, out
end

-- Spike Traps (D88): while you drive, one just behind the way you're moving.
local function traps(c: Context): (boolean, { Action })
	local d, r = c.def, c.robot
	local speed = math.sqrt(r.vx * r.vx + r.vz * r.vz)
	if not r.hasRoot or speed < d.minSpeed then
		return false, {}
	end
	local behind = r.hitRadius + d.radius * 0.6
	return true, { { kind = "trap", x = r.x - r.vx / speed * behind, z = r.z - r.vz / speed * behind } }
end

local FIRE: { [string]: Fire } = {
	gatling = gatling,
	rocket = rocket,
	railgun = railgun,
	shock = shock,
	spikeram = spikeram,
	sidesaw = sidesaw,
	traps = traps,
}

-- Fires the mount whose Config.Weapons key is `kind`. Returns whether it fired (the
-- caller restarts its fire timer) and the actions to carry out. A mount with no entry
-- is an error, not a silent gatling (Combat's weapon pcall reports it once).
function MountFire.fire(kind: string, c: Context): (boolean, { Action })
	local fire = FIRE[kind]
	if not fire then
		error(`MountFire has no entry for mount kind "{kind}"`)
	end
	return fire(c)
end

return MountFire
