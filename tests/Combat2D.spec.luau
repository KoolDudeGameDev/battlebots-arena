local Combat2D = require("../src/shared/Combat2D")
local Config = require("../src/shared/Config")

local function near(a, b)
	return a ~= nil and math.abs(a - b) < 1e-6
end

return function(test)
	test("segment hits a circle at the right t", function()
		local t = Combat2D.segmentCircle(0, 0, 10, 0, 5, 0, 1)
		assert(near(t, 0.4), tostring(t))
		assert(Combat2D.segmentCircle(0, 0, 10, 0, 5, 3, 1) == nil, "miss")
		assert(Combat2D.segmentCircle(0, 0, 2, 0, 5, 0, 1) == nil, "short")
		assert(Combat2D.segmentCircle(5, 0, 10, 0, 5, 0, 1) == 0, "start inside")
	end)

	test("segment hits a box at the right t", function()
		local t = Combat2D.segmentBox(0, 0, 10, 0, 4, -1, 6, 1)
		assert(near(t, 0.4), tostring(t))
		assert(Combat2D.segmentBox(0, 5, 10, 5, 4, -1, 6, 1) == nil, "miss")
		assert(Combat2D.segmentBox(5, 0, 6, 0, 4, -1, 6, 1) == 0, "inside")
		assert(near(Combat2D.segmentBox(5, -10, 5, 10, 4, -1, 6, 1), 0.45), "vertical")
	end)

	test("segment hits a rotated wall", function()
		-- Wall at (10, 0) facing +x: thickness along x (half 1), width along z (half 6).
		local t = Combat2D.segmentOBB(0, 0, 20, 0, 10, 0, 1, 0, 1, 6)
		assert(near(t, 0.45), tostring(t))
		-- Same wall turned 90 degrees: thin along z, wide along x. A shot along x at z=0 enters at x=4.
		local t2 = Combat2D.segmentOBB(0, 0, 20, 0, 10, 0, 0, 1, 1, 6)
		assert(near(t2, 0.2), tostring(t2))
		-- Passing beside the wall misses.
		assert(Combat2D.segmentOBB(0, 8, 20, 8, 10, 0, 1, 0, 1, 6) == nil, "miss")
	end)

	test("kill reward scales with the level gap", function()
		-- equal levels: 25% of 1000
		assert(Combat2D.killReward(1000, 20, 20, 0.25, 20) == 250)
		-- killing a much lower player: clamped to 0.25x, then the minimum
		assert(Combat2D.killReward(100, 0, 40, 0.25, 20) == 20)
		-- killing a much higher player: capped at 1.5x
		assert(Combat2D.killReward(10000, 50, 5, 0.25, 20) == 3750)
	end)

	test("death spill splits 40% into 5-25 orbs", function()
		local count, value = Combat2D.deathSpill(1000, 30, 0.4)
		assert(count == 15 and value == 26, `{count} {value}`)
		count, value = Combat2D.deathSpill(0, 0, 0.4)
		assert(count == 0 and value == 0)
		count, value = Combat2D.deathSpill(3, 0, 0.4)
		assert(count == 1 and value == 1, `{count} {value}`)
	end)
end
