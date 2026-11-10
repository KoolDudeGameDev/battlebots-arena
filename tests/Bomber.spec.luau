-- Bomber (D70): a huge, tough robot that only fires nets (they slow what they hit),
-- detonates with Space, drops to 25% HP and becomes a small fast robot until it
-- heals back up.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

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
end
