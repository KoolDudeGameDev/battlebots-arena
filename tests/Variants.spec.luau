-- Rare main-weapon variants (D67): Laser Gun for Rookie, Battle Axe or Sledgehammer for Brawler.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")

local function build(chassisId: string, stacks)
	return { stacks = stacks or {}, mounts = {}, skill = nil, skillRank = 0, tags = Chassis.byId[chassisId].tags }
end

local function offered(b, id: string): boolean
	for _, c in OfferGenerator.eligible(Upgrades, b, Config.MaxLevel) do
		if c.id == id then
			return true
		end
	end
	return false
end

return function(test)
	test("every variant is a rare Epic card that swaps in a real weapon", function()
		local count = 0
		for _, def in Upgrades.list do
			local p = (def :: any).primary
			if p then
				count += 1
				assert(def.rarity == "Epic" and def.max == 1 and def.minLevel >= 10, def.id .. " should be Epic, max 1, Lv 10+")
				assert(Config.Weapons[p.weapon], def.id .. " weapon missing from Config.Weapons")
			end
		end
		assert(count == 3, "laser, axe and hammer")
	end)

	test("each robot only sees its own variants", function()
		assert(offered(build("rookie"), "var_laser"))
		assert(not offered(build("bombard"), "var_laser"), "laser replaces the blaster, not rockets")
		assert(offered(build("brawler"), "var_axe") and offered(build("brawler"), "var_hammer"))
		assert(not offered(build("rookie"), "var_axe"))
	end)

	test("one variant per life: axe and hammer exclude each other", function()
		assert(not offered(build("brawler", { var_axe = 1 }), "var_hammer"))
		assert(not offered(build("brawler", { var_hammer = 1 }), "var_axe"))
	end)

	test("Ricochet and the laser exclude each other (beams don't bounce)", function()
		assert(not offered(build("rookie", { var_laser = 1 }), "mod_ricochet"))
		assert(not offered(build("rookie", { mod_ricochet = 1 }), "var_laser"))
	end)
end
