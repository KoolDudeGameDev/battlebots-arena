--!strict
-- XP needed to go from level L to L+1: round(40 + 0.5 * L^1.8), fitted by
-- tests/fit-curve.luau to the pacing targets (Lv 1 ~20 s, Lv 10 ~4 min,
-- Lv 50 ~20 min, Lv 100 ~40 min for a strong player). Provisional.

local XpCurve = {}

XpCurve.MaxLevel = 100
XpCurve.OfferEvery = 2 -- upgrade cards arrive on even levels only

function XpCurve.toNext(level: number): number
	return math.floor(40 + 0.5 * level ^ 1.8 + 0.5)
end

-- Total XP needed to reach `level` from 0.
function XpCurve.totalTo(level: number): number
	local total = 0
	for l = 0, level - 1 do
		total += XpCurve.toNext(l)
	end
	return total
end

-- Adds xp to a (level, xpIntoLevel) pair. Returns the new level, the leftover xp
-- inside that level, and how many levels were gained. XP past the cap is not
-- stored in the level (the caller keeps it as score).
function XpCurve.add(level: number, xp: number, amount: number): (number, number, number)
	local gained = 0
	xp += amount
	while level < XpCurve.MaxLevel and xp >= XpCurve.toNext(level) do
		xp -= XpCurve.toNext(level)
		level += 1
		gained += 1
	end
	if level >= XpCurve.MaxLevel then
		xp = 0
	end
	return level, xp, gained
end

-- How many upgrade offers a jump from `fromLevel` to `toLevel` earns:
-- one per offer level (multiple of OfferEvery) passed in (fromLevel, toLevel].
function XpCurve.offersFor(fromLevel: number, toLevel: number): number
	local every = XpCurve.OfferEvery
	return math.max(0, math.floor(toLevel / every) - math.floor(fromLevel / every))
end

-- The next level that brings an upgrade offer, or nil at the cap.
function XpCurve.nextOfferLevel(level: number): number?
	local nextLevel = (math.floor(level / XpCurve.OfferEvery) + 1) * XpCurve.OfferEvery
	if nextLevel > XpCurve.MaxLevel then
		return nil
	end
	return nextLevel
end

return XpCurve
