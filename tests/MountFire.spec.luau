-- What each mount does when it fires (D92): pinned from Combat.fireMounts and its
-- helpers before the move. Robot faces +X (facing 0) from the origin unless changed.
local MountFire = require("../src/shared/MountFire")
local Combat2D = require("../src/shared/Combat2D")
local Stats = require("../src/shared/Stats")
local Config = require("../src/shared/Config")

local W = Config.Weapons

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function robot(over: { [string]: any }?)
	local r = { x = 0, z = 0, facing = 0, scale = 1, hitRadius = 2, speedFraction = 1, vx = 10, vz = 0, hasRoot = true, rangeMult = 1, shotSpeedMult = 1, damageMult = 1, liveProjectiles = 0 }
	for k, v in over or {} do
		r[k] = v
	end
	return r
end

local function ctx(key: string, targets, over: { [string]: any }?)
	local rank = (over and over.rank) or 1
	local c = {
		robot = (over and over.robot) or robot(),
		def = W[key],
		rank = rank,
		damage = (over and over.damage) or W[key].damage,
		targets = targets,
		arcHalf = math.rad(Config.MountArcDegrees / 2),
		projectileCap = Config.Combat.ProjectileCapPerPlayer,
		rocketCount = Stats.rocketCount(rank),
		geom = Combat2D,
	}
	return c
end

local function bot(x: number, z: number)
	return { x = x, z = z, r = 2, crate = false }
end
local function crate(x: number, z: number)
	return { x = x, z = z, r = 2, crate = true }
end

local function only(actions, kind: string)
	local out = {}
	for _, a in actions do
		if a.kind == kind then
			table.insert(out, a)
		end
	end
	return out
end

return function(test)
	-- Guns ----------------------------------------------------------------------

	test("mount fire: a gun shoots the nearest robot in its front arc", function()
		local fired, actions = MountFire.fire("gatling", ctx("gatling", { bot(-8, 0), bot(30, 0), bot(20, 5) }))
		assert(fired and #actions == 1)
		local s = actions[1]
		assert(s.kind == "shot" and near(s.angle, math.atan2(5, 20)), "the robot behind is out of the arc")
		assert(near(s.x, math.cos(s.angle) * 2) and near(s.z, math.sin(s.angle) * 2), "leaves 2 studs out (x scale)")
		assert(s.range == W.gatling.range + 2 and s.speed == W.gatling.speed and s.code == W.gatling.code and s.radius == W.gatling.radius)
	end)

	test("mount fire: guns fall back to crates only with no robot, if they target crates", function()
		local _, a = MountFire.fire("gatling", ctx("gatling", { crate(10, 0), bot(30, 0) }))
		assert(near(a[1].angle, 0) and #a == 1, "a robot beats a closer crate")
		local fired, b = MountFire.fire("gatling", ctx("gatling", { crate(10, 3) }))
		assert(fired and near(b[1].angle, math.atan2(3, 10)))
		local railFired = MountFire.fire("railgun", ctx("railgun", { crate(10, 0) }))
		assert(not railFired, "the railgun ignores crates")
	end)

	test("mount fire: nothing in range, or too many shots out, means no shot", function()
		local fired, a = MountFire.fire("gatling", ctx("gatling", { bot(W.gatling.range + 5, 0) }))
		assert(not fired and #a == 0)
		local capped = MountFire.fire("gatling", ctx("gatling", { bot(10, 0) }, { robot = robot({ liveProjectiles = Config.Combat.ProjectileCapPerPlayer }) }))
		assert(not capped)
	end)

	test("mount fire: range and shot speed cards scale guns", function()
		local _, a = MountFire.fire("gatling", ctx("gatling", { bot(W.gatling.range + 5, 0) }, { robot = robot({ rangeMult = 1.5, shotSpeedMult = 2 }) }))
		assert(#a == 1 and a[1].range == W.gatling.range * 1.5 + 2 and a[1].speed == W.gatling.speed * 2)
	end)

	test("mount fire: the Rocket Pod fans out more rockets by rank", function()
		local R = W.rocket
		local _, one = MountFire.fire("rocket", ctx("rocket", { bot(20, 0) }))
		assert(#one == 1 and near(one[1].angle, 0))
		local _, three = MountFire.fire("rocket", ctx("rocket", { bot(20, 0) }, { rank = 5, robot = robot({ damageMult = 1.5 }) }))
		assert(#three == 3)
		assert(near(three[1].angle, -math.rad(R.spreadDegrees)) and near(three[3].angle, math.rad(R.spreadDegrees)))
		local o = three[2].opts
		assert(three[2].speed == R.launchSpeed and three[2].range == R.range and o.accel == R.accel and o.maxSpeed == R.speed)
		assert(near(o.splashDamage, R.splashDamage * 1.5 * (1 + R.damagePerRank * 4)) and o.splashRadius == R.splashRadius and o.knockback == R.knockback)
	end)

	test("mount fire: the railgun's shot pierces", function()
		local _, a = MountFire.fire("railgun", ctx("railgun", { bot(50, 0) }))
		assert(#a == 1 and a[1].opts.pierce == true and type(a[1].opts.hitIds) == "table" and a[1].range == W.railgun.range)
	end)

	-- Shock Coil ----------------------------------------------------------------

	test("mount fire: the Shock Coil starts in its arc and chains with falloff", function()
		local S = W.shock
		local list = { bot(10, 0), bot(18, 0), bot(26, 0), bot(34, 0), bot(-5, 0) }
		local fired, a = MountFire.fire("shock", ctx("shock", list, { damage = 20 }))
		assert(fired)
		local hits, beams = only(a, "hit"), only(a, "beam")
		assert(#hits == 1 + S.chains, `{#hits} hits`) -- rank 1: the first bolt plus 2 jumps
		assert(hits[1].target == 1 and hits[1].amount == 20)
		assert(near(hits[2].amount, 20 * S.chainFalloff) and near(hits[3].amount, 20 * S.chainFalloff ^ 2))
		assert(beams[1].first and not beams[2].first and beams[1].x1 == 0 and beams[2].x1 == 10)
		assert(a[1].kind == "beam" and a[2].kind == "hit", "each bolt is drawn, then lands")
		local _, a3 = MountFire.fire("shock", ctx("shock", list, { rank = 3 }))
		assert(#only(a3, "hit") == 2 + S.chains, "one more jump at rank 3")
	end)

	test("mount fire: the Shock Coil needs a target in front to start", function()
		local fired = MountFire.fire("shock", ctx("shock", { bot(-10, 0) }))
		assert(not fired)
	end)

	-- Melee mounts and traps ----------------------------------------------------

	test("mount fire: Minotaur Horns gore robots in front while you drive", function()
		local reach = 2 + W.spikeram.reach
		local fired, a = MountFire.fire("spikeram", ctx("spikeram", { bot(reach, 0), bot(-reach, 0) }))
		assert(fired and #a == 1 and a[1].target == 1 and a[1].knockback == W.spikeram.knockback)
		local slow = MountFire.fire("spikeram", ctx("spikeram", { bot(reach, 0) }, { robot = robot({ speedFraction = W.spikeram.minSpeedFraction - 0.01 }) }))
		assert(not slow, "standing still does nothing")
	end)

	test("mount fire: the horns reach 35 degrees either side, not crates, and need a robot body", function()
		local reach = 2 + W.spikeram.reach
		local function at(deg: number)
			local a = math.rad(deg)
			return { x = math.cos(a) * reach * 0.9, z = math.sin(a) * reach * 0.9, r = 0.05, crate = false }
		end
		local _, a = MountFire.fire("spikeram", ctx("spikeram", { at(30), at(40), { x = 2, z = 0, r = 2, crate = true } }))
		assert(#a == 1 and a[1].target == 1, "30 degrees in, 40 out, crates never")
		assert(not MountFire.fire("spikeram", ctx("spikeram", { at(0) }, { robot = robot({ hasRoot = false }) })))
		assert(not MountFire.fire("traps", ctx("traps", {}, { robot = robot({ hasRoot = false }) })))
	end)

	test("mount fire: one shot under the cap still fires; ties go to the first listed", function()
		local fired, a = MountFire.fire("gatling", ctx("gatling", { bot(10, 3), bot(10, -3) }, { robot = robot({ liveProjectiles = Config.Combat.ProjectileCapPerPlayer - 1 }) }))
		assert(fired and near(a[1].angle, math.atan2(3, 10)))
	end)

	test("mount fire: the Shock Coil hits crates, never one target twice, and jumps behind you", function()
		local _, a = MountFire.fire("shock", ctx("shock", { crate(8, 0), bot(1, 0) }, { rank = 5 }))
		local hits = only(a, "hit")
		assert(#hits == 2 and hits[1].target == 2 and hits[2].target == 1, "the nearest first, then the crate; no repeats")
		local _, b = MountFire.fire("shock", ctx("shock", { bot(4, 0), bot(-4, 0) }))
		assert(#only(b, "hit") == 2, "after the first bolt, jumps go any direction")
	end)

	test("mount fire: an unknown mount kind is an error, not a silent gatling", function()
		assert(not pcall(MountFire.fire, "laser_cannon", ctx("gatling", {})))
	end)

	test("mount fire: the Vertical Saw grinds robots touching you from any side, not crates", function()
		local reach = 2 + W.sidesaw.reach
		local fired, a = MountFire.fire("sidesaw", ctx("sidesaw", { bot(-(reach + 1), 0), crate(1, 0), bot(0, 20) }))
		assert(fired and #a == 1 and a[1].target == 1 and a[1].knockback == nil)
	end)

	test("mount fire: Spike Traps drop behind the way you move, only while moving", function()
		local T = W.traps
		local fired, a = MountFire.fire("traps", ctx("traps", {}, { robot = robot({ vx = 0, vz = 8, facing = 0 }) }))
		local behind = 2 + T.radius * 0.6
		assert(fired and a[1].kind == "trap" and near(a[1].x, 0) and near(a[1].z, -behind))
		local still = MountFire.fire("traps", ctx("traps", {}, { robot = robot({ vx = 1, vz = 0 }) }))
		assert(not still)
	end)
end
