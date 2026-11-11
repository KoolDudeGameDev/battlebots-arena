--!strict
-- The robots (D27, D44). Classes run E (base) to A; each step is about +12%
-- stat budget. Every robot has its own primary weapon and attack speed.
-- Reach costs toughness: ranged robots are fragile and slowed by recoil while
-- firing; close-range robots are heavy, armored and fast. tests/Duel.spec holds
-- every matchup to a fair duel (print it: lune run tests/duel-table).
-- Pure data: new robots are new rows.

export type Primary = {
	kind: "projectile" | "rocket" | "melee" | "cone" | "beam" | "net",
	weapon: string, -- key in Config.Weapons
}

export type Chassis = {
	id: string,
	class: string,
	name: string,
	price: number,
	hp: number,
	speed: number,
	armor: number?, -- built-in armor: absorbs first, regenerates, grows with level, never deflects
	mass: number?, -- knockback resistance (default 1)
	size: number?, -- hitbox radius multiplier (default 1): heavier robots are bigger targets
	firingSpeed: number?, -- walk speed multiplier while firing (recoil, default 1)
	small: { speed: number, size: number, mass: number, armor: number }?, -- Bomber's form after detonating (D70)
	skill: string?, -- a built-in skill the robot starts with and can't swap (Bomber's bomb)
	primary: Primary?,
	tags: { string }, -- gate upgrades, e.g. Ricochet needs "projectile_primary"
	blurb: string,
	comingSoon: boolean?,
}

local list: { Chassis } = {
	{
		id = "rookie",
		class = "E",
		name = "Rookie",
		price = 0,
		hp = 90,
		speed = 22,
		firingSpeed = 0.7,
		primary = { kind = "projectile", weapon = "blaster" },
		tags = { "projectile_primary", "blaster_primary", "gun_mounts" },
		blurb = "Balanced blaster. 4 shots per second.",
	},
	{
		id = "brawler",
		class = "D",
		name = "Brawler",
		price = 300,
		hp = 170,
		speed = 26.5,
		armor = 50,
		mass = 1.6,
		size = 1.15,
		primary = { kind = "melee", weapon = "buzzsaw" },
		tags = { "melee_primary", "melee_mounts" },
		blurb = "Fast melee buzzsaw that knocks robots back. 2.5 swings per second.",
	},
	{
		id = "scorcher",
		class = "D",
		name = "Scorcher",
		price = 300,
		hp = 160,
		speed = 26,
		armor = 45,
		mass = 1.8,
		size = 1.1,
		primary = { kind = "cone", weapon = "flamer" },
		tags = { "cone_primary", "special_mounts" },
		blurb = "Flamethrower cone that sets robots on fire. Blocked by cover.",
	},
	{
		id = "bombard",
		class = "C",
		name = "Bombard",
		price = 600,
		hp = 120, -- D83: 100 -> 120; it is slow, so it has to survive a little longer when caught
		speed = 19,
		firingSpeed = 0.6,
		mass = 1.1,
		primary = { kind = "rocket", weapon = "launcher" },
		tags = { "projectile_primary", "gun_mounts" },
		blurb = "Slow rockets that speed up, blast an area and push robots away.",
	},
	-- Bomber (D70): huge and tough, never shoots damage. Nets slow robots down so it
	-- can get close; Space detonates. After the blast it is small and fast at 25% HP
	-- until it heals back to Config.Bomber.rebuildAt, then it is big again.
	{
		id = "bomber",
		class = "C",
		name = "Bomber",
		price = 750, -- the most unusual robot to play, so it comes last (D73)
		hp = 230,
		speed = 20,
		armor = 60,
		mass = 2.5,
		size = 1.35,
		small = { speed = 34, size = 0.7, mass = 0.7, armor = 0 },
		skill = "skl_bomb",
		primary = { kind = "net", weapon = "netgun" },
		tags = { "net_primary", "special_mounts", "bomber" },
		blurb = "Huge and tough. Nets slow robots down; Space blows up, then it races around small until it heals.",
	},
	{ id = "class_b", class = "B", name = "Coming soon", price = 0, hp = 0, speed = 0, primary = nil, tags = {}, blurb = "", comingSoon = true },
	{ id = "class_a", class = "A", name = "Coming soon", price = 0, hp = 0, speed = 0, primary = nil, tags = {}, blurb = "", comingSoon = true },
}

local byId: { [string]: Chassis } = {}
for _, c in list do
	byId[c.id] = c
end

return {
	list = list,
	byId = byId,
	default = "rookie",
}
