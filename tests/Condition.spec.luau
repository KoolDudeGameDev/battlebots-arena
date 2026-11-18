-- A robot's Condition (D90): its health-side state and the rules for hits, healing and
-- burn. These pin the behaviour Combat.damage and tickSustain had before the move.
local Condition = require("../src/shared/Condition")
local Stats = require("../src/shared/Stats")
local Config = require("../src/shared/Config")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local LIMITS = { maxHp = 100, maxArmor = 0, maxGuard = 0, deflectChance = 0, armorRegenDelay = 4.5 }

local function limits(over: { [string]: number }?)
	local l = table.clone(LIMITS)
	for k, v in over or {} do
		l[k] = v
	end
	return l
end

-- A direct (non-splash) hit at t = 10 that never deflects, unless overridden.
local function hit(amount: number, over: { [string]: any }?)
	local h = { amount = amount, splash = false, t = 10, roll = 0.99, protected = false, shielded = false, fromFront = false, scale = 1, shell = false }
	for k, v in over or {} do
		h[k] = v
	end
	return h
end

return function(test)
	-- Hits ----------------------------------------------------------------------

	test("condition: no armor, all damage goes to health", function()
		local s = Condition.new(100)
		local r = Condition.hit(s, hit(30), LIMITS, Config)
		assert(r.stage == "landed" and s.hp == 70 and r.hpTaken == 30 and r.armorTaken == 0 and not r.deflected and not r.died)
		assert(s.lastHitAt == 10, "a landed hit stamps lastHitAt")
	end)

	test("condition: armor absorbs first and overflow reaches health", function()
		local s = Condition.new(100)
		s.armor = 20
		local r = Condition.hit(s, hit(30), limits({ maxArmor = 20, deflectChance = 0.1 }), Config)
		assert(s.hp == 90 and s.armor == 0 and r.armorTaken == 20 and r.hpTaken == 10, `{s.hp} {s.armor}`)
	end)

	test("condition: a low roll deflects while armor is up, and still counts as a hit", function()
		local s = Condition.new(100)
		s.armor = 20
		local r = Condition.hit(s, hit(30, { roll = 0.05 }), limits({ maxArmor = 20, deflectChance = 0.1 }), Config)
		assert(r.deflected and s.hp == 100 and s.armor == 20)
		assert(s.lastHitAt == 10, "deflects still delay armor regen")
	end)

	test("condition: no deflect without armor, and never on splash", function()
		local s = Condition.new(100)
		local r = Condition.hit(s, hit(30, { roll = 0 }), limits({ deflectChance = 0.3 }), Config)
		assert(not r.deflected, "no armor")
		local s2 = Condition.new(100)
		s2.armor = 50
		local r2 = Condition.hit(s2, hit(30, { roll = 0, splash = true }), limits({ maxArmor = 50, deflectChance = 0.3 }), Config)
		assert(not r2.deflected and s2.armor == 20, "splash")
	end)

	test("condition: Armor Pod armor goes before plating", function()
		local s = Condition.new(100)
		s.armor, s.tempArmor = 30, 20
		Condition.hit(s, hit(35), limits({ maxArmor = 30 }), Config)
		assert(s.tempArmor == 0 and s.armor == 15 and s.hp == 100, `{s.tempArmor} {s.armor} {s.hp}`)
	end)

	test("condition: Armor Pod armor alone deflects at tempDeflect", function()
		local s = Condition.new(100)
		s.tempArmor = 50
		local r = Condition.hit(s, hit(30, { roll = Config.Armor.tempDeflect - 0.01 }), LIMITS, Config)
		assert(r.deflected)
		local r2 = Condition.hit(s, hit(30, { roll = Config.Armor.tempDeflect + 0.01 }), LIMITS, Config)
		assert(not r2.deflected and s.tempArmor == 20)
	end)

	test("condition: plating's own deflect chance wins over the Armor Pod's", function()
		local s = Condition.new(100)
		s.armor, s.tempArmor = 30, 50
		local roll = Config.Armor.tempDeflect + 0.05 -- above the pod's chance, under the plating's
		local r = Condition.hit(s, hit(30, { roll = roll }), limits({ maxArmor = 30, deflectChance = roll + 0.05 }), Config)
		assert(r.deflected)
	end)

	test("condition: spawn protection ignores the hit entirely", function()
		local s = Condition.new(100)
		local r = Condition.hit(s, hit(30, { protected = true }), LIMITS, Config)
		assert(r.stage == "ignored" and s.hp == 100 and s.lastHitAt == -math.huge)
	end)

	test("condition: Shield Pulse blocks direct hits and halves splash", function()
		local s = Condition.new(100)
		local r = Condition.hit(s, hit(30, { shielded = true }), LIMITS, Config)
		assert(r.stage == "ignored" and s.hp == 100)
		Condition.hit(s, hit(30, { shielded = true, splash = true }), LIMITS, Config)
		assert(near(s.hp, 100 - 30 * Config.Combat.ShieldSplashFactor), tostring(s.hp))
	end)

	test("condition: the front shield soaks direct hits from the front first", function()
		local s = Condition.new(100)
		s.guardHp = 50
		local r = Condition.hit(s, hit(30, { fromFront = true }), limits({ maxGuard = 60 }), Config)
		assert(r.stage == "guarded" and r.guardAbsorbed == 30 and s.guardHp == 20 and s.hp == 100 and s.guardHitAt == 10)
		assert(s.lastHitAt == -math.huge, "a hit the front shield stops entirely never reaches the hull")
		local r2 = Condition.hit(s, hit(30, { fromFront = true }), limits({ maxGuard = 60 }), Config)
		assert(r2.stage == "landed" and r2.guardAbsorbed == 20 and s.guardHp == 0 and s.hp == 90)
	end)

	test("condition: the front shield ignores splash and hits from behind", function()
		local s = Condition.new(100)
		s.guardHp = 50
		Condition.hit(s, hit(30, { fromFront = false }), limits({ maxGuard = 60 }), Config)
		Condition.hit(s, hit(10, { fromFront = true, splash = true }), limits({ maxGuard = 60 }), Config)
		assert(s.guardHp == 50 and s.hp == 60)
	end)

	test("condition: the attacker's scale applies after the front shield", function()
		local s = Condition.new(100)
		s.guardHp = 10
		Condition.hit(s, hit(30, { fromFront = true, scale = 2 }), limits({ maxGuard = 60 }), Config)
		assert(s.hp == 60, "(30 - 10) x 2 = 40") -- the underdog bonus multiplies what gets past the shield
	end)

	test("condition: the Bomber shell's plating cuts splash only", function()
		local s = Condition.new(100)
		Condition.hit(s, hit(100, { splash = true, shell = true }), limits({ maxHp = 200 }), Config)
		assert(near(s.hp, 100 - 100 * (1 - Config.Bomber.plating)), tostring(s.hp))
		local s2 = Condition.new(100)
		Condition.hit(s2, hit(40, { shell = true }), LIMITS, Config)
		assert(s2.hp == 60, "direct hits are not plated")
	end)

	test("condition: health stops at 0 and the robot dies", function()
		local s = Condition.new(20)
		local r = Condition.hit(s, hit(50), LIMITS, Config)
		assert(r.died and s.hp == 0 and r.hpTaken == 50)
	end)

	-- Ticks ---------------------------------------------------------------------

	test("condition: armor regenerates only after the regen delay since the last hit", function()
		local s = Condition.new(100)
		s.armor, s.lastHitAt = 0, 10
		local L = limits({ maxArmor = 50, armorRegenDelay = 4.5 })
		local early = Condition.tick(s, 14, 1, L, Config)
		assert(s.armor == 0 and not early.armorChanged)
		local late = Condition.tick(s, 14.5, 1, L, Config)
		assert(late.armorChanged and near(s.armor, 50 * Config.Armor.regenPerSecond))
	end)

	test("condition: the front shield recharges after its own delay", function()
		local s = Condition.new(100)
		s.guardHp, s.guardHitAt = 0, 10
		local W = Config.Weapons.shieldgen
		local L = limits({ maxGuard = 60 })
		assert(not Condition.tick(s, 10 + W.regenDelay - 0.1, 1, L, Config).guardChanged)
		local r = Condition.tick(s, 10 + W.regenDelay, 1, L, Config)
		assert(r.guardChanged and near(s.guardHp, 60 * W.regenPerSecond))
	end)

	test("condition: Armor Pod armor and Fortify expire on time", function()
		local s = Condition.new(100)
		s.tempArmor, s.tempArmorUntil = 50, 20
		s.bonusHp, s.bonusHpUntil = 60, 30
		local a = Condition.tick(s, 20, 0.1, LIMITS, Config)
		assert(s.tempArmor == 0 and a.armorChanged and not a.bonusExpired)
		local b = Condition.tick(s, 30, 0.1, LIMITS, Config)
		assert(s.bonusHp == 0 and b.bonusExpired)
	end)

	test("condition: a Regen Pod heals up to max HP", function()
		local s = Condition.new(100)
		s.hp, s.regenUntil, s.regenRate = 50, 20, 10
		local r = Condition.tick(s, 10, 1, LIMITS, Config)
		assert(r.hpChanged and s.hp == 60)
		s.hp = 98
		Condition.tick(s, 11, 1, LIMITS, Config)
		assert(s.hp == 100)
		assert(not Condition.tick(s, 21, 1, LIMITS, Config).hpChanged, "over")
	end)

	test("condition: burn lands in chunks for its source, then stops", function()
		local s = Condition.new(100)
		Condition.ignite(s, 13, 8, 42)
		local r = Condition.tick(s, 10, 0.25, LIMITS, Config)
		assert(r.burning and r.burnDamage == 0)
		local r2 = Condition.tick(s, 10.25, 0.25, LIMITS, Config)
		assert(near(r2.burnDamage, 8 * Config.Combat.BurnTick) and r2.burnSourceId == 42, tostring(r2.burnDamage))
		assert(s.hp == 100, "the caller routes burn damage as a hit")
		local done = Condition.tick(s, 13, 0.25, LIMITS, Config)
		assert(not done.burning and done.burnDamage == 0 and s.burnAcc == 0)
	end)

	-- Pods, healing and direct changes ------------------------------------------

	test("condition: pods heal, regenerate, plate and fortify", function()
		local P = Config.Pods
		local s = Condition.new(100)
		s.hp = 50
		Condition.pod(s, "health", 10, LIMITS, Config)
		assert(near(s.hp, 50 + 100 * P.health.heal))
		Condition.pod(s, "regen", 10, LIMITS, Config)
		assert(s.regenUntil == 10 + P.regen.duration and near(s.regenRate, 100 * P.regen.heal / P.regen.duration))
		Condition.pod(s, "armor", 10, limits({ maxArmor = 40 }), Config)
		assert(s.armor == 40 and s.tempArmor == P.armor.tempArmor and s.tempArmorUntil == 10 + P.armor.duration)
		s.hp = 100
		local changed = Condition.pod(s, "fortify", 10, LIMITS, Config)
		assert(changed and s.bonusHp == P.fortify.bonusHp and s.bonusHpUntil == 10 + P.fortify.duration)
		assert(s.hp == 100 + P.fortify.bonusHp, "the bonus arrives filled")
		Condition.pod(s, "fortify", 20, limits({ maxHp = 100 + P.fortify.bonusHp }), Config)
		assert(s.hp == 100 + P.fortify.bonusHp and s.bonusHpUntil == 20 + P.fortify.duration, "a second pickup only refreshes the timer")
		local hurt = Condition.new(100)
		hurt.hp = 40
		Condition.pod(hurt, "fortify", 10, LIMITS, Config)
		assert(hurt.hp == 40 + P.fortify.bonusHp, "a hurt robot gets the bonus on top of what it has")
	end)

	test("condition: heal clamps to max; set and clamp change values directly", function()
		local s = Condition.new(100)
		s.hp = 90
		Condition.heal(s, 30, 100)
		assert(s.hp == 100)
		Condition.set(s, { hp = 1, armor = 0, tempArmor = 0 })
		assert(s.hp == 1 and s.armor == 0 and s.tempArmor == 0)
		s.hp, s.armor = 150, 80
		Condition.clamp(s, 100, 50)
		assert(s.hp == 100 and s.armor == 50)
	end)

	test("condition: a new condition is full and quiet", function()
		local s = Condition.new(120)
		assert(s.hp == 120 and s.armor == 0 and s.tempArmor == 0 and s.guardHp == 0 and s.burnUntil == 0 and s.burnSourceId == nil)
		assert(s.lastHitAt == -math.huge and s.guardHitAt == -math.huge)
	end)

	test("armor plating: 30 then +20 per stack, deflect capped at 30%", function()
		local a0, d0 = Stats.armorFor(0, Config.Armor)
		assert(a0 == 0 and d0 == 0)
		local a1, d1 = Stats.armorFor(1, Config.Armor)
		assert(a1 == 30 and math.abs(d1 - 0.10) < 1e-9, `{a1} {d1}`)
		local a5, d5 = Stats.armorFor(5, Config.Armor)
		assert(a5 == 110 and math.abs(d5 - 0.30) < 1e-9, `{a5} {d5}`)
		local _, d9 = Stats.armorFor(9, Config.Armor)
		assert(math.abs(d9 - 0.30) < 1e-9, "cap")
	end)
end
