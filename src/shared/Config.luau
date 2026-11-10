--!strict
-- Every tuning number from the Phase 1 GDD lives here. All values are provisional
-- until playtesting. Pure data: no requires, so Lune tests can load it directly.

local Config = {}

Config.MaxPlayers = 20 -- also set Max Players in Game Settings (D24)
Config.MaxLevel = 100 -- keep in step with XpCurve.MaxLevel (D26)

-- Arena (studs), sized for 20 players. The centre is (0, 0); the ground top sits at Y = 0.
Config.Arena = {
	HalfSize = 190,
	WallHeight = 8,
	WallThickness = 4,
	-- Zones use Chebyshev distance max(|x|, |z|) from the centre.
	Zones = {
		outer = { min = 135, max = 187 }, -- includes the tall grass by the walls; orbs float above it
		middle = { min = 80, max = 135 },
		centre = { min = 0, max = 80 }, -- the dirt plaza
	},
	-- Cover, spawns and hazards per map: see MapLayouts.luau (generated, D81).
	SpawnMinEnemyDistance = 40,
	SpawnTries = 20,
}

Config.Robot = {
	MaxHp = 100,
	MoveSpeed = 22,
	HitboxRadius = 3,
	HipHeight = 1.2,
	RootSize = { 4, 2, 4 },
	BodyLift = 2.0, -- a bigger body is raised (scale - 1) * BodyLift so its wheels stay on the ground
	BarrelLength = 3,
	-- Realistic paint jobs (D77): each player gets one, still easy to tell apart.
	Colors = {
		{ 92, 102, 64 }, -- olive drab
		{ 206, 162, 42 }, -- safety yellow
		{ 168, 84, 42 }, -- rust orange
		{ 54, 76, 108 }, -- navy steel
		{ 176, 150, 108 }, -- desert tan
		{ 142, 48, 40 }, -- brick red
		{ 44, 108, 106 }, -- teal
		{ 200, 196, 184 }, -- off-white
	},
}

Config.Camera = {
	Height = 80,
	Back = 35,
	Fov = 45,
	Lerp = 0.25, -- per frame at 60 fps
	-- Third-person look up and down (D78): camera elevation above the robot, radians.
	PitchDefault = 0.46,
	PitchMin = 0.08, -- nearly level: look out across the arena
	PitchMax = 1.15, -- nearly overhead
}

-- Robot presentation (D78). Cosmetic only: the server never reads these.
Config.Presentation = {
	-- How fast each hull turns toward where it drives (radians per second): light
	-- robots snap round, heavy ones swing.
	turnRate = { rookie = 10, bombard = 4.5, scorcher = 8, brawler = 6.5, bomber = 3.5, bomberSmall = 12 },
	swivelDegrees = 90, -- turrets and mounted weapons swivel this far either side of the hull's front (a 180-degree arc)
	reverseDot = -0.3, -- driving this far away from the aim backs the hull up instead of turning it round
	-- Weapon kick per shot: studs back along the barrel, degrees of muzzle climb, seconds to settle.
	recoil = {
		rookie = { slide = 0.35, climb = 2, settle = 0.12 },
		bombard = { slide = 0.6, climb = 7, settle = 0.45 },
		bomber = { slide = 0.4, climb = 10, settle = 0.6 },
		default = { slide = 0.2, climb = 1, settle = 0.1 },
	},
	smokeBelow = 0.35, -- HP fraction where a damaged robot starts to smoke
	sparksBelow = 0.15, -- and where it also throws sparks
}

Config.Combat = {
	ProjectileCapPerPlayer = 60,
	KillCreditWindow = 10,
	SpawnProtection = 3, -- ends early once you damage a robot
	RespawnDelay = 3,
	ShieldSplashFactor = 0.5,
	SplashEdge = 0.4, -- splash damage at the blast edge, as a fraction of the centre (D45)
	BurnTick = 0.5, -- burn damage lands in chunks, not every frame
}

-- Extra barrels and the Spreader Choke (projectile robots only).
Config.Barrels = {
	max = 5, -- 1 base + 4 Extra Barrel stacks
	damageFactor = { 1, 0.8, 0.7, 0.6, 0.55 }, -- per bullet, by barrel count (5 barrels = 2.75x total)
	gap = 0.9, -- studs between parallel bullets
	spreadDegrees = 12, -- Spreader Choke: angle between neighbouring barrels
	spreadDamage = 1.25,
	spreadRange = 0.7,
}

-- Underdog bonus (D53): +1.5% damage per level you are below your target,
-- up to +60% (reached at a 40-level gap). Set perLevel = 0 to switch it off.
Config.Underdog = { perLevel = 0.015, cap = 0.6 }

-- Shooting while moving costs accuracy (kiting).
Config.Accuracy = {
	baseDegrees = 1, -- random deviation when standing still
	movingDegrees = 8, -- added at full speed
}

-- code = the small number sent over the network for each projectile kind.
Config.Weapons = {
	blaster = {
		code = 1,
		damage = 12,
		fireRate = 4,
		speed = 120,
		range = 45,
		radius = 0.5,
	},
	-- Bombard's primary (D44, D45): rockets launch slow and accelerate.
	launcher = {
		code = 7, -- its own look: twice the Rocket Pod's size (D80)
		damage = 26,
		splashDamage = 22,
		splashRadius = 24, -- doubled (D80)
		fireRate = 1.2,
		launchSpeed = 40,
		speed = 110, -- top speed
		accel = 160,
		range = 55,
		radius = 1.4, -- doubled with the splash (D80)
		knockback = 6, -- studs of push on a scale-1 robot at the blast centre
	},
	-- Rare variants (D67). The laser is a hitscan beam: damage per tick, 10 ticks/s
	-- (70 DPS vs the blaster's 48), stopped by the first robot or cover.
	laser = { damage = 7, fireRate = 10, range = 45 },
	axe = { damage = 38, fireRate = 1.8, reach = 7, arcDegrees = 360, knockback = 3 }, -- full 360 sweep round the robot (D71)
	-- Overhead 180-degree smash (D71): an area of smashRadius centred `reach` studs
	-- beyond your hitbox, in the aim direction, landing `windup` s after the swing starts.
	hammer = { damage = 80, fireRate = 0.8, reach = 4, smashRadius = 8, knockback = 12, windup = 0.2 },
	buzzsaw = { damage = 26, fireRate = 2.5, reach = 5.5, arcDegrees = 100, knockback = 2 },
	flamer = { damagePerTick = 3.8, fireRate = 10, range = 16, coneDegrees = 50, burnDps = 8, burnDuration = 3 },
	gatling = {
		code = 2,
		damage = 5,
		fireRate = 6,
		speed = 140,
		range = 45,
		radius = 0.4,
		damagePerRank = 0.15,
		fireRatePerRank = 0.10,
		targetsCrates = true,
	},
	rocket = {
		code = 3,
		damage = 30,
		splashDamage = 18,
		splashRadius = 8,
		fireRate = 0.8,
		launchSpeed = 35,
		speed = 90, -- top speed
		accel = 140,
		range = 60,
		radius = 0.7,
		damagePerRank = 0.20,
		spreadDegrees = 8,
		targetsCrates = false,
		knockback = 8,
	},
	-- New mounts (Phase 3b)
	railgun = {
		code = 5,
		damage = 45,
		fireRate = 0.6,
		speed = 220,
		range = 110,
		radius = 0.4,
		damagePerRank = 0.20,
		pierce = true, -- passes through robots, hitting each once
		targetsCrates = false,
	},
	shock = {
		damage = 18,
		fireRate = 1.0,
		range = 25,
		chainRange = 10,
		chains = 2, -- extra jumps; +1 at ranks 3 and 5
		chainFalloff = 0.6,
		damagePerRank = 0.15,
		targetsCrates = true,
	},
	-- Minotaur Horns (the old Spike Ram): gore and toss robots you drive into.
	spikeram = {
		damage = 15,
		fireRate = 2,
		reach = 2.5, -- studs beyond the hitbox, in front
		damagePerRank = 0.25,
		minSpeedFraction = 0.3, -- only hurts while you are driving
		knockback = 18, -- a real toss (D72)
	},
	-- Bomber's net gun (D70): no damage; a robot it hits drives at netSlow for netDuration s.
	-- The net opens in flight (D72): radius grows from `radius` by openPerStud per stud flown, up to openRadius.
	netgun = { code = 6, damage = 0, fireRate = 0.8, speed = 70, range = 32, radius = 1.5, openRadius = 4.5, openPerStud = 0.3, netDuration = 2.5, netSlow = 0.45 },
	-- Melee mounts (D69)
	sidesaw = { damage = 6, fireRate = 4, reach = 2.5, damagePerRank = 0.2 }, -- grinds every robot within reach of your hitbox, any side
	traps = {
		damage = 25,
		fireRate = 0.2, -- one trap every 5 s while an enemy is within triggerRange
		fireRatePerRank = 0.15,
		damagePerRank = 0.2,
		triggerRange = 30,
		maxTraps = 3, -- the oldest goes when you drop a 4th
		radius = 3,
		armDelay = 0.5,
		life = 20,
		root = 1.0, -- seconds the robot that steps on it cannot drive
	},
	shieldgen = { passive = true, hp = 60, hpPerRank = 30, arcDegrees = 120, regenDelay = 4, regenPerSecond = 0.25 }, -- front shield, blocks direct hits; never fires
}
Config.RicochetCode = 4 -- a bounced Blaster shot (orange)
Config.Ricochet = { range = 20, damageFactor = 0.5 }

Config.Skills = {
	skl_dash = { distance = 20, duration = 0.2, cooldown = 6, cooldownPerRank = -1 },
	skl_shield = { duration = 1.5, durationPerRank = 0.5, cooldown = 12 },
	-- Flipper (D72): flips every robot in front into the air; they can't drive or attack
	-- for flipTime (+ per rank) and are thrown back, flipHeight studs up for flipAirTime s (D80).
	skl_flipper = { reach = 6, arcDegrees = 150, flipHeight = 12, flipAirTime = 1.0, flipTime = 1.2, flipTimePerRank = 0.3, knockback = 12, cooldown = 10, cooldownPerRank = -1 },
	-- Bomber's built-in skill (D70): only in big form. Splash damage with falloff.
	-- Detonate (D80): the blast fills the drawn attack ring (Stats.attackRange); damage at the
	-- ring's edge is `edge` of the centre damage.
	skl_bomb = { cooldown = 2, damage = 300, edge = 0.5, damagePerRank = 0.25, knockback = 16 },
	-- Null Field (D68): a big bubble around you; enemy shots inside crawl (dodgeable)
	-- and enemy robots inside drive at half speed. Beams, flames and melee are not slowed.
	skl_nullfield = { radius = 18, radiusPerRank = 4, duration = 3, durationPerRank = 1, cooldown = 15, projectileSlow = 0.25, robotSlow = 0.5 },
	-- Anti-bullying wall (D35, D42): blocks every robot and bullet, from both sides.
	skl_earthwall = {
		cooldown = 14,
		duration = 3,
		durationPerRank = 1.5,
		hp = 250,
		hpPerRank = 100,
		width = 16,
		widthPerRank = 4,
		height = 8,
		heightPerRank = 2,
		thickness = 2,
		distance = 5, -- studs in front of the robot (times its scale)
	},
}

Config.MountSockets = { "MountLeft", "MountRight", "MountBack" }
Config.MountRankScale = 0.15 -- weapons grow 15% per rank (D36)

-- Coins (Phase 4a, D38, D73): rare. Map coins top up to mapMax, one every
-- mapEvery[1]-[2] s. One chest at a time (shoot it open) drops pieces[1]-[2]
-- coins worth `value` each, then the next appears respawn[1]-[2] s later.
Config.Coins = {
	code = 9, -- pickup kind code (after the pods)
	value = 5,
	mapMax = 3,
	mapEvery = { 60, 90 },
	zones = { "outer", "middle", "centre" },
	chest = { hp = 200, size = 5, radius = 3.2, pieces = { 3, 7 }, respawn = { 240, 360 }, zones = { "middle", "centre" } },
}

-- Bosses (Phase 4b, D39, D74). One at a time, every every[1]-[2] s while at least
-- minPlayers are in, after a `warning`. Everyone who hit it gets the same reward;
-- more scatters on the ground. Its hazard then runs for hazardDuration s.
Config.Bosses = {
	minPlayers = 2,
	every = { 420, 600 },
	warning = 20,
	despawnAfter = 240,
	hpBase = 1500,
	hpPerPlayer = 400,
	reward = { coins = 60, xp = 600, scatterCoins = 8, scatterOrbs = 10, scatterOrbValue = 30 },
	hazardDuration = 360,
	chaseRange = 160, -- it hunts the nearest robot within this; otherwise walks to the centre
	list = {
		inferno = {
			name = "Inferno Giant",
			chassis = "scorcher",
			color = { 150, 58, 34 }, -- burnt orange
			scale = 3,
			speed = 9,
			hazard = "vents",
			-- A long cone of fire for 1 s that sets robots burning.
			attack = { kind = "flame", every = 2.5, duration = 1, range = 34, coneDegrees = 70, damage = 24, burnDps = 8, burnDuration = 3 },
		},
		forge = {
			name = "Forge Titan",
			chassis = "brawler",
			stacks = { var_hammer = 1 },
			color = { 120, 125, 135 },
			scale = 3.2,
			speed = 8,
			hazard = "hammers",
			-- A red warning circle, then the hammer lands on it.
			attack = { kind = "smash", every = 3, windup = 0.8, reach = 6, radius = 16, damage = 45, knockback = 20 }, -- radius 12 -> 16 (D80)
		},
		grinder = {
			name = "Grinder",
			chassis = "brawler",
			mounts = { "wpn_sidesaw", "wpn_spikeram" },
			color = { 196, 152, 40 }, -- worn industrial yellow
			scale = 2.8,
			speed = 10,
			hazard = "saws",
			-- Charges at a robot with its saws spinning, hurting everything it hits.
			attack = { kind = "charge", every = 5, duration = 1.2, speedMult = 3.5, damage = 30, knockback = 18 },
		},
	},
}

-- Maps (D79, D81, 09-environment-bible.md). Boss fights happen in the boss's own
-- arena; a win leaves its biome on the overworld for Bosses.hazardDuration s.
-- Timings: fade out, swap, fade in; victory window; revert warning before going home.
-- Colours are { r, g, b } (0-255) so Lune can load this file; Color3 is built where used.
local function rgb(r: number, g: number, b: number): { number }
	return { r, g, b }
end
local function hex(h: number): { number }
	return rgb(bit32.rshift(h, 16), bit32.band(bit32.rshift(h, 8), 255), bit32.band(h, 255))
end
Config.Maps = {
	fade = 0.5,
	victory = 6,
	revertWarning = 20,
	arenaFor = { forge = "arena_forge", inferno = "arena_inferno", grinder = "arena_grinder" },
	biomeFor = { forge = "forge_highlands", inferno = "inferno_fields", grinder = "grinder_scrapyard" },
	-- Lava (Q3): damage over time while inside, plus burning and a slow.
	lava = { dps = 30, burnDps = 8, burnDuration = 2, slow = 0.6 },
	-- Dying in a boss arena (Q2): keep your level, lose this share of the XP to your next level.
	arenaDeath = { respawn = 5, xpLoss = 0.25 },
	-- Arena health pads: a Health Pod reappears on each pad every `every` s.
	pads = { every = 30 },
	-- The colour each map fades through when you arrive (bible section 12).
	fadeColor = {
		grassland = hex(0x3C5A28), forge_highlands = hex(0x5A3010), inferno_fields = hex(0x5A1408),
		grinder_scrapyard = hex(0x4A3A10), arena_forge = hex(0x5A3010), arena_inferno = hex(0x5A1408), arena_grinder = hex(0x4A3A10),
	},
	-- Lighting per map (bible section 10). Grassland keeps its current values.
	lighting = {
		grassland = { clock = 14.5, brightness = 2.4, ambient = rgb(135, 140, 150), atmosphere = { density = 0.3, offset = 0.2, color = rgb(205, 200, 185), decay = rgb(110, 130, 160), glare = 0.15, haze = 1.4 }, cc = { brightness = 0.02, contrast = 0.06, saturation = 0.12, tint = hex(0xFFFFFF) }, bloom = { intensity = 0.5, size = 24, threshold = 1.6 }, sunRays = 0.06 },
		forge_highlands = { clock = 16.5, brightness = 2.2, ambient = hex(0x8C8278), atmosphere = { density = 0.38, offset = 0.1, color = hex(0xC8B8A0), decay = hex(0x7A6A58), glare = 0.2, haze = 1.8 }, cc = { brightness = 0, contrast = 0.10, saturation = 0.05, tint = hex(0xFFF0DC) }, bloom = { intensity = 0.6, size = 24, threshold = 1.3 }, sunRays = 0.10 },
		inferno_fields = { clock = 18.5, brightness = 1.6, ambient = hex(0x6A3C2C), atmosphere = { density = 0.42, offset = 0.15, color = hex(0x8C4A2A), decay = hex(0x3C1408), glare = 0.3, haze = 2.0 }, cc = { brightness = 0, contrast = 0.12, saturation = 0.15, tint = hex(0xFFE0CC) }, bloom = { intensity = 0.8, size = 28, threshold = 1.1 }, sunRays = 0 },
		grinder_scrapyard = { clock = 19.5, brightness = 1.5, ambient = hex(0x5A5C60), atmosphere = { density = 0.40, offset = 0.1, color = hex(0x8A8070), decay = hex(0x3A3A40), glare = 0, haze = 1.6 }, cc = { brightness = 0.02, contrast = 0.12, saturation = -0.08, tint = hex(0xFFFFFF) }, bloom = { intensity = 0.6, size = 24, threshold = 1.2 }, sunRays = 0 },
		arena_forge = { clock = 0, brightness = 1.0, ambient = hex(0x5A4234), atmosphere = { density = 0.40, offset = 0, color = hex(0x6A3A20), decay = hex(0x2A1408), glare = 0, haze = 2.0 }, cc = { brightness = 0, contrast = 0.12, saturation = 0.05, tint = hex(0xFFE2C8) }, bloom = { intensity = 0.8, size = 28, threshold = 1.2 }, sunRays = 0 },
		arena_inferno = { clock = 18.8, brightness = 1.4, ambient = hex(0x5A2A1E), atmosphere = { density = 0.45, offset = 0.1, color = hex(0x7A3018), decay = hex(0x2A0E08), glare = 0.3, haze = 2.4 }, cc = { brightness = 0, contrast = 0.12, saturation = 0.20, tint = hex(0xFFD8C0) }, bloom = { intensity = 0.9, size = 28, threshold = 1.1 }, sunRays = 0 },
		arena_grinder = { clock = 21, brightness = 1.2, ambient = hex(0x5E6268), atmosphere = { density = 0.35, offset = 0, color = hex(0x606A70), decay = hex(0x30343A), glare = 0, haze = 1.4 }, cc = { brightness = 0, contrast = 0.15, saturation = -0.10, tint = hex(0xFFFFFF) }, bloom = { intensity = 0.6, size = 24, threshold = 1.3 }, sunRays = 0 },
	},
}

-- Arena hazards a boss leaves behind (D39). Cycles repeat; each spot starts at its
-- own offset so they don't all fire together. Since D81 their positions come from
-- the map (MapLayouts vents, hammers, saws); ring, side and reach below are unused.
Config.Hazards = {
	vents = {
		name = "Flame Vents",
		cycle = { { name = "idle", seconds = 3 }, { name = "glow", seconds = 1 }, { name = "flame", seconds = 2 } },
		radius = 4,
		dps = 20,
		ring = 100, -- 8 vents on this ring, between the walls
	},
	hammers = {
		name = "Edge Hammers",
		cycle = { { name = "raise", seconds = 4 }, { name = "shake", seconds = 1 }, { name = "slam", seconds = 0.6 } },
		radius = 7,
		damage = 40,
		knockback = 15,
		ring = 168, -- 8 hammers near the edge
	},
	saws = {
		name = "Floor Saws",
		radius = 2.5,
		speed = 18,
		damage = 25,
		hitEvery = 0.5,
		knockback = 8,
		-- 4 straight tracks across the middle ring: from (-reach, side) to (reach, side), turned 4 ways.
		side = 110,
		reach = 70,
	},
}

-- Bomber forms (D70): HP left after detonating (fraction of max, if higher), and the
-- HP fraction that rebuilds the bombs and makes it big again. The small form heals
-- smallRegenPerSecond of max HP per second, the one exception to D33 (D80).
Config.Bomber = { hpAfter = 0.25, rebuildAt = 0.6, smallRegenPerSecond = 0.01 }

-- Health never regenerates (D33), except the small Bomber (D80). Armor comes only from the Armor Plating card.
Config.Armor = {
	firstStack = 30,
	perStack = 20,
	deflectBase = 0.10,
	deflectPerStack = 0.05,
	deflectCap = 0.30,
	regenDelay = 4.5, -- seconds without taking damage (D80)
	regenPerSecond = 0.10, -- fraction of max armor (D80)
	tempDeflect = 0.10, -- deflect chance of Armor Pod armor without plating
}

-- Booster pods on the map (D34, D41). count = how many exist at once.
Config.Pods = {
	health = { code = 5, zones = { "outer", "middle" }, count = 10, every = 6, heal = 0.15 },
	regen = { code = 6, zones = { "middle" }, count = 2, every = 45, heal = 0.30, duration = 8 },
	armor = { code = 7, zones = { "centre" }, count = 1, every = 60, tempArmor = 50, duration = 20 },
	-- Flat +60 max HP for 30 s: a big boost at Lv 0 (100 HP), a small one at Lv 100 (300 HP).
	fortify = { code = 8, zones = { "middle", "centre" }, count = 2, every = 40, bonusHp = 60, duration = 30 },
}

-- Automatic growth on every level (D26): heavier and harder-hitting, but slower.
Config.LevelGrowth = {
	hpPerLevel = 0.02, -- x3 max HP at Lv 100
	damagePerLevel = 0.004, -- +40% damage at Lv 100
	speedPerLevel = -0.0025, -- -25% speed at Lv 100
	speedFloor = 0.75,
	scalePerLevel = 0.004, -- +40% size at Lv 100 (a bigger target)
}

-- What one stack of each stat upgrade adds.
Config.StatPerStack = {
	stat_damage = 0.10,
	stat_firerate = 0.10,
	stat_hp = 15,
	stat_speed = 0.05,
	stat_range = 0.08,
	stat_range_shotspeed = 0.04,
	stat_cone = 8, -- Wider Flames: degrees per stack (D71)
	stat_pickup = 0.25,
	fb_reinforce_hp = 5,
	fb_reinforce_damage = 0.02,
	fb_cache_fraction = 0.30,
}

-- XP sources
Config.Orbs = {
	small = { value = 2, size = 1.0, heal = 1 },
	medium = { value = 8, size = 1.5, heal = 3 },
	core = { value = 30, size = 2.0, heal = 8 }, -- purple, so it never reads as a gold coin
	death = { value = 0, size = 1.6, heal = 10 }, -- value set at spill time
}
Config.OrbTargets = {
	outer = { small = 170 },
	middle = { small = 130, medium = 48 },
	centre = { small = 40, medium = 50, core = 16 }, -- bigger plaza, richer centre
}
Config.OrbRefillPerSecond = 2 -- per zone
Config.OrbCellSize = 20
Config.PickupRadius = 6
Config.PickupInterval = 0.1

Config.Crates = {
	small = {
		hp = 40,
		size = 4,
		radius = 2.6,
		count = 19,
		zones = { "outer", "middle" },
		respawn = 20,
		drops = { small = 4, medium = 1 },
	},
	large = {
		hp = 250,
		size = 7,
		radius = 4.2,
		count = 5,
		zones = { "centre" },
		respawn = 45,
		drops = { core = 2, medium = 4 },
	},
}

Config.Death = {
	SpillFraction = 0.4,
	KillShare = 0.25,
	KillMinimum = 20,
	DeathOrbDespawn = 60,
	ComebackMultiplier = 2.5,
	ComebackTargetFraction = 0.5,
}

-- Level-band colours for the "Lv N" tag (RGB 0-255).
Config.LevelBands = {
	{ min = 0, color = { 170, 170, 170 } },
	{ min = 20, color = { 90, 200, 110 } },
	{ min = 40, color = { 80, 150, 255 } },
	{ min = 60, color = { 180, 100, 255 } },
	{ min = 80, color = { 255, 140, 60 } },
	{ min = 100, color = { 255, 200, 60 } },
}

Config.RarityColors = {
	Common = { 200, 200, 200 },
	Rare = { 70, 150, 255 },
	Epic = { 190, 90, 255 },
	Fallback = { 120, 200, 140 },
}

-- Remote budgets: tokens per second (burst = 2x).
Config.RateLimits = {
	AimUpdate = 30,
	SetFiring = 10,
	UseSkill = 5,
	PickUpgrade = 10,
	ClientReady = 1,
	BuyRobot = 2,
	EquipRobot = 2,
}

Config.AntiCheat = {
	Interval = 0.2,
	Tolerance = 1.5,
	Slack = 2,
	DashWindow = 0.6,
}

Config.TrayCollapseAfter = 10

-- Debug commands run in Studio for everyone, and in live servers for these UserIds only.
Config.DebugUserIds = {} :: { number }

return Config
