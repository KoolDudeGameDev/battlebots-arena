--!strict
-- Builds a level-up offer of exactly three distinct cards (GDD section 13).
-- Pure: the upgrade table and the random source are passed in.

export type Build = {
	stacks: { [string]: number }, -- stat stacks, weapon ranks, modifiers, fallback counts
	mounts: { string }, -- weapon ids in socket order
	skill: string?,
	skillRank: number,
	tags: { string }?, -- the robot's tags (Chassis.tags)
}

export type Card = {
	id: string,
	kind: "new" | "rank" | "replace" | "fallback",
	rank: number, -- the stack or rank you will have after picking
	replaces: string?,
	category: string,
	rarity: string,
	name: string,
	text: string,
	weight: number,
	tags: { string },
	earlyBoost: number?,
}

type Def = {
	id: string,
	name: string,
	category: string,
	rarity: string,
	weight: number,
	max: number,
	minLevel: number,
	tags: { string },
	text: string,
}

-- `any` on purpose: the Upgrades module's literal-typed rows would not match an
-- exact copy of its type, and this module must not require it (Lune tests).
type Defs = any

local MAX_MOUNTS = 3
local CATEGORY_CAP = 2
local SYNERGY_CAP = 4
local NEED_MULT = 3
local REPLACE_WEIGHT = 0.5 -- swapping your skill is offered at half weight (D32)

local OfferGenerator = {}

local function card(def: Def, kind, rank: number, replaces: string?): Card
	return {
		id = def.id,
		kind = kind,
		rank = rank,
		replaces = replaces,
		category = def.category,
		rarity = def.rarity,
		name = def.name,
		text = def.text,
		weight = if kind == "replace" then def.weight * REPLACE_WEIGHT else def.weight,
		tags = def.tags,
		earlyBoost = (def :: any).earlyBoost,
	}
end

-- Every non-fallback card the player could pick right now.
function OfferGenerator.eligible(defs: Defs, build: Build, level: number): { Card }
	local out: { Card } = {}
	local tags = build.tags or {}
	for _, def in defs.list do
		local owned = build.stacks[def.id] or 0
		local cat = def.category
		if cat == "Fallback" or level < def.minLevel then
			continue
		end
		if def.requiresTag and not table.find(tags, def.requiresTag) then
			continue -- e.g. barrels and Ricochet need a projectile main gun
		end
		if def.excludes then
			local clash = false
			for _, id in def.excludes do
				if (build.stacks[id] or 0) > 0 then
					clash = true
				end
			end
			if clash then
				continue -- e.g. one weapon variant per life
			end
		end
		if def.requiresAnyTag then
			local fits = false
			for _, tag in def.requiresAnyTag do
				if table.find(tags, tag) then
					fits = true
				end
			end
			if not fits then
				continue -- mount pools (D69): no guns on melee robots
			end
		end
		if def.requires then
			local missing = false
			for id, minStacks in def.requires do
				if (build.stacks[id] or 0) < minStacks then
					missing = true
				end
			end
			if missing then
				continue
			end
		end
		if cat == "Stat" or cat == "Modifier" then
			if owned < def.max then
				table.insert(out, card(def, if owned > 0 then "rank" else "new", owned + 1))
			end
		elseif cat == "Weapon" then
			if owned > 0 then
				if owned < def.max then
					table.insert(out, card(def, "rank", owned + 1))
				end
			elseif #build.mounts < MAX_MOUNTS then
				table.insert(out, card(def, "new", 1))
			end
		elseif cat == "Skill" then
			if build.skill == def.id then
				if build.skillRank < def.max then
					table.insert(out, card(def, "rank", build.skillRank + 1))
				end
			elseif build.skill ~= nil then
				local current = defs.byId[build.skill] :: any
				if not (current and current.locked) then -- the Bomber's bomb is never swapped out
					table.insert(out, card(def, "replace", 1, build.skill))
				end
			else
				table.insert(out, card(def, "new", 1))
			end
		end
	end
	-- Card wording that fits the robot's weapon (D71).
	for _, c in out do
		local byTag = (defs.byId[c.id] :: any).textByTag
		if byTag then
			for tag, text in byTag do
				if table.find(tags, tag) then
					c.text = text
				end
			end
		end
	end
	return out
end

local function ownedTagStacks(defs: Defs, build: Build): { [string]: number }
	local counts: { [string]: number } = {}
	local function add(id: string, n: number)
		local def = defs.byId[id]
		if def then
			for _, tag in def.tags do
				counts[tag] = (counts[tag] or 0) + n
			end
		end
	end
	for id, n in build.stacks do
		add(id, n)
	end
	if build.skill then
		add(build.skill, build.skillRank)
	end
	return counts
end

local function pickWeighted(candidates: { Card }, weightOf: (Card) -> number, rand: () -> number): Card
	local total = 0
	for _, c in candidates do
		total += weightOf(c)
	end
	local roll = rand() * total
	for _, c in candidates do
		roll -= weightOf(c)
		if roll < 0 then
			return c
		end
	end
	return candidates[#candidates]
end

function OfferGenerator.generate(defs: Defs, build: Build, level: number, rand: () -> number): { Card }
	local pool = OfferGenerator.eligible(defs, build, level)
	local tagStacks = ownedTagStacks(defs, build)

	local weightFor = {
		synergy = function(c: Card): number
			local bonus = 0
			for _, tag in c.tags do
				bonus += tagStacks[tag] or 0
			end
			return c.weight * (1 + math.min(SYNERGY_CAP, bonus))
		end,
		need = function(c: Card): number
			-- Only weapons get a "need" boost; skills stay rare on purpose (D32),
			-- except the anti-bullying Earth Wall for new players (D42).
			if c.category == "Weapon" and #build.mounts == 0 and level >= 6 then
				return c.weight * NEED_MULT
			elseif c.earlyBoost and build.skill == nil and level < 10 then
				return c.weight * c.earlyBoost
			end
			return c.weight
		end,
		wild = function(c: Card): number
			return c.weight
		end,
	}

	local chosen: { Card } = {}
	local chosenIds: { [string]: boolean } = {}
	local catCount: { [string]: number } = {}

	for _, slot in { "synergy", "need", "wild" } do
		local candidates = {}
		for _, c in pool do
			if not chosenIds[c.id] and (catCount[c.category] or 0) < CATEGORY_CAP then
				table.insert(candidates, c)
			end
		end
		if #candidates == 0 then
			for _, c in pool do
				if not chosenIds[c.id] then
					table.insert(candidates, c)
				end
			end
		end
		if #candidates == 0 then
			for _, def in defs.list do
				if def.category == "Fallback" and not chosenIds[def.id] then
					table.insert(candidates, card(def, "fallback", (build.stacks[def.id] or 0) + 1))
				end
			end
		end
		local pick = pickWeighted(candidates, weightFor[slot], rand)
		table.insert(chosen, pick)
		chosenIds[pick.id] = true
		catCount[pick.category] = (catCount[pick.category] or 0) + 1
	end

	-- Shuffle so players cannot learn which position is the synergy slot.
	for i = #chosen, 2, -1 do
		local j = 1 + math.floor(rand() * i)
		chosen[i], chosen[j] = chosen[j], chosen[i]
	end
	return chosen
end

return OfferGenerator
