--!strict
-- Coins, buying and equipping robots (Phase 4a, D73). Pure: the robot rows,
-- Config and Stats are passed in, so Lune tests cover every money rule. The
-- server runs these against the saved profile; clients only display.

export type Data = {
	coins: number,
	owned: { [string]: boolean },
	equipped: string,
}

local Shop = {}

-- A brand-new profile: the free Rookie, equipped, and no coins.
function Shop.template(): Data
	return { coins = 0, owned = { rookie = true }, equipped = "rookie" }
end

-- Adds whole, positive coins only (NaN, negatives and fractions are dropped).
function Shop.addCoins(data: Data, amount: number)
	if amount ~= amount or amount <= 0 then
		return
	end
	data.coins += math.floor(amount)
end

-- Buys a robot: returns true, or false and a reason ("unknown", "soon", "owned", "coins").
function Shop.buy(data: Data, chassis: any): (boolean, string?)
	if not chassis then
		return false, "unknown"
	elseif chassis.comingSoon then
		return false, "soon"
	elseif data.owned[chassis.id] then
		return false, "owned"
	elseif data.coins < chassis.price then
		return false, "coins"
	end
	data.coins -= chassis.price
	data.owned[chassis.id] = true
	return true, nil
end

-- Equips an owned robot (it drives from your next spawn): true, or false and a reason.
function Shop.equip(data: Data, chassis: any): (boolean, string?)
	if not chassis then
		return false, "unknown"
	elseif chassis.comingSoon then
		return false, "soon"
	elseif not data.owned[chassis.id] then
		return false, "locked"
	end
	data.equipped = chassis.id
	return true, nil
end

-- Fixes a loaded profile so it is always valid: whole non-negative coins, the
-- default robot owned, and an equipped robot that exists and is owned.
function Shop.repair(data: any, byId: { [string]: any }, default: string)
	if type(data.coins) ~= "number" or data.coins ~= data.coins or data.coins < 0 then
		data.coins = 0
	end
	data.coins = math.floor(data.coins)
	if type(data.owned) ~= "table" then
		data.owned = {}
	end
	data.owned[default] = true
	local c = byId[data.equipped]
	if not c or c.comingSoon or not data.owned[data.equipped] then
		data.equipped = default
	end
end

local WEAPON_NAMES = {
	blaster = "Blaster",
	launcher = "Rockets",
	buzzsaw = "Buzzsaw",
	flamer = "Flamethrower",
	netgun = "Net gun",
}

local function num(n: number): string
	return string.format("%g", math.floor(n * 10 + 0.5) / 10)
end

export type Card = { hp: number, armor: number, speed: number, range: number, attack: string }

-- What the garage shows for a robot at Lv 0: toughness, speed, reach and its attack.
function Shop.card(config: any, stats: any, chassis: any): Card
	local s = stats.compute(config, { stacks = {}, chassis = chassis }, 0)
	local p = chassis.primary
	local w = config.Weapons[p.weapon]
	local name = WEAPON_NAMES[p.weapon] or p.weapon
	local range, attack
	if p.kind == "melee" then
		range = w.reach + s.hitRadius
		attack = `{name}: {num(w.damage)} damage, {num(w.fireRate)} swings/s`
	elseif p.kind == "cone" then
		range = w.range
		attack = `{name}: {num(w.damagePerTick * w.fireRate)} damage/s and sets robots burning`
	elseif p.kind == "net" then
		range = w.range
		attack = `{name}: no damage; netted robots drive at {math.floor(w.netSlow * 100)}% for {num(w.netDuration)} s. Space blows up`
	elseif p.kind == "rocket" then
		range = w.range
		attack = `{name}: {num(w.damage)} damage + {num(w.splashDamage)} splash, {num(w.fireRate)}/s`
	else
		range = w.range
		attack = `{name}: {num(w.damage)} damage, {num(w.fireRate)} shots/s`
	end
	return { hp = s.maxHp, armor = s.maxArmor, speed = s.speed, range = range, attack = attack }
end

return Shop
