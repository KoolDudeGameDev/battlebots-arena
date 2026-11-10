-- Minimal test runner for the pure shared modules. Run: lune run tests/run
local process = require("@lune/process")

local failures = 0
local passes = 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passes += 1
	else
		failures += 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local suites = {
	require("./XpCurve.spec"),
	require("./OfferGenerator.spec"),
	require("./Combat2D.spec"),
	require("./Stats.spec"),
	require("./Damage.spec"),
	require("./Phase3b.spec"),
	require("./Balance.spec"),
	require("./Duel.spec"),
	require("./Variants.spec"),
	require("./NullField.spec"),
	require("./Mounts.spec"),
	require("./Bomber.spec"),
	require("./ClassCards.spec"),
	require("./Shop.spec"),
	require("./Bosses.spec"),
}

for _, suite in suites do
	suite(test)
end

print(string.format("%d passed, %d failed", passes, failures))
process.exit(if failures == 0 then 0 else 1)
