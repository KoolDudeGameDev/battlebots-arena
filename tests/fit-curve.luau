-- One-off tuning script: grid-searches the XP curve round(a + b * L^p) so the
-- pacing model hits its targets. Run: lune run tests/fit-curve
-- Copy the winning a, b, p into src/shared/XpCurve.luau.

local Pacing = require("./Pacing")

local best, bestErr = nil, math.huge
for a = 20, 80, 5 do
	for b = 0.25, 6, 0.25 do
		for p = 1.2, 2.0, 0.05 do
			local function toNext(l: number): number
				return math.floor(a + b * l ^ p + 0.5)
			end
			local times = Pacing.simulate(toNext, 100)
			local err = 0
			for level, target in Pacing.targets do
				local got = times[level] or 4 * 3600
				err += math.log(got / target) ^ 2
			end
			if err < bestErr then
				best, bestErr = { a = a, b = b, p = p, times = times }, err
			end
		end
	end
end

print(string.format("a=%g b=%g p=%.2f err=%.4f", best.a, best.b, best.p, bestErr))
for level, target in Pacing.targets do
	print(string.format("  Lv %3d: %5ds (target %ds)", level, best.times[level] or -1, target))
end
