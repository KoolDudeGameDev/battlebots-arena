local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

-- Deterministic LCG so tests do not depend on a Random global.
local function rng(seed: number): () -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function()
		state = (state * 16807) % 2147483647
		return (state - 1) / 2147483646
	end
end

local function emptyBuild()
	-- A Rookie: gun mounts (D69).
	return { stacks = {}, mounts = {}, skill = nil, skillRank = 0, tags = { "projectile_primary", "blaster_primary", "gun_mounts" } }
end

local function ids(cards)
	local out = {}
	for _, c in cards do
		table.insert(out, c.id)
	end
	return table.concat(out, ",")
end

local function randomBuild(r: () -> number, level: number)
	local b = emptyBuild()
	for _, def in Upgrades.list do
		if def.category == "Stat" then
			b.stacks[def.id] = math.floor(r() * (def.max + 1))
		elseif def.category == "Weapon" and r() < 0.5 and level >= def.minLevel then
			b.stacks[def.id] = 1 + math.floor(r() * def.max)
			table.insert(b.mounts, def.id)
		elseif def.category == "Modifier" and r() < 0.3 and level >= def.minLevel then
			b.stacks[def.id] = 1
		end
	end
	if r() < 0.6 then
		b.skill = if r() < 0.5 then "skl_dash" else "skl_shield"
		b.skillRank = 1 + math.floor(r() * 3)
	end
	return b
end

return function(test)
	test("level 1 offer: 3 distinct cards, no level-gated items", function()
		local cards = OfferGenerator.generate(Upgrades, emptyBuild(), 1, rng(1))
		assert(#cards == 3, "count " .. #cards)
		local seen = {}
		for _, c in cards do
			assert(not seen[c.id], "duplicate " .. c.id)
			seen[c.id] = true
			assert(c.id ~= "wpn_rocket" and c.id ~= "mod_ricochet", "gated item " .. c.id)
			assert(c.category ~= "Skill", "skills are gated to Lv 6: " .. c.id)
		end
	end)

	test("same seed gives the same offer", function()
		local a = OfferGenerator.generate(Upgrades, emptyBuild(), 12, rng(42))
		local b = OfferGenerator.generate(Upgrades, emptyBuild(), 12, rng(42))
		assert(ids(a) == ids(b), ids(a) .. " vs " .. ids(b))
	end)

	test("owned weapon is offered as a rank-up", function()
		local b = emptyBuild()
		b.stacks.wpn_gatling = 2
		b.mounts = { "wpn_gatling" }
		local found
		for _, c in OfferGenerator.eligible(Upgrades, b, 10) do
			if c.id == "wpn_gatling" then
				found = c
			end
		end
		assert(found and found.kind == "rank" and found.rank == 3, "gatling rank card")
	end)

	test("maxed weapon and full mounts are not offered", function()
		local b = emptyBuild()
		b.stacks.wpn_gatling = 5
		b.mounts = { "wpn_gatling", "x", "y" }
		for _, c in OfferGenerator.eligible(Upgrades, b, 30) do
			assert(c.id ~= "wpn_gatling", "maxed gatling offered")
			assert(c.id ~= "wpn_rocket", "rocket offered with full mounts")
		end
	end)

	test("a different skill is offered as a replacement", function()
		local b = emptyBuild()
		b.skill = "skl_dash"
		b.skillRank = 3
		local sawShield = false
		for _, c in OfferGenerator.eligible(Upgrades, b, 10) do
			assert(c.id ~= "skl_dash", "maxed dash offered")
			if c.id == "skl_shield" then
				sawShield = true
				assert(c.kind == "replace" and c.replaces == "skl_dash", "replace label")
			end
		end
		assert(sawShield, "shield missing")
	end)

	test("a nearly maxed build is topped up with fallbacks to exactly 3", function()
		local b = emptyBuild()
		for _, def in Upgrades.list do
			if def.category ~= "Fallback" and def.category ~= "Skill" then
				b.stacks[def.id] = def.max
			end
		end
		b.mounts = { "wpn_gatling", "wpn_rocket" }
		b.skill = "skl_dash"
		b.skillRank = 3
		-- At Lv 3 only Earth Wall can replace Dash (Flipper unlocks at Lv 4, the
		-- rest at Lv 6), so exactly 2 fallbacks fill the offer.
		local cards = OfferGenerator.generate(Upgrades, b, 3, rng(7))
		assert(#cards == 3, "count")
		local fallbacks = 0
		for _, c in cards do
			if c.kind == "fallback" then
				fallbacks += 1
			end
		end
		assert(fallbacks == 2, "fallbacks " .. fallbacks .. ": " .. ids(cards))
	end)

	test("property: 10,000 random states always give 3 valid cards", function()
		local r = rng(2026)
		for i = 1, 10000 do
			local level = 1 + math.floor(r() * 99)
			local b = randomBuild(r, level)
			local eligible = OfferGenerator.eligible(Upgrades, b, level)
			local eligibleById = {}
			local eligibleCats = {}
			for _, c in eligible do
				eligibleById[c.id] = c
				eligibleCats[c.category] = (eligibleCats[c.category] or 0) + 1
			end
			local cards = OfferGenerator.generate(Upgrades, b, level, r)
			assert(#cards == 3, `case {i}: {#cards} cards`)
			local seen, cats = {}, {}
			for _, c in cards do
				assert(not seen[c.id], `case {i}: duplicate {c.id}`)
				seen[c.id] = true
				if c.kind ~= "fallback" then
					assert(eligibleById[c.id], `case {i}: ineligible {c.id}`)
				end
				cats[c.category] = (cats[c.category] or 0) + 1
			end
			for cat, n in cats do
				if n > 2 then
					for other, m in eligibleCats do
						assert(other == cat or m == 0, `case {i}: 3x {cat} while {other} was eligible`)
					end
				end
			end
		end
	end)

	test("skills stay rare once a player has one", function()
		local r = rng(99)
		local withSkill = 0
		local b = emptyBuild()
		b.skill = "skl_dash"
		b.skillRank = 3 -- maxed, so only half-weight replacement cards remain
		for _ = 1, 2000 do
			for _, c in OfferGenerator.generate(Upgrades, b, 20, r) do
				if c.category == "Skill" then
					withSkill += 1
					break
				end
			end
		end
		-- Two replacements at half weight out of ~90: roughly 8% of offers.
		assert(withSkill < 300, "offers with a skill: " .. withSkill)
	end)

	test("Earth Wall reaches new players early (D42)", function()
		local r = rng(5)
		local withWall = 0
		for _ = 1, 2000 do
			for _, c in OfferGenerator.generate(Upgrades, emptyBuild(), 2, r) do
				if c.id == "skl_earthwall" then
					withWall += 1
					break
				end
			end
		end
		-- At Lv 2 it is the only skill and its need slot weight doubles: about 15-20%.
		assert(withWall > 200, "offers with Earth Wall at Lv 2: " .. withWall)
		for _, c in OfferGenerator.eligible(Upgrades, emptyBuild(), 1) do
			assert(c.id ~= "skl_earthwall", "Earth Wall is gated to Lv 2")
		end
	end)

	test("replace-skill cards carry half weight", function()
		local b = emptyBuild()
		b.skill = "skl_dash"
		b.skillRank = 1
		for _, c in OfferGenerator.eligible(Upgrades, b, 10) do
			if c.id == "skl_shield" then
				assert(c.kind == "replace" and c.weight == 1, "replace weight " .. c.weight)
			elseif c.id == "skl_dash" then
				assert(c.kind == "rank" and c.weight == 2, "rank-up keeps full weight")
			end
		end
	end)
end
