--!strict
-- Derives a robot's live stats from its build and level. Pure: Config is passed in.
-- Every level grows HP, damage and size and costs some speed (D26).

export type Stats = {
	maxHp: number,
	maxArmor: number,
	deflectChance: number,
	speed: number,
	damageMult: number,
	fireRateMult: number,
	rangeMult: number,
	shotSpeedMult: number,
	pickupRadius: number,
	scale: number,
	hitRadius: number,
	mass: number,
	firingSpeedMult: number,
	coneBonus: number, -- Wider Flames: extra cone degrees (D71)
}

local Stats = {}

function Stats.compute(config: any, build: any, level: number): Stats
	local s = build.stacks
	local per = config.StatPerStack
	local growth = config.LevelGrowth
	local function n(id: string): number
		return s[id] or 0
	end
	-- build.chassis is the robot row (Chassis.luau); Rookie defaults without one.
	-- build.small switches to the Bomber's small form (D70).
	local c = Stats.form(build)
	local hpGrowth = 1 + growth.hpPerLevel * level
	local hpBase = (c.hp or config.Robot.MaxHp) + n("stat_hp") * per.stat_hp + n("fb_reinforce") * per.fb_reinforce_hp
	local damageBase = 1 + n("stat_damage") * per.stat_damage + n("fb_reinforce") * per.fb_reinforce_damage
	local speedLevel = math.max(growth.speedFloor, 1 + growth.speedPerLevel * level)
	local maxArmor, deflect = Stats.armorFor(n("stat_armor"), config.Armor)
	local scale = 1 + level * growth.scalePerLevel
	return {
		maxHp = hpBase * hpGrowth,
		-- Built-in armor grows with level like HP; it never deflects (only plating does).
		maxArmor = (c.armor or 0) * hpGrowth + maxArmor,
		deflectChance = deflect,
		speed = (c.speed or config.Robot.MoveSpeed) * (1 + n("stat_speed") * per.stat_speed) * speedLevel,
		damageMult = damageBase * (1 + growth.damagePerLevel * level),
		fireRateMult = 1 + n("stat_firerate") * per.stat_firerate,
		rangeMult = 1 + n("stat_range") * per.stat_range,
		shotSpeedMult = 1 + n("stat_range") * per.stat_range_shotspeed,
		pickupRadius = config.PickupRadius * (1 + n("stat_pickup") * per.stat_pickup),
		scale = scale,
		hitRadius = config.Robot.HitboxRadius * (c.size or 1) * scale,
		mass = c.mass or 1,
		firingSpeedMult = c.firingSpeed or 1,
		coneBonus = n("stat_cone") * (per.stat_cone or 0),
	}
end

-- The robot's row with its current form applied: the Bomber's small form
-- overrides speed, size, mass and armor; everything else stays.
function Stats.form(build: any): any
	local c = build.chassis or {}
	if not (build.small and c.small) then
		return c
	end
	local out = table.clone(c)
	for k, v in c.small do
		out[k] = v
	end
	return out
end

-- Body and hitbox size multiplier for the robot type and form.
function Stats.bodySize(build: any): number
	return Stats.form(build).size or 1
end

-- Walk speed right now: ranged robots are slowed by recoil while firing.
function Stats.moveSpeed(stats: Stats, firing: boolean): number
	return stats.speed * (if firing then stats.firingSpeedMult else 1)
end

-- Visual size steps every 5 levels, so the robot is rebuilt 20 times per life,
-- not 100 (and never resized physically, which caused the level-up glitch).
function Stats.visualScale(config: any, level: number): number
	local step = math.floor(level / 5) * 5
	return 1 + step * config.LevelGrowth.scalePerLevel
end

-- Underdog bonus: a lower-level robot hits a higher-level one harder, so a
-- fresh player can still take down a Lv 100 (D53).
function Stats.underdogFactor(config: any, attackerLevel: number, targetLevel: number): number
	local gap = targetLevel - attackerLevel
	if gap <= 0 then
		return 1
	end
	local u = config.Underdog
	return 1 + math.min(u.cap, gap * u.perLevel)
end

-- Damage per bullet for n barrels, before global stats.
function Stats.barrelFactor(config: any, barrels: number): number
	local f = config.Barrels.damageFactor
	return f[math.clamp(barrels, 1, #f)]
end

-- Random aim deviation (degrees) for a robot moving at speedFraction of its top speed.
function Stats.inaccuracy(config: any, speedFraction: number): number
	return config.Accuracy.baseDegrees + config.Accuracy.movingDegrees * math.clamp(speedFraction, 0, 1)
end

-- Armor and deflect chance from the number of Armor Plating stacks (D33).
function Stats.armorFor(stacks: number, cfg: any): (number, number)
	if stacks <= 0 then
		return 0, 0
	end
	local maxArmor = cfg.firstStack + cfg.perStack * (stacks - 1)
	local deflect = math.min(cfg.deflectCap, cfg.deflectBase + cfg.deflectPerStack * (stacks - 1))
	return maxArmor, deflect
end

-- Damage and fire rate of a mounted weapon at a given rank, before global stats.
function Stats.weaponAtRank(weapon: any, rank: number): (number, number)
	local damage = weapon.damage * (1 + (weapon.damagePerRank or 0) * (rank - 1))
	local fireRate = weapon.fireRate * (1 + (weapon.fireRatePerRank or 0) * (rank - 1))
	return damage, fireRate
end

-- Rocket Pod fires 1 rocket, 2 from rank 3, 3 at rank 5.
function Stats.rocketCount(rank: number): number
	if rank >= 5 then
		return 3
	elseif rank >= 3 then
		return 2
	end
	return 1
end

return Stats
