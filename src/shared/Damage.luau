--!strict
-- How one hit lands on a robot with health and armor (D33). Pure and tested.
-- Armor absorbs first. While armor is up, a non-splash hit can deflect entirely.

local Damage = {}

-- roll is a random number in [0, 1); pass it in so tests are deterministic.
-- Returns: newHp, newArmor, deflected, armorTaken, hpTaken
function Damage.resolve(hp: number, armor: number, amount: number, deflectChance: number, roll: number, isSplash: boolean): (number, number, boolean, number, number)
	if not isSplash and armor > 0 and roll < deflectChance then
		return hp, armor, true, 0, 0
	end
	local absorbed = math.min(armor, amount)
	local rest = amount - absorbed
	return hp - rest, armor - absorbed, false, absorbed, rest
end

return Damage
