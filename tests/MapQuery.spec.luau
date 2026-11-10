-- Geometry queries against a map layout (D81), and sanity checks on the generated data.
local MapQuery = require("../src/shared/MapQuery")
local MapLayouts = require("../src/shared/MapLayouts")

local function near(a: number, b: number, eps: number): boolean
	return math.abs(a - b) <= eps
end

local c45, s45 = math.cos(math.rad(45)), math.sin(math.rad(45))
local function diamond()
	return { boxes = { { id = 1, cx = 0, cz = 0, ux = c45, uz = s45, hu = 5, hv = 1, h = 6 } }, circles = {}, lava = {} }
end

return function(test)
	test("a turned box blocks a shot where it crosses it", function()
		local t = MapQuery.blockedAt(diamond(), -10, 0, 10, 0, 0)
		assert(t and near(t, 0.45, 0.06), "t " .. tostring(t))
		assert(MapQuery.blockedAt(diamond(), -10, 8, 10, 8, 0) == nil, "passes above it")
	end)

	test("circles block, and a shot's radius grows them", function()
		local map = { boxes = {}, circles = { { id = 1, x = 0, z = 5, r = 2, h = 6, kind = "wood" } }, lava = {} }
		assert(MapQuery.blockedAt(map, -10, 0, 10, 0, 0) == nil)
		local t, kind = MapQuery.blockedAt(map, -10, 0, 10, 0, 3.5)
		assert(t ~= nil and kind == "wood", "reports what it hit: " .. tostring(kind))
	end)

	test("broken pieces no longer block", function()
		assert(MapQuery.blockedAt(diamond(), -10, 0, 10, 0, 0, { [1] = true }) == nil)
		local map = { boxes = {}, circles = { { id = 2, x = 0, z = 0, r = 2, h = 6 } }, lava = {} }
		assert(MapQuery.blockedAt(map, -10, 0, 10, 0, 0, { [MapQuery.CIRCLE_KEY + 2] = true }) == nil)
	end)

	test("inCover and inLava use the turned shapes", function()
		assert(MapQuery.inCover(diamond(), 2, 2, 0))
		assert(not MapQuery.inCover(diamond(), 4, -4, 0))
		local map = { boxes = {}, circles = {}, lava = { { id = 1, cx = 100, cz = 0, ux = 1, uz = 0, hu = 7, hv = 10 } } }
		assert(MapQuery.inLava(map, 100, 0))
		assert(not MapQuery.inLava(map, 108, 0))
	end)

	test("spawns: the one far from enemies wins", function()
		local map = { spawns = { { x = 100, z = 0 }, { x = -100, z = 0 } } }
		local x, z = MapQuery.pickSpawn(map, { { 90, 0 } }, 40, 1)
		assert(x == -100 and z == 0, `got {x}, {z}`)
		x = MapQuery.pickSpawn(map, { { 95, 0 }, { -95, 0 } }, 40, 1) -- nobody far enough: the farthest
		assert(x == 100 or x == -100)
	end)

	test("generated maps: spawns, gates and hazards are all there and clear", function()
		local overworld = { "grassland", "forge_highlands", "inferno_fields", "grinder_scrapyard" }
		local arenas = { "arena_forge", "arena_inferno", "arena_grinder" }
		for _, name in overworld do
			local m = MapLayouts[name]
			assert(m and m.kind == "overworld" and m.half == 190 and #m.spawns >= 24, name)
		end
		for _, name in arenas do
			local m = MapLayouts[name]
			assert(m and m.kind == "arena" and m.half == 120 and #m.spawns >= 20 and m.gate, name)
		end
		assert(#MapLayouts.inferno_fields.lava > 0, "lava")
		assert(#MapLayouts.grinder_scrapyard.saws == 8, "8 saw runs")
		assert(#MapLayouts.forge_highlands.hammers == 8, "8 drop-hammers")
		assert(#MapLayouts.inferno_fields.vents == 8, "8 geysers")
		for name, m in MapLayouts do
			for _, s in m.spawns do
				assert(not MapQuery.inCover(m, s.x, s.z, 5), `{name} spawn {s.x}, {s.z} in cover`)
				assert(not MapQuery.inLava(m, s.x, s.z), `{name} spawn in lava`)
			end
		end
	end)
end
