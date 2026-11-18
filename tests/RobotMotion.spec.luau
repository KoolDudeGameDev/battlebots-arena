-- The timing curves behind robot animation (D94), pinned from Robots.luau before
-- the move: saw spin-up, Scorcher heat, hammer smash, Flipper kick, Null Field
-- opening, lamp blinks.
local RobotMotion = require("../src/shared/RobotMotion")
local Config = require("../src/shared/Config")

local M = Config.Presentation.motion

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return function(test)
	test("robot motion: the saw spins up while attacking and winds down after, never snapping", function()
		local r = RobotMotion.sawRate(M, 3, true, 1 / 60)
		assert(r > 3 and r < 32, tostring(r))
		assert(near(r, 3 + (32 - 3) * (4 / 60)))
		local settled = 3
		for _ = 1, 600 do
			settled = RobotMotion.sawRate(M, settled, true, 1 / 60)
		end
		assert(math.abs(settled - 32) < 0.01, "settles at the attack speed")
		assert(RobotMotion.sawRate(M, 32, false, 1 / 60) < 32, "winds down when idle")
		assert(near(RobotMotion.sawRate(M, 10, true, 1), 32), "a long frame lands exactly on the target")
	end)

	test("robot motion: the saw's sound follows its speed", function()
		local vol, pitch = RobotMotion.sawSound(M, 32)
		assert(near(vol, 0.4) and near(pitch, 1.1))
		local vol0, pitch0 = RobotMotion.sawSound(M, 0)
		assert(near(vol0, 0.08) and near(pitch0, 0.7))
	end)

	test("robot motion: Scorcher heat rises while firing, cools after, and stays 0-1", function()
		assert(near(RobotMotion.heat(M, 0, true, 0.5), 0.6))
		assert(near(RobotMotion.heat(M, 1, false, 0.5), 0.75))
		assert(RobotMotion.heat(M, 0.9, true, 1) == 1 and RobotMotion.heat(M, 0.1, false, 1) == 0)
	end)

	test("robot motion: the hammer lifts, slams by 0.2 s, holds, then rises back to rest", function()
		local rest, lift = math.rad(100), math.rad(130)
		assert(near(RobotMotion.smashAngle(M, 0), rest))
		assert(near(RobotMotion.smashAngle(M, 0.1), lift))
		assert(near(RobotMotion.smashAngle(M, 0.2), 0))
		assert(RobotMotion.smashAngle(M, 0.3) == 0, "held on the ground")
		assert(near(RobotMotion.smashAngle(M, 0.6), rest * 0.5))
		assert(RobotMotion.smashAngle(M, 0.9) == rest and RobotMotion.smashAngle(M, math.huge) == rest)
		assert(near(RobotMotion.smashRest(M), rest))
	end)

	test("robot motion: the Flipper plate kicks up in 0.1 s and settles by 0.5 s", function()
		assert(RobotMotion.flipAngle(M, 0) == 0)
		assert(near(RobotMotion.flipAngle(M, 0.1), math.rad(70)))
		assert(near(RobotMotion.flipAngle(M, 0.3), math.rad(70) * 0.5))
		assert(RobotMotion.flipAngle(M, 0.5) == 0 and RobotMotion.flipAngle(M, math.huge) == 0)
	end)

	test("robot motion: the Null Field dome swells open over 0.3 s", function()
		assert(RobotMotion.fieldOpen(M, 0) == 0 and RobotMotion.fieldOpen(M, 0.3) == 1 and RobotMotion.fieldOpen(M, 5) == 1)
		assert(near(RobotMotion.fieldOpen(M, 0.15), 1 - 0.5 ^ 3))
	end)

	test("robot motion: lamps blink on for the first half of each cycle", function()
		assert(RobotMotion.blinkOn(0.2, 1) and not RobotMotion.blinkOn(0.7, 1))
		assert(RobotMotion.blinkOn(1.3, 2) == false and RobotMotion.blinkOn(1.0, 2))
	end)
end
