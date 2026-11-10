-- Prints every ranged-vs-close duel, for tuning Chassis and Config.
-- Run: lune run tests/duel-table
local Chassis = require("../src/shared/Chassis")
local Duel = require("./Duel")

for _, level in { 0, 50, 100 } do
	print(`Lv {level}`)
	for _, r in Chassis.list do
		if not r.comingSoon and Duel.isRanged(r.id) then
			for _, c in Chassis.list do
				if not c.comingSoon and Duel.isClose(c.id) then
					local w1, h1, t1 = Duel.run(r.id, c.id, level, false)
					local w2, h2, t2 = Duel.run(r.id, c.id, level, true)
					print(string.format("  %-8s vs %-8s  stands: %-6s wins %3d%% left %4.1fs   kites: %-6s wins %3d%% left %4.1fs", r.id, c.id, w1, h1 * 100, t1, w2, h2 * 100, t2))
				end
			end
		end
	end
end
