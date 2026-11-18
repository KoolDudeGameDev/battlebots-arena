-- Shared server state: every robot in the arena (players and debug dummies) and
-- the hooks that let services call each other without circular requires.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Condition = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Condition"))

local World = {}

export type Entity = {
	id: number,
	player: Player?,
	isDummy: boolean,
	isBoss: boolean?, -- Phase 4b (D74)
	hitBy: { [number]: boolean }?, -- boss: entity ids of everyone who damaged it
	bossScale: number?,
	bossMaxHp: number?,
	name: string,
	generation: number, -- bumps on every spawn; stale async work compares it
	model: Model?,
	root: BasePart?,
	humanoid: Humanoid?,
	alive: boolean,

	-- Health, armor, front shield, pods and burn (D90). Only Condition changes it.
	condition: Condition.State,
	inLava: boolean?, -- standing in a LavaZone (D81)
	pushGrantAt: number, -- last knockback, so Guard allows the movement
	pushRoom: number,
	chassisId: string, -- which robot (Chassis.luau)
	visualScale: number, -- body size, stepped every 5 levels
	level: number,
	xp: number, -- xp inside the current level
	totalXp: number, -- earned this life
	score: number,
	build: any,
	stats: any,
	rng: Random,

	offer: { id: number, cards: { any } }?,
	pendingOffers: number,
	nextOfferId: number,

	aim: number,
	firing: boolean,
	nextFire: { [string]: number },
	liveProjectiles: number,

	protectedUntil: number,
	shieldUntil: number,
	fieldUntil: number, -- Null Field (D68)
	fieldRadius: number,
	slowFactor: number, -- walk speed factor from enemy fields and trap pins (1 = not slowed)
	rootedUntil: number, -- Spike Traps pin (D69)
	netUntil: number, -- hit by a Bomber net (D70)
	netImmuneUntil: number, -- a net can't slow this robot again until then (D84)
	markedUntil: number, -- marked by a Bomber net: bigger blast and Scrap Cannon hits (D84)
	pressure: number, -- Bomber: 0-100, fills from damage the shell soaks (D84)
	pressureAt: number, -- when Pressure last grew (it drains after a lull)
	husk: any, -- Bomber core: its empty shell (a Combat wall) while it stands (D84)
	reclaimT: number, -- Bomber core: seconds parked on the husk
	waitingForArena: boolean, -- killed in a boss arena: out until the fight ends (D85)
	stunnedUntil: number, -- flipped: can't attack (D72)
	skillReadyAt: number,
	dashGrantAt: number,
	lastDamagerId: number?,
	lastDamageAt: number,
	comebackTarget: number?,
	god: boolean,
	lastValidPos: Vector3?,
	dirty: boolean,
}

World.entities = {} :: { [number]: Entity }
World.byPlayer = {} :: { [Player]: Entity }

local nextId = 0
function World.newId(): number
	nextId += 1
	return nextId
end

function World.position(e: Entity): (number, number)
	local root = e.root
	if root then
		local p = root.Position
		return p.X, p.Z
	end
	return 0, 0
end

function World.hitRadius(e: Entity, config): number
	return if e.stats then e.stats.hitRadius else config.Robot.HitboxRadius
end

-- Filled in by the services at boot (see init.server.luau).
World.hooks = {} :: {
	onKill: (victim: Entity, killer: Entity?) -> (),
	addXp: (e: Entity, amount: number, source: string) -> (),
	markDirty: (e: Entity) -> (),
	spill: (x: number, z: number, count: number, value: number) -> (),
	refreshStats: (e: Entity) -> (),
	spawnDummy: (x: number, z: number, opts: any?) -> (),
	consumeDash: (e: Entity) -> (),
	applyPod: (e: Entity, kind: string) -> (),
	spawnPod: (kind: string, x: number, z: number) -> (),
	setSmall: (e: Entity, small: boolean) -> (),
	removeHusk: (e: Entity) -> (), -- the Bomber core's shell, if it stands (Combat, D84)
	addCoins: (e: Entity, amount: number) -> (),
	bossDied: (e: Entity, x: number, z: number) -> (),
	syncHp: (e: Entity) -> (),
}

return World
