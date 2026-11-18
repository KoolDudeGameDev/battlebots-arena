--!strict
-- A robot's Condition (D90): its health-side state (health, armor, Armor Pod armor,
-- the Shield Generator's front shield, Regen Pod, Fortify, burn) and the rules for
-- hits, healing and burn. The only module that changes these values. Pure: Config,
-- the time, the deflect roll and the robot's limits are passed in, so Lune tests it.
--
-- Callers decide the attacker and map rules (no friendly fire in boss arenas, the
-- underdog bonus) and apply what comes back (attributes, hit numbers, kill credit).

export type State = {
	hp: number,
	armor: number, -- Armor Plating; regenerates (D33)
	tempArmor: number, -- Armor Pod; goes first, expires at tempArmorUntil
	tempArmorUntil: number,
	regenUntil: number, -- Regen Pod heal-over-time window
	regenRate: number, -- HP per second while regenerating
	bonusHp: number, -- Fortify Pod: flat extra max HP until bonusHpUntil (D54)
	bonusHpUntil: number,
	burnUntil: number, -- set alight by flames, a boss or lava (D44)
	burnDps: number,
	burnSourceId: number?,
	burnAcc: number,
	guardHp: number, -- Shield Generator front shield (D69)
	guardHitAt: number,
	lastHitAt: number, -- last hit that reached the hull (delays armor regen)
}

-- What the robot's build allows right now (from its stats and chassis).
export type Limits = {
	maxHp: number,
	maxArmor: number,
	maxGuard: number,
	deflectChance: number,
	armorRegenDelay: number,
}

export type Hit = {
	amount: number,
	splash: boolean, -- explosions, flames, burn: never deflect, pass the front shield
	t: number,
	roll: number, -- random in [0, 1) for the deflect
	protected: boolean, -- spawn protection, god mode, already dead
	shielded: boolean, -- Shield Pulse is up
	fromFront: boolean, -- came from an attacker inside the front shield's arc
	scale: number, -- the attacker's multiplier (underdog bonus), after the front shield
	shell: boolean, -- a Bomber shell: plating cuts splash (D84)
}

-- stage: "ignored" (nothing happened), "guarded" (the front shield took it all) or
-- "landed" (it reached the armor and health; it may still have deflected).
export type HitResult = {
	stage: string,
	guardAbsorbed: number,
	deflected: boolean,
	armorTaken: number,
	hpTaken: number,
	died: boolean,
}

export type TickResult = {
	hpChanged: boolean,
	armorChanged: boolean,
	guardChanged: boolean,
	bonusExpired: boolean, -- Fortify ran out: the caller recomputes max HP
	burning: boolean,
	burnDamage: number, -- route it as a splash hit from burnSourceId
	burnSourceId: number?,
}

local Condition = {}

function Condition.new(hp: number): State
	return {
		hp = hp,
		armor = 0,
		tempArmor = 0,
		tempArmorUntil = 0,
		regenUntil = 0,
		regenRate = 0,
		bonusHp = 0,
		bonusHpUntil = 0,
		burnUntil = 0,
		burnDps = 0,
		burnSourceId = nil,
		burnAcc = 0,
		guardHp = 0,
		guardHitAt = -math.huge,
		lastHitAt = -math.huge,
	}
end

-- How one hit lands (D33, D69, D84): protection, Shield Pulse, front shield, the
-- attacker's scale, shell plating, then armor (Armor Pod first) with a deflect chance
-- on direct hits, then health.
function Condition.hit(s: State, h: Hit, limits: Limits, cfg: any): HitResult
	local result: HitResult = { stage = "ignored", guardAbsorbed = 0, deflected = false, armorTaken = 0, hpTaken = 0, died = false }
	if h.protected then
		return result
	end
	local amount = h.amount
	if h.shielded then
		if not h.splash then
			return result
		end
		amount *= cfg.Combat.ShieldSplashFactor
	end
	if not h.splash and h.fromFront and s.guardHp > 0 then
		local absorbed = math.min(s.guardHp, amount)
		s.guardHp -= absorbed
		s.guardHitAt = h.t
		amount -= absorbed
		result.guardAbsorbed = absorbed
		if amount <= 0 then
			result.stage = "guarded"
			return result
		end
	end
	result.stage = "landed"
	amount *= h.scale
	if h.splash and h.shell then
		amount *= 1 - cfg.Bomber.plating
	end

	local chance = limits.deflectChance
	if chance <= 0 and s.tempArmor > 0 then
		chance = cfg.Armor.tempDeflect
	end
	s.lastHitAt = h.t
	local armor = s.armor + s.tempArmor
	if not h.splash and armor > 0 and h.roll < chance then
		result.deflected = true
		return result
	end
	local armorTaken = math.min(armor, amount)
	local hpTaken = amount - armorTaken
	local fromTemp = math.min(s.tempArmor, armorTaken) -- Armor Pod armor goes first
	s.tempArmor -= fromTemp
	s.armor = math.max(0, s.armor - (armorTaken - fromTemp))
	s.hp -= hpTaken
	result.armorTaken, result.hpTaken = armorTaken, hpTaken
	if s.hp <= 0 then
		s.hp = 0
		result.died = true
	end
	return result
end

-- One frame of recovery and burn: front shield and armor regen after their delays,
-- Armor Pod and Fortify expiry, Regen Pod healing, burn in BurnTick-sized chunks.
function Condition.tick(s: State, t: number, dt: number, limits: Limits, cfg: any): TickResult
	local r: TickResult = { hpChanged = false, armorChanged = false, guardChanged = false, bonusExpired = false, burning = false, burnDamage = 0, burnSourceId = nil }
	local G = cfg.Weapons.shieldgen
	if limits.maxGuard > 0 and s.guardHp < limits.maxGuard and t - s.guardHitAt >= G.regenDelay then
		s.guardHp = math.min(limits.maxGuard, s.guardHp + limits.maxGuard * G.regenPerSecond * dt)
		r.guardChanged = true
	end
	if limits.maxArmor > 0 and s.armor < limits.maxArmor and t - s.lastHitAt >= limits.armorRegenDelay then
		s.armor = math.min(limits.maxArmor, s.armor + limits.maxArmor * cfg.Armor.regenPerSecond * dt)
		r.armorChanged = true
	end
	if s.tempArmor > 0 and t >= s.tempArmorUntil then
		s.tempArmor = 0
		r.armorChanged = true
	end
	if s.bonusHp > 0 and t >= s.bonusHpUntil then
		s.bonusHp = 0
		r.bonusExpired = true
	end
	if t < s.regenUntil and s.hp < limits.maxHp then
		s.hp = math.min(limits.maxHp, s.hp + s.regenRate * dt)
		r.hpChanged = true
	end
	r.burning = t < s.burnUntil
	if r.burning then
		s.burnAcc += s.burnDps * dt
		if s.burnAcc >= s.burnDps * cfg.Combat.BurnTick then
			r.burnDamage, r.burnSourceId = s.burnAcc, s.burnSourceId
			s.burnAcc = 0
		end
	else
		s.burnAcc = 0
	end
	return r
end

-- Sets the robot alight until `untilT` (a new flame replaces the old burn).
function Condition.ignite(s: State, untilT: number, dps: number, sourceId: number?)
	s.burnUntil, s.burnDps, s.burnSourceId = untilT, dps, sourceId
end

-- Booster pods (D34, D41, D54). Returns true when max HP changed (Fortify): the
-- caller recomputes stats.
function Condition.pod(s: State, kind: string, t: number, limits: Limits, cfg: any): boolean
	local P = cfg.Pods
	if kind == "health" then
		s.hp = math.min(limits.maxHp, s.hp + limits.maxHp * P.health.heal)
	elseif kind == "regen" then
		s.regenUntil = t + P.regen.duration
		s.regenRate = limits.maxHp * P.regen.heal / P.regen.duration
	elseif kind == "armor" then
		s.armor = limits.maxArmor
		s.tempArmor = P.armor.tempArmor
		s.tempArmorUntil = t + P.armor.duration
	elseif kind == "fortify" then
		-- Flat bonus max HP, arriving filled. Re-picking refreshes the timer.
		local added = P.fortify.bonusHp - s.bonusHp
		s.bonusHp = P.fortify.bonusHp
		s.bonusHpUntil = t + P.fortify.duration
		s.hp = math.min(limits.maxHp + added, s.hp + added)
		return true
	end
	return false
end

-- Heals by `amount`, never above maxHp.
function Condition.heal(s: State, amount: number, maxHp: number)
	s.hp = math.min(maxHp, s.hp + amount)
end

-- Direct changes decided elsewhere (level growth, the Bomber's blast and rebuild,
-- dummies, a beaten boss, debug commands).
function Condition.set(s: State, values: { hp: number?, armor: number?, tempArmor: number? })
	if values.hp then
		s.hp = values.hp
	end
	if values.armor then
		s.armor = values.armor
	end
	if values.tempArmor then
		s.tempArmor = values.tempArmor
	end
end

-- Keeps health and armor within new maximums (after stats change).
function Condition.clamp(s: State, maxHp: number, maxArmor: number)
	s.hp = math.min(s.hp, maxHp)
	s.armor = math.min(s.armor, maxArmor)
end

return Condition
