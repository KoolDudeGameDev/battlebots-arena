--!strict
-- The server-to-client contract (D93): every Instance attribute and every robot part
-- name the two sides agree on, in one place. Pure data. `tests/Contract.spec.luau`
-- reads the source and fails when something is set but never read, read but never
-- set, or looked up on a robot but never built, so a typo can't silently hide an
-- effect. Add a line here when you add an attribute or a looked-up part.

local Contract = {}

-- Attribute name -> what it holds. Mostly on robot models; the rest are noted.
Contract.attributes = {
	-- A robot's state (model attributes, set by Match and Combat)
	HP = "health now, rounded (also crates and bosses)",
	MaxHP = "max health (also crates)",
	Armor = "armor now, plating plus pod armor, rounded",
	MaxArmor = "plating at full",
	Guard = "front shield left, 0-1 of full",
	Level = "level",
	Chassis = "which robot (Chassis id)",
	Small = "the Bomber's small core form",
	VisualScale = "body size, stepped with level",
	HitRadius = "hitbox radius (the ground disc)",
	AttackRange = "main weapon reach (the faint ring, camera zoom)",
	EntityId = "the server's entity id",
	UserId = "the owner's UserId (0 for dummies and bosses)",
	DisplayName = "name over the robot",
	Color = "the robot's paint, kept for respawns and redressing",
	DressedLevel = "the level its parts were last dressed for",
	Scavenger = "has the Scavenger card (orbs show their repair)",
	Protected = "spawn protection is on",
	Firing = "attacking now (flames, saws, recoil)",
	Shield = "Shield Pulse is up",
	Field = "Null Field radius while active, else 0",
	Flipped = "flipped and stunned",
	Flips = "times this robot used its Flipper (counter)",
	Netted = "caught in a Bomber net",
	Marked = "marked by a Bomber net",
	Pressure = "the Bomber shell's Pressure, 0-100",
	Burning = "on fire",
	RegenUntil = "server time the Regen Pod ends",
	TempArmorUntil = "server time the Armor Pod's armor ends",
	FortifyUntil = "server time Fortify's bonus HP ends",
	Smashes = "hammer smash counter (named by a hub's SmashCounter)",
	BossName = "a boss's display name",

	-- On robot parts (set by RobotBuilder, read by the client's animation)
	ViewFade = "part fades in third person when it blocks the view",
	Blink = "lamp blink rate in Hz",
	HeatGlow = "glows with the Scorcher's heat",
	Slide = "gun recoil slide, studs",
	Climb = "gun recoil muzzle climb, radians",
	Settle = "gun recoil settle time, seconds",
	Mount = "the mount weapon id a swivel carries",
	SwingRate = "Battle Axe sweeps per second",
	SmashCounter = "which model attribute counts this hammer's smashes",

	-- On Workspace (set by Arena and Bosses)
	Map = "the map id now",
	MapDisplay = "the map's display name",
	MapPhase = "the map flow phase (grassland, warning, arena, victory, biome, revert)",
	MapEndsAt = "server time the phase ends (0 = no end)",
	MapBoss = "the boss of this flow",
	CoverBroken = "smashed cover keys, \"key,key,\"",
}

-- Robot part names the client looks up, made by RobotBuilder. A name with motor =
-- true also has a "<name>Motor" Motor6D the client turns.
Contract.parts = {
	Body = { motor = false, about = "the folder of a robot's visual parts" },
	Gun = { motor = true, about = "the main gun frame (recoil)" },
	Muzzle = { motor = false, about = "where a mount's shots leave (an Attachment)" },
	Turret = { motor = true, about = "turns toward the aim" },
	Swivel = { motor = true, about = "a mount's swivel" },
	Nozzle = { motor = false, about = "the flamethrower tip; holds the flame emitters and light" },
	NozzleTip = { motor = false, about = "the flamethrower's glowing tip" },
	StackTip = { motor = false, about = "the Scorcher's exhaust tips" },
	Flame = { motor = false, about = "the flame jet emitter" },
	FlameCore = { motor = false, about = "the white-hot core emitter" },
	FlameEmbers = { motor = false, about = "the ember emitter" },
	FlameSmoke = { motor = false, about = "the smoke rolling off the flame's end" },
	FlameLight = { motor = false, about = "the flame's flickering light" },
	PilotLight = { motor = false, about = "the idle pilot flame" },
	Saw = { motor = true, about = "the Brawler's saw" },
	Swing = { motor = true, about = "the Battle Axe sweep" },
	SideSaw = { motor = true, about = "the Vertical Saw" },
	SmashHub = { motor = true, about = "the Sledgehammer" },
	FlipperHub = { motor = true, about = "the Flipper plate" },
	GuardShield = { motor = false, about = "the Shield Generator's barrier" },
}

return Contract
