-- Map floors are painted with Terrain, which only takes terrain materials (D89: Forge
-- Highlands used Pebble, a Part material; SetMaterialColor threw and the biome came up
-- with no ground and no map). Arena.luau needs Roblox, so this reads its FLOORS table.
local fs = require("@lune/fs")

-- Enum.Material values Terrain accepts (Roblox Terrain materials).
local TERRAIN = {
	Asphalt = true, Basalt = true, Brick = true, Cobblestone = true, Concrete = true,
	CrackedLava = true, Glacier = true, Grass = true, Ground = true, Ice = true,
	LeafyGrass = true, Limestone = true, Mud = true, Pavement = true, Rock = true,
	Salt = true, Sand = true, Sandstone = true, Slate = true, Snow = true,
	WoodPlanks = true, Water = true,
}

return function(test)
	test("every map floor uses terrain materials only", function()
		local src = fs.readFile("src/server/Arena.luau")
		local block = string.match(src, "local FLOORS = (%b{})")
		assert(block, "FLOORS table not found in Arena.luau")
		local count = 0
		for material in string.gmatch(block, "Enum%.Material%.(%w+)") do
			count += 1
			assert(TERRAIN[material], material .. " is not a terrain material")
		end
		assert(count > 0, "no floor materials found")
	end)
end
