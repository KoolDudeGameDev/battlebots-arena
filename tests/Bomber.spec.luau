-- Bomber (D70): a huge, tough robot that only fires nets (they slow what they hit),
-- detonates with Space, drops to 25% HP and becomes a small fast robot until it
-- heals back up.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")
local Combat2D = require("../src/shared/Combat2D")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function stats(id: string, small: boolean?)
	return Stats.compute(Config, { stacks = {}, chassis = Chassis.byId[id], small = small }, 0)
end

local function offered(chassisId: string, skill: string?): { [string]: boolean }
	local c = Chassis.byId[chassisId]
	local b = { stacks = {}, mounts = {}, skill = skill, skillRank = 1, tags = c.tags }
	local out = {}
	for _, card in OfferGenerator.eligible(Upgrades, b, Config.MaxLevel) do
		out[card.id] = true
	end
	return out
end

return function(test)
	test("big form is the toughest robot and never shoots damage", function()
		local big = stats("bomber")
		for _, c in Chassis.list do
			if not c.comingSoon and c.id ~= "bomber" then
				local s = stats(c.id)
				assert(big.maxHp + big.maxArmor > s.maxHp + s.maxArmor, "bomber should out-tank " .. c.id)
			end
		end
		local p = Chassis.byId.bomber.primary :: Chassis.Primary
		assert(p.kind == "net" and Config.Weapons[p.weapon].netDuration > 0)
	end)

	test("small form: same max HP, much faster, smaller, no built-in armor", function()
		local big, small = stats("bomber"), stats("bomber", true)
		assert(small.maxHp == big.maxHp, "HP percentage carries over")
		assert(small.speed >= big.speed * 1.4, "small form is fast")
		assert(small.hitRadius < big.hitRadius and small.maxArmor == 0)
		assert(Stats.bodySize({ chassis = Chassis.byId.bomber, small = true }) < Stats.bodySize({ chassis = Chassis.byId.bomber }))
	end)

	test("the bomb is the Bomber's own skill: never replaced, only ranked up", function()
		local b = offered("bomber", "skl_bomb")
		assert(b.skl_bomb, "rank-up offered")
		assert(not b.skl_dash and not b.skl_shield and not b.skl_nullfield and not b.skl_earthwall, "no other skills")
		assert(not offered("rookie", nil).skl_bomb, "only the Bomber gets bombs")
		assert(Chassis.byId.bomber.skill == "skl_bomb")
	end)

	test("Bomber uses the special attachment pool", function()
		local b = offered("bomber", "skl_bomb")
		assert(b.wpn_traps and b.wpn_shieldgen and not b.wpn_gatling)
	end)

	test("detonating leaves 25% HP and healing past the rebuild line makes it big again", function()
		local B = Config.Bomber
		assert(B.hpAfter == 0.25 and B.rebuildAt > B.hpAfter and B.rebuildAt <= 1)
	end)

	test("the bomb blast is exactly the drawn ring: 300 at the centre, 150 at the edge (D80)", function()
		local S = Config.Skills.skl_bomb
		local ring = Stats.attackRange(Config, Chassis.byId.bomber.primary, stats("bomber"), { stacks = {} })
		assert(near(ring, Config.Weapons.netgun.range + 1.2 + Config.Robot.BarrelLength), "ring " .. ring)
		assert(S.damage == 300 and S.edge == 0.5, "damage and edge")
		assert(S.radius == nil and S.radiusPerRank == nil, "radius comes from the ring, not the skill")
		assert(near(S.damage * Combat2D.splashFactor(ring, ring, S.edge), 150))
	end)

	test("the small form heals itself back to big in about 12 s (D80)", function()
		local B = Config.Bomber
		local secs = (B.rebuildAt - B.hpAfter) / B.smallRegenPerSecond
		assert(secs >= 10 and secs <= 14, "rebuild takes " .. secs .. " s")
	end)
end
