local XpCurve = require("../src/shared/XpCurve")
local Pacing = require("./Pacing")

return function(test)
	test("XP thresholds follow round(40 + 0.5 * L^1.8)", function()
		assert(XpCurve.toNext(0) == 40, "L0 " .. XpCurve.toNext(0))
		assert(XpCurve.toNext(10) == 72, "L10 " .. XpCurve.toNext(10))
		assert(XpCurve.totalTo(2) == 40 + 41, "total to 2 " .. XpCurve.totalTo(2))
		for l = 1, 99 do
			assert(XpCurve.toNext(l) >= XpCurve.toNext(l - 1), "curve must not drop at " .. l)
		end
	end)

	test("overflow carries into several levels", function()
		local level, xp, gained = XpCurve.add(0, 0, 40 + 41 + 5)
		assert(level == 2 and xp == 5 and gained == 2, `{level} {xp} {gained}`)
	end)

	test("level stops at 100 and drops leftover xp", function()
		local level, xp, gained = XpCurve.add(99, 0, 10_000_000)
		assert(level == 100 and xp == 0 and gained == 1)
		level, xp, gained = XpCurve.add(100, 0, 500)
		assert(level == 100 and xp == 0 and gained == 0)
	end)

	test("offers come on even levels only", function()
		assert(XpCurve.offersFor(0, 1) == 0, "0->1")
		assert(XpCurve.offersFor(1, 2) == 1, "1->2")
		assert(XpCurve.offersFor(0, 10) == 5, "0->10")
		assert(XpCurve.offersFor(3, 7) == 2, "3->7")
		assert(XpCurve.offersFor(99, 100) == 1, "99->100")
		assert(XpCurve.offersFor(0, 100) == 50, "a full life gives 50 picks")
		assert(XpCurve.nextOfferLevel(0) == 2 and XpCurve.nextOfferLevel(2) == 4 and XpCurve.nextOfferLevel(3) == 4)
		assert(XpCurve.nextOfferLevel(100) == nil)
	end)

	test("pacing model hits its targets within 20%", function()
		local times = Pacing.simulate(XpCurve.toNext, XpCurve.MaxLevel)
		for level, target in Pacing.targets do
			local got = times[level]
			assert(got and math.abs(got - target) / target <= 0.2, `Lv {level}: {got}s vs {target}s`)
		end
	end)
end
