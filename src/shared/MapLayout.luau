--!strict
-- The battlefield layout (default environment, before any boss hazards).
-- One quadrant is designed by hand and rotated four times, so every spawn
-- side gets the same walls, trees and rocks (fair for free-for-all).
-- Pure: the server builds Parts from it, and both server and clients use the
-- same boxes and circles to stop bullets.
--
--   centre  (0-80)    big dirt plaza with 4 ruined pillars: the main fight zone
--   middle  (80-135)  L-shaped walls at the diagonals, a wall on each axis, rocks
--   outer   (135-187) tree groves and boulders around the edge: cover for new spawns

export type Box = { minX: number, minZ: number, maxX: number, maxZ: number, height: number, kind: string }
export type Circle = { x: number, z: number, r: number, kind: string }

local MapLayout = {}

-- One quadrant (x >= 0, z >= 0). Boxes are centre x, z and size along x, z.
local QUADRANT_BOXES = {
	{ x = 38, z = 38, sx = 6, sz = 6, h = 8, kind = "pillar" },
	{ x = 106, z = 92, sx = 26, sz = 4, h = 6, kind = "wall" }, -- L-wall arm along x
	{ x = 92, z = 106, sx = 4, sz = 26, h = 6, kind = "wall" }, -- L-wall arm along z
	{ x = 118, z = 0, sx = 4, sz = 30, h = 6, kind = "wall" }, -- axis wall (one per side)
	{ x = 0, z = 156, sx = 22, sz = 4, h = 5, kind = "wall" }, -- low outer wall in front of the spawn edge
}
local QUADRANT_CIRCLES = {
	-- Tree groves (trunks block bullets and robots; canopies are cosmetic)
	{ x = 150, z = 40, r = 1.6, kind = "tree" },
	{ x = 158, z = 52, r = 1.6, kind = "tree" },
	{ x = 145, z = 58, r = 1.6, kind = "tree" },
	{ x = 120, z = 150, r = 1.6, kind = "tree" },
	{ x = 132, z = 160, r = 1.6, kind = "tree" },
	{ x = 168, z = 120, r = 1.6, kind = "tree" },
	{ x = 60, z = 168, r = 1.6, kind = "tree" },
	-- Boulders
	{ x = 132, z = 116, r = 4, kind = "rock" },
	{ x = 70, z = 125, r = 3, kind = "rock" },
	{ x = 58, z = 14, r = 2.5, kind = "rock" }, -- a little cover inside the plaza
}

-- Rotates (x, z) by k * 90 degrees around the centre.
local function rotate(x: number, z: number, k: number): (number, number)
	for _ = 1, k do
		x, z = -z, x
	end
	return x, z
end

function MapLayout.boxes(): { Box }
	local out: { Box } = {}
	for k = 0, 3 do
		for _, b in QUADRANT_BOXES do
			local cx, cz = rotate(b.x, b.z, k)
			local sx, sz = b.sx, b.sz
			if k % 2 == 1 then
				sx, sz = sz, sx
			end
			table.insert(out, { minX = cx - sx / 2, minZ = cz - sz / 2, maxX = cx + sx / 2, maxZ = cz + sz / 2, height = b.h, kind = b.kind })
		end
	end
	return out
end

function MapLayout.circles(): { Circle }
	local out: { Circle } = {}
	for k = 0, 3 do
		for _, c in QUADRANT_CIRCLES do
			local x, z = rotate(c.x, c.z, k)
			table.insert(out, { x = x, z = z, r = c.r, kind = c.kind })
		end
	end
	return out
end

return MapLayout
