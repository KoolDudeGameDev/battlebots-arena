--!strict
-- Upgrade definitions (GDD section 14). Pure data, so new content is a new row.

export type Category = "Stat" | "Weapon" | "Skill" | "Modifier" | "Fallback"
export type Rarity = "Common" | "Rare" | "Epic" | "Fallback"

export type Def = {
	id: string,
	name: string,
	category: Category,
	rarity: Rarity,
	weight: number,
	max: number, -- max stacks, or max rank for weapons and skills
	minLevel: number,
	tags: { string },
	text: string, -- what one pick does
	earlyBoost: number?, -- extra weight in the "need" slot while under Lv 10 with no skill (D42)
	requiresTag: string?, -- the robot must have this tag (Chassis.tags), e.g. "projectile_primary"
	requiresAnyTag: { string }?, -- the robot must have at least one of these (mount pools, D69)
	requires: { [string]: number }?, -- minimum stacks of other upgrades
	excludes: { string }?, -- not offered while you own any of these
	primary: { kind: string, weapon: string }?, -- a variant: replaces the robot's main weapon
	locked: boolean?, -- a skill that is never replaced by another (the Bomber's bomb)
	textByTag: { [string]: string }?, -- wording for robots with that tag (D71), else `text`
}

local list: { Def } = {
	{ id = "stat_damage", name = "Damage", category = "Stat", rarity = "Common", weight = 10, max = 8, minLevel = 1, tags = { "offense" }, text = "+10% damage (all weapons)", textByTag = { bomber = "+10% damage (bomb and attachments)" } },
	-- Only robots that shoot get Fire Rate; melee and flame attack at a fixed pace (D71).
	{ id = "stat_firerate", name = "Fire Rate", category = "Stat", rarity = "Common", weight = 10, max = 8, minLevel = 1, tags = { "offense" }, text = "+10% fire rate (all weapons)", requiresAnyTag = { "projectile_primary", "net_primary" }, textByTag = { net_primary = "+10% net fire rate (and attachments)" } },
	{ id = "stat_hp", name = "Max HP", category = "Stat", rarity = "Common", weight = 10, max = 8, minLevel = 1, tags = { "sustain" }, text = "+15 max HP" },
	{ id = "stat_speed", name = "Move Speed", category = "Stat", rarity = "Common", weight = 10, max = 6, minLevel = 1, tags = { "mobility" }, text = "+5% move speed" },
	{ id = "stat_range", name = "Range", category = "Stat", rarity = "Common", weight = 10, max = 6, minLevel = 1, tags = { "offense" }, text = "+8% range, +4% shot speed", textByTag = { melee_primary = "+8% weapon reach: a bigger weapon", cone_primary = "+8% flame length", net_primary = "+8% net range" } },
	{ id = "stat_cone", name = "Wider Flames", category = "Stat", rarity = "Common", weight = 10, max = 5, minLevel = 1, tags = { "offense", "primary" }, text = "+8 degrees of flame width", requiresTag = "cone_primary" },
	{ id = "stat_pickup", name = "Pickup Radius", category = "Stat", rarity = "Common", weight = 10, max = 4, minLevel = 1, tags = { "economy" }, text = "+25% pickup radius" },
	-- Not everyone gets armor (D33): it is a Rare card.
	{ id = "stat_armor", name = "Armor Plating", category = "Stat", rarity = "Rare", weight = 4, max = 5, minLevel = 1, tags = { "sustain" }, text = "Regenerating armor; bullets can deflect off it" },
	-- Up to 5 barrels: one more bullet per shot each, at a little less damage per bullet.
	{ id = "stat_barrels", name = "Extra Barrel", category = "Stat", rarity = "Rare", weight = 5, max = 4, minLevel = 2, tags = { "offense", "primary" }, text = "+1 barrel: one more bullet per shot", requiresTag = "projectile_primary" },

	-- Mounts come in class pools (D69): gun robots get guns, melee robots pure melee
	-- gear, special robots (Scorcher) close-range gear.
	{ id = "wpn_gatling", name = "Side Gatling", category = "Weapon", rarity = "Rare", weight = 6, max = 5, minLevel = 1, tags = { "offense", "mount" }, text = "Mounted gun that aims itself at the nearest target", requiresAnyTag = { "gun_mounts" } },
	{ id = "wpn_rocket", name = "Rocket Pod", category = "Weapon", rarity = "Rare", weight = 6, max = 5, minLevel = 5, tags = { "offense", "mount" }, text = "Accelerating rockets with splash and knockback", requiresAnyTag = { "gun_mounts" } },
	{ id = "wpn_railgun", name = "Railgun", category = "Weapon", rarity = "Rare", weight = 5, max = 5, minLevel = 8, tags = { "offense", "mount" }, text = "Long-range shot that pierces every robot in line", requiresAnyTag = { "gun_mounts" } },
	{ id = "wpn_shock", name = "Shock Coil", category = "Weapon", rarity = "Rare", weight = 5, max = 5, minLevel = 6, tags = { "offense", "mount" }, text = "Lightning that chains between nearby targets", requiresAnyTag = { "gun_mounts", "special_mounts" } },
	{ id = "wpn_spikeram", name = "Minotaur Horns", category = "Weapon", rarity = "Rare", weight = 6, max = 5, minLevel = 1, tags = { "offense", "mount", "melee" }, text = "Big horns gore robots you drive into and toss them back", requiresAnyTag = { "melee_mounts", "special_mounts" } },
	{ id = "wpn_sidesaw", name = "Vertical Saw", category = "Weapon", rarity = "Rare", weight = 5, max = 5, minLevel = 4, tags = { "offense", "mount", "melee" }, text = "A spinning blade on your back that grinds any robot touching you", requiresAnyTag = { "melee_mounts" } },
	{ id = "wpn_traps", name = "Spike Traps", category = "Weapon", rarity = "Rare", weight = 5, max = 5, minLevel = 4, tags = { "offense", "mount" }, text = "Drops spike traps behind you as you drive: they hurt and pin robots for 1 s", requiresAnyTag = { "melee_mounts", "special_mounts" } },
	{ id = "wpn_shieldgen", name = "Shield Generator", category = "Weapon", rarity = "Rare", weight = 5, max = 5, minLevel = 6, tags = { "sustain", "mount" }, text = "A recharging energy shield blocks hits from the front", requiresAnyTag = { "melee_mounts", "special_mounts" } },

	-- Skills are deliberately rarer (D32): low weight, from Lv 6, no "need" boost.
	{ id = "skl_dash", name = "Dash", category = "Skill", rarity = "Rare", weight = 2, max = 3, minLevel = 6, tags = { "mobility" }, text = "Dash 20 studs. 6 s cooldown" },
	{ id = "skl_shield", name = "Shield Pulse", category = "Skill", rarity = "Rare", weight = 2, max = 3, minLevel = 6, tags = { "sustain" }, text = "Block all shots for 1.5 s. 12 s cooldown" },
	{ id = "skl_nullfield", name = "Null Field", category = "Skill", rarity = "Rare", weight = 2, max = 3, minLevel = 6, tags = { "sustain" }, text = "A big field around you for 3 s: enemy shots and robots inside slow down. 15 s cooldown" },
	{ id = "skl_flipper", name = "Flipper", category = "Skill", rarity = "Rare", weight = 3, max = 3, minLevel = 4, tags = { "sustain" }, text = "Flip robots in front of you into the air: they can't drive or attack for 1.2 s. 10 s cooldown" },
	-- The Bomber's own skill (D70): it starts with rank 1; cards only rank it up.
	{ id = "skl_bomb", name = "Detonate", category = "Skill", rarity = "Rare", weight = 3, max = 3, minLevel = 2, tags = { "offense" }, text = "Blow up: big blast, then small and fast at 25% HP. Ranks: +25% damage", requiresTag = "bomber", locked = true },
	-- The anti-bullying tool (D42): available from the first pick, boosted for new players.
	{ id = "skl_earthwall", name = "Earth Wall", category = "Skill", rarity = "Rare", weight = 3, max = 3, minLevel = 2, tags = { "sustain" }, text = "Raise a wall that blocks bullets and robots. 14 s cooldown", earlyBoost = 2 },

	{ id = "mod_ricochet", name = "Ricochet", category = "Modifier", rarity = "Epic", weight = 3, max = 1, minLevel = 10, tags = { "offense", "primary" }, text = "Main-gun hits bounce once at 50% damage", requiresTag = "blaster_primary", excludes = { "var_laser" } }, -- not Bombard: rockets splash and never bounce
	{ id = "mod_spread", name = "Spreader Choke", category = "Modifier", rarity = "Epic", weight = 3, max = 1, minLevel = 6, tags = { "offense", "primary" }, text = "Barrels fan out like a shotgun: +25% damage, -30% range", requiresTag = "projectile_primary", requires = { stat_barrels = 1 } },
	-- Rare main-weapon variants (D67): Epic, from Lv 10, one per life, lost on death.
	{ id = "var_laser", name = "Laser Gun", category = "Modifier", rarity = "Epic", weight = 2, max = 1, minLevel = 10, tags = { "offense", "primary" }, text = "Your blaster becomes a laser beam that never stops firing", requiresTag = "blaster_primary", excludes = { "mod_ricochet" }, primary = { kind = "beam", weapon = "laser" } },
	{ id = "var_axe", name = "Battle Axe", category = "Modifier", rarity = "Epic", weight = 2, max = 1, minLevel = 10, tags = { "offense", "primary" }, text = "Your saw becomes an axe that sweeps all the way round you", requiresTag = "melee_primary", excludes = { "var_hammer" }, primary = { kind = "melee", weapon = "axe" } },
	{ id = "var_hammer", name = "Sledgehammer", category = "Modifier", rarity = "Epic", weight = 2, max = 1, minLevel = 10, tags = { "offense", "primary" }, text = "Your saw becomes a hammer: overhead smashes that hit an area in front and send robots flying", requiresTag = "melee_primary", excludes = { "var_axe" }, primary = { kind = "melee", weapon = "hammer" } },
	{ id = "mod_scavenger", name = "Scavenger", category = "Modifier", rarity = "Rare", weight = 4, max = 1, minLevel = 1, tags = { "sustain", "economy" }, text = "Orbs repair your robot" },

	-- Bomber-only cards (D84, 11-bomber-redesign.md): shell, blast and core.
	{ id = "bmb_mesh", name = "Wide Mesh", category = "Stat", rarity = "Common", weight = 8, max = 3, minLevel = 1, tags = { "control" }, text = "Nets open 25% wider", requiresTag = "bomber" },
	{ id = "bmb_valve", name = "Pressure Valve", category = "Modifier", rarity = "Rare", weight = 5, max = 2, minLevel = 2, tags = { "offense" }, text = "Pressure drains 50% slower; +5 Pressure per robot netted", requiresTag = "bomber" },
	{ id = "bmb_shaped", name = "Shaped Charge", category = "Modifier", rarity = "Rare", weight = 5, max = 3, minLevel = 4, tags = { "offense" }, text = "+12% blast radius", requiresTag = "bomber" },
	{ id = "bmb_hotfuse", name = "Hot Fuse", category = "Modifier", rarity = "Epic", weight = 2, max = 1, minLevel = 10, tags = { "offense" }, text = "Detonate's fuse: 0.8 s -> 0.55 s", requiresTag = "bomber" },
	{ id = "bmb_shrapnel", name = "Shrapnel", category = "Modifier", rarity = "Rare", weight = 4, max = 2, minLevel = 4, tags = { "offense" }, text = "+1 Scrap Cannon pellet (small form)", requiresTag = "bomber" },
	{ id = "bmb_marked", name = "Marked for Demolition", category = "Modifier", rarity = "Rare", weight = 4, max = 2, minLevel = 6, tags = { "offense" }, text = "Marks last 3 s longer; Scrap Cannon +25% on marked robots", requiresTag = "bomber" },

	-- Used only when the normal pool cannot fill three cards. Never capped.
	-- Health only comes from the map (D33), so this drops a health pack rather than healing.
	{ id = "fb_supply", name = "Supply Drop", category = "Fallback", rarity = "Fallback", weight = 1, max = math.huge, minLevel = 1, tags = {}, text = "Drops a health pack beside you" },
	{ id = "fb_reinforce", name = "Reinforce", category = "Fallback", rarity = "Fallback", weight = 1, max = math.huge, minLevel = 1, tags = {}, text = "+5 max HP, +2% damage" },
	{ id = "fb_cache", name = "Scrap Cache", category = "Fallback", rarity = "Fallback", weight = 1, max = math.huge, minLevel = 1, tags = {}, text = "+30% of this level's XP" },
}

local byId: { [string]: Def } = {}
local variants: { Def } = {}
for _, def in list do
	byId[def.id] = def
	if def.primary then
		table.insert(variants, def)
	end
end

-- The main-weapon variant a build owns, if any (D67); nil means the robot's own weapon.
-- Runs every frame per firing robot, so it only scans the variant rows.
local function primaryFor(stacks: { [string]: number }): { kind: string, weapon: string }?
	for _, def in variants do
		if (stacks[def.id] or 0) > 0 then
			return def.primary
		end
	end
	return nil
end

return {
	list = list,
	byId = byId,
	primaryFor = primaryFor,
}
