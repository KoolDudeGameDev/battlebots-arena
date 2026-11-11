-- Duel model: a close-range robot charges a ranged robot across open ground
-- (no cover), starting at the edge of the ranged robot's range. Expected values,
-- no dice, 60 steps per second. Uses the real Config, Chassis and Stats, so a
-- tuning change shows up here. Print the table: lune run tests/duel-table

local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Combat2D = require("../src/shared/Combat2D")
local Stats = require("../src/shared/Stats")

local DT = 1 / 60
local MAX_TIME = 60

local Duel = {}

local function fighter(id: string, level: number)
	local c = Chassis.byId[id]
	local s = Stats.compute(Config, { stacks = {}, chassis = c }, level)
	local p = c.primary :: Chassis.Primary
	return {
		kind = p.kind,
		w = Config.Weapons[p.weapon],
		s = s,
		hp = s.maxHp,
		armor = s.maxArmor,
		nextAt = 0,
		burnUntil = -1,
		burnDps = 0,
	}
end

function Duel.isRanged(id: string): boolean
	local p = Chassis.byId[id].primary :: Chassis.Primary
	return p.kind == "projectile" or p.kind == "rocket"
end

-- Close-range fighters the duel model covers (the Bomber's net and bomb are not modelled).
function Duel.isClose(id: string): boolean
	local p = Chassis.byId[id].primary :: Chassis.Primary
	return p.kind == "melee" or p.kind == "cone"
end

-- How far f's weapon reaches, centre to centre, against target t (as in Combat).
function Duel.reach(f, t): number
	local w, s = f.w, f.s
	if f.kind == "melee" then
		return w.reach * s.scale + s.hitRadius + t.s.hitRadius
	elseif f.kind == "cone" then
		return w.range * s.rangeMult + s.hitRadius + t.s.hitRadius
	end
	return w.range * s.rangeMult + (1.2 + Config.Robot.BarrelLength) * s.scale + t.s.hitRadius
end

local function hurt(f, amount: number)
	local a = math.min(f.armor, amount)
	f.armor -= a
	f.hp -= amount - a
end

local function health(f): number
	return math.max(0, f.hp + f.armor) / (f.s.maxHp + f.s.maxArmor)
end

-- Expected damage and push of one shot from gun robot f at distance d.
local function shot(f, t, d: number, speedFraction: number): (number, number)
	local w, s = f.w, f.s
	local dev = Stats.inaccuracy(Config, speedFraction)
	local half = math.deg(math.atan(t.s.hitRadius / d))
	local p = math.clamp(half / dev, 0, 1)
	local direct = w.damage * s.damageMult
	local push = Combat2D.knockback(w.knockback or 0, t.s.scale, t.s.mass)
	if not w.splashRadius then
		return p * direct, 0
	end
	-- A near miss still lands splash, at the average miss angle.
	local miss = d * math.tan(math.rad((half + dev) / 2)) - t.s.hitRadius
	local falloff = if miss <= w.splashRadius then Combat2D.splashFactor(math.max(0, miss), w.splashRadius, Config.Combat.SplashEdge) else 0
	local splash = w.splashDamage * s.damageMult * falloff
	return p * direct + (1 - p) * splash, push * (p + (1 - p) * falloff)
end

-- Returns "ranged" or "close" (or "draw"), the winner's health left (0..1) and the seconds it took.
function Duel.run(rangedId: string, closeId: string, level: number, kite: boolean): (string, number, number)
	local r, c = fighter(rangedId, level), fighter(closeId, level)
	local d = Duel.reach(r, c)
	local contact = r.s.hitRadius + c.s.hitRadius
	local t = 0
	while t < MAX_TIME do
		t += DT
		-- Movement: the ranged robot backs off while firing (recoil-slowed); the other chases.
		local rSpeed = if kite then Stats.moveSpeed(r.s, true) else 0
		d += rSpeed * DT
		d -= math.min(Stats.moveSpeed(c.s, true) * DT, math.max(0, d - contact))

		if t >= r.nextAt and d <= Duel.reach(r, c) then
			r.nextAt = t + 1 / r.w.fireRate
			local dmg, push = shot(r, c, d, rSpeed / r.s.speed)
			hurt(c, dmg)
			d += push
		end
		if t >= c.nextAt and d <= Duel.reach(c, r) then
			c.nextAt = t + 1 / c.w.fireRate
			if c.kind == "melee" then
				hurt(r, c.w.damage * c.s.damageMult)
				d += Combat2D.knockback(c.w.knockback, r.s.scale, r.s.mass)
			else
				hurt(r, c.w.damagePerTick * c.s.damageMult)
				r.burnUntil, r.burnDps = t + c.w.burnDuration, c.w.burnDps * c.s.damageMult
			end
		end
		if t < r.burnUntil then
			hurt(r, r.burnDps * DT)
		end

		if c.hp <= 0 then
			return "ranged", health(r), t
		elseif r.hp <= 0 then
			return "close", health(c), t
		end
	end
	return "draw", 0, t
end

return Duel
