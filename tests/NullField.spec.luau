-- Null Field skill (D68): enemy shots and enemy robots inside the field slow down.
local Config = require("../src/shared/Config")
local Combat2D = require("../src/shared/Combat2D")
local Upgrades = require("../src/shared/Upgrades")

return function(test)
	local fields = { { x = 0, z = 0, r = 18, owner = 1 } }

	test("enemy things inside a Null Field are slowed; the owner's are not", function()
		assert(Combat2D.fieldFactor(5, 5, 2, fields, 0.25) == 0.25, "enemy shot inside")
		assert(Combat2D.fieldFactor(5, 5, 1, fields, 0.25) == 1, "own shot inside")
		assert(Combat2D.fieldFactor(30, 0, 2, fields, 0.25) == 1, "enemy shot outside")
		assert(Combat2D.fieldFactor(18, 0, 2, fields, 0.25) == 0.25, "on the edge counts")
		assert(Combat2D.fieldFactor(5, 5, 2, {}, 0.25) == 1, "no fields")
	end)

	test("a slowed shot can be dodged: it crawls slower than a robot drives", function()
		local S = Config.Skills.skl_nullfield
		assert(Config.Weapons.blaster.speed * S.projectileSlow < Config.Robot.MoveSpeed * 1.5)
		assert(S.robotSlow > 0 and S.robotSlow < 1)
	end)

	test("Null Field is a rare skill with its numbers in Config", function()
		local def = Upgrades.byId.skl_nullfield
		assert(def and def.category == "Skill" and def.rarity == "Rare")
		local S = Config.Skills.skl_nullfield
		assert(S.radius > 9 * 1.5, "much bigger than the Shield Pulse bubble")
		assert(S.duration > 0 and S.cooldown > S.duration)
	end)
end
