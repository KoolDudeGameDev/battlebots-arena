-- Server-authoritative combat: firing, projectiles as data, 2D hit tests,
-- damage through armor, splash with falloff, knockback, burn, ricochet,
-- skills and the Earth Wall. Clients only send intent (aim, trigger, skill);
-- they never report hits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Combat2D = require(Shared.Combat2D)
local MapQuery = require(Shared.MapQuery)
local Condition = require(Shared.Condition)
local MountFire = require(Shared.MountFire)
local Stats = require(Shared.Stats)
local Chassis = require(Shared.Chassis)
local Upgrades = require(Shared.Upgrades)
local World = require(script.Parent.World)
local Arena = require(script.Parent.Arena)
local Guard = require(script.Parent.Guard)
local Pickups = require(script.Parent.Pickups)

local Combat = {}

local W = Config.Weapons
local RICOCHET_CODE = Config.RicochetCode
local RICOCHET_BOUNCE_CODE = Config.RicochetBounceCode
local SPAWN_RECORD = 37 -- bytes per projectile in the spawn buffer
local SPAWN_PER_PACKET = 24 -- 24 * 37 = 888 bytes, under the 1000-byte unreliable limit
local END_PER_PACKET = 200
local MOUNT_WEAPON = {
	wpn_gatling = "gatling",
	wpn_rocket = "rocket",
	wpn_railgun = "railgun",
	wpn_shock = "shock",
	wpn_spikeram = "spikeram",
	wpn_sidesaw = "sidesaw",
	wpn_traps = "traps",
	wpn_shieldgen = "shieldgen",
}

type Projectile = {
	id: number,
	ownerId: number,
	code: number,
	x: number,
	z: number,
	dx: number,
	dz: number,
	angle: number,
	speed: number,
	accel: number, -- rockets speed up (D45); 0 for bullets
	maxSpeed: number,
	remaining: number,
	damage: number,
	radius: number,
	primary: boolean,
	bounced: boolean,
	splashDamage: number?,
	splashRadius: number?,
	knockback: number?,
	pierce: boolean?,
	hitIds: { [number]: boolean }?,
	skipEntity: number?,
	skipCrate: number?,
}

local projectiles: { Projectile } = {}
local nextProjectileId = 0
local spawnQueue: { Projectile } = {}
local endQueue: { number } = {}
local rng = Random.new()

-- Earth Walls (D35): oriented boxes that block every robot and bullet.
type Wall = { id: number, cx: number, cz: number, ux: number, uz: number, halfU: number, halfV: number, hp: number, part: Part? }
local walls: { Wall } = {}
-- Spike Traps on the ground (D69): server data plus one anchored Part each.
type Trap = { ownerId: number, x: number, z: number, armAt: number, dieAt: number, damage: number, part: Part? }
local traps: { Trap } = {}
local trapFolder: Folder
local nextWallId = 0
local wallFolder: Folder

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- Attributes are only rewritten when the rounded value changes (regen runs per frame).
local function syncHp(e: World.Entity)
	local rounded = math.floor(e.condition.hp + 0.5)
	local model = e.model
	if model and model:GetAttribute("HP") ~= rounded then
		model:SetAttribute("HP", rounded)
	end
end
Combat.syncHp = syncHp

local function syncArmor(e: World.Entity)
	local rounded = math.floor(e.condition.armor + e.condition.tempArmor + 0.5)
	local model = e.model
	if model and model:GetAttribute("Armor") ~= rounded then
		model:SetAttribute("Armor", rounded)
	end
end
Combat.syncArmor = syncArmor

local function isShell(e: World.Entity): boolean
	return e.chassisId == "bomber" and not e.build.small
end

-- Bomber Pressure (D84), 0-100, shown to everyone as the model's Pressure attribute.
local function addPressure(e: World.Entity, amount: number)
	if amount <= 0 or not isShell(e) then
		return
	end
	e.pressure = math.min(100, e.pressure + amount)
	e.pressureAt = now()
	if e.model then
		e.model:SetAttribute("Pressure", math.floor(e.pressure))
	end
end

local function setPressure(e: World.Entity, value: number)
	e.pressure = value
	if e.model then
		e.model:SetAttribute("Pressure", math.floor(value))
	end
end

-- Bomber net (D70, D84): marks the robot, slows it for netDuration s, then it can't be
-- slowed again for `immunity` s (it can still be marked). The netter gains Pressure.
function Combat.applyNet(e: World.Entity, hx: number, hz: number, owner: World.Entity?)
	local N = Config.Weapons.netgun
	local t = now()
	local marked = (owner and owner.build.stacks.bmb_marked or 0) * Config.Bomber.cards.markedExtra
	e.markedUntil = math.max(e.markedUntil, t + N.markDuration + marked)
	if t >= e.netImmuneUntil then
		e.netUntil = t + N.netDuration
		e.netImmuneUntil = e.netUntil + N.immunity
	end
	if e.model then
		e.model:SetAttribute("Netted", t < e.netUntil)
		e.model:SetAttribute("Marked", true)
	end
	if owner then
		local valve = owner.build.stacks.bmb_valve or 0
		addPressure(owner, Config.Bomber.pressure.perNet + valve * Config.Bomber.cards.valveNet)
	end
	Remotes.Effect:FireAllClients("net", hx, hz, 3)
end

-- Shield Generator front-shield size for this robot (0 without the mount), grows with level like HP.
local function guardMax(e: World.Entity): number
	local rank = e.build.stacks.wpn_shieldgen or 0
	if rank <= 0 then
		return 0
	end
	local g = Config.Weapons.shieldgen
	return (g.hp + g.hpPerRank * (rank - 1)) * (1 + Config.LevelGrowth.hpPerLevel * e.level)
end

function Combat.syncGuard(e: World.Entity)
	if e.model then
		local max = guardMax(e)
		e.model:SetAttribute("Guard", if max > 0 then math.floor(e.condition.guardHp / max * 100) / 100 else 0)
	end
end

-- Walk speed now: recoil while firing (ranged robots), times any enemy Null Field or trap pin.
function Combat.applyWalkSpeed(e: World.Entity)
	if e.humanoid then
		e.humanoid.WalkSpeed = Stats.moveSpeed(e.stats, e.firing) * e.slowFactor
	end
end

local function setFiring(e: World.Entity, firing: boolean)
	e.firing = firing
	local model = e.model
	if model and model:GetAttribute("Firing") ~= firing then
		model:SetAttribute("Firing", firing) -- drives saw spin and flame particles on clients
		Combat.applyWalkSpeed(e)
	end
end

local function endProtection(e: World.Entity)
	if e.protectedUntil > 0 then
		e.protectedUntil = 0
		if e.model then
			e.model:SetAttribute("Protected", false)
		end
	end
end

local function spawnProjectile(owner: World.Entity, x: number, z: number, angle: number, speed: number, range: number, damage: number, radius: number, code: number, opts: { [string]: any }?)
	nextProjectileId += 1
	local p: Projectile = {
		id = nextProjectileId,
		ownerId = owner.id,
		code = code,
		x = x,
		z = z,
		dx = math.cos(angle),
		dz = math.sin(angle),
		angle = angle,
		speed = speed,
		accel = 0,
		maxSpeed = speed,
		remaining = range,
		damage = damage,
		radius = radius,
		primary = false,
		bounced = false,
	}
	if opts then
		for k, v in opts do
			(p :: any)[k] = v
		end
	end
	table.insert(projectiles, p)
	table.insert(spawnQueue, p)
	owner.liveProjectiles += 1
end

-- How fast a robot is moving, as a fraction of its top speed (for kiting inaccuracy).
local function speedFraction(e: World.Entity): number
	local root = e.root
	if not root then
		return 0
	end
	local v = root.AssemblyLinearVelocity
	return math.sqrt(v.X * v.X + v.Z * v.Z) / math.max(1, e.stats.speed)
end

-- Targets ---------------------------------------------------------------------

type Target = { x: number, z: number, r: number, e: World.Entity?, crate: Pickups.Crate? }

local function isTargetable(e: World.Entity, t: number): boolean
	return e.alive and t >= e.protectedUntil
end

-- Two players on the same side: everyone is in boss arenas (co-op, Q1).
local function allies(a: World.Entity?, b: World.Entity): boolean
	return a ~= nil and a ~= b and a.player ~= nil and b.player ~= nil and Arena.isArena()
end

-- Every enemy robot (and optionally crate) as a hit target.
local function targets(selfId: number, crates: boolean): { Target }
	local t = now()
	local out: { Target } = {}
	local self = World.entities[selfId]
	for _, e in World.entities do
		if e.id ~= selfId and e.root and isTargetable(e, t) and not allies(self, e) then
			local x, z = World.position(e)
			table.insert(out, { x = x, z = z, r = World.hitRadius(e, Config), e = e })
		end
	end
	if crates then
		for _, c in Pickups.crates do
			if c.alive then
				table.insert(out, { x = c.x, z = c.z, r = c.radius, crate = c })
			end
		end
	end
	return out
end

-- Nearest target within range of (x, z); robots first, crates only if no robot.
local function nearestTarget(selfId: number, x: number, z: number, range: number, crates: boolean, skipEntity: number?, skipCrate: number?): (number?, number?)
	local best: Target? = nil
	local bestD = math.huge
	for pass = 1, 2 do
		if pass == 2 and (best or not crates) then
			break
		end
		for _, tg in targets(selfId, pass == 2) do
			local isCrate = tg.crate ~= nil
			if (pass == 1) == isCrate then
				continue
			end
			if (tg.e and tg.e.id == skipEntity) or (tg.crate and tg.crate.id == skipCrate) then
				continue
			end
			local d = math.sqrt((tg.x - x) ^ 2 + (tg.z - z) ^ 2) - tg.r
			if d <= range and d < bestD then
				best, bestD = tg, d
			end
		end
	end
	if best then
		return best.x, best.z
	end
	return nil, nil
end

-- How far along the line (0..1) the first cover or Earth Wall is, or nil if clear.
local function blockedAt(x1: number, z1: number, x2: number, z2: number): number?
	local best: number? = nil
	local function take(ht: number?)
		if ht and (best == nil or ht < best) then
			best = ht
		end
	end
	take(Arena.blockedAt(x1, z1, x2, z2, 0))
	for _, w in walls do
		take(Combat2D.segmentOBB(x1, z1, x2, z2, w.cx, w.cz, w.ux, w.uz, w.halfU, w.halfV))
	end
	return best
end

-- Is the straight line between two points blocked by cover or an Earth Wall?
local function lineBlocked(x1: number, z1: number, x2: number, z2: number): boolean
	return blockedAt(x1, z1, x2, z2) ~= nil
end

-- Knockback (D45): the owning client moves its own robot; Guard allows for it.
local function knock(target: World.Entity, fromX: number, fromZ: number, force: number, flip: number?)
	local player = target.player
	if not player or not target.alive or force <= 0 then
		return
	end
	local x, z = World.position(target)
	local dx, dz = x - fromX, z - fromZ
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-3 then
		local a = rng:NextNumber(0, 2 * math.pi)
		dx, dz, len = math.cos(a), math.sin(a), 1
	end
	local push = Combat2D.knockback(force, target.stats.scale, target.stats.mass)
	target.pushGrantAt = now()
	target.pushRoom = push
	Remotes.Knockback:FireClient(player, dx / len * push, dz / len * push, flip) -- flip = seconds airborne (Flipper)
end
Combat.knock = knock -- bosses and hazards push robots too (D74)

-- Flipper on a robot nobody drives (dummies, D78): the server somersaults its
-- anchored root, the same arc a player's client plays (InputController.flipOver).
local function flipAnchored(target: World.Entity, fromX: number, fromZ: number, duration: number)
	local root = target.root
	if not root or not root.Anchored then
		return
	end
	local start = root.CFrame
	local push = Vector3.new(start.Position.X - fromX, 0, start.Position.Z - fromZ)
	local axis = if push.Magnitude > 0.05 then push.Unit:Cross(Vector3.yAxis) * -1 else start.RightVector
	local F = Config.Skills.skl_flipper
	local airTime = math.min(F.flipAirTime, duration)
	local gen = target.generation
	local t = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		t += dt
		local k = math.min(1, t / airTime)
		if not root.Parent or target.generation ~= gen then
			conn:Disconnect()
			return
		end
		root.CFrame = CFrame.new(start.Position + Vector3.new(0, F.flipHeight * 4 * k * (1 - k), 0)) * CFrame.fromAxisAngle(axis, k * 2 * math.pi) * start.Rotation
		if k >= 1 then
			conn:Disconnect()
			root.CFrame = start
		end
	end)
end

-- Damage ----------------------------------------------------------------------

-- Damage numbers for every hit (D43): the shooter sees what they dealt, the
-- victim sees what they took, split into armor and health.
local function feedback(target: World.Entity, attacker: World.Entity?, hx: number, hz: number, deflected: boolean, armorTaken: number, hpTaken: number)
	local function send(player: Player, amount: number, kind: string)
		Remotes.HitFeedback:FireClient(player, target.id, hx, hz, math.floor(amount + 0.5), kind)
	end
	if attacker and attacker.player and attacker ~= target then
		send(attacker.player, armorTaken + hpTaken, if deflected then "block" else "dealt")
	end
	local victim = target.player
	if victim then
		if deflected then
			send(victim, 0, "block")
		else
			if armorTaken > 0 then
				send(victim, armorTaken, "armor")
			end
			if hpTaken > 0 then
				send(victim, hpTaken, "taken")
			end
		end
	end
end

-- What the robot's build allows right now, for Condition (D90).
local function limitsOf(e: World.Entity): Condition.Limits
	return {
		maxHp = e.stats.maxHp,
		maxArmor = e.stats.maxArmor,
		maxGuard = guardMax(e),
		deflectChance = e.stats.deflectChance,
		armorRegenDelay = Config.Armor.regenDelayByChassis[e.chassisId] or Config.Armor.regenDelay,
	}
end

-- splash = true means it cannot deflect (explosions, flames, burn).
-- The attacker and map rules are decided here; how the hit lands on the robot is
-- Condition's (D90). This applies what comes back: attributes, sparks, hit numbers,
-- kill credit.
function Combat.damage(target: World.Entity, amount: number, attacker: World.Entity?, splash: boolean, hx: number, hz: number)
	local t = now()
	-- Boss arenas are co-op (Q1): players can't hurt each other there.
	if attacker and attacker ~= target and attacker.player and target.player and Arena.isArena() then
		return
	end
	local byOther = attacker ~= nil and attacker ~= target
	-- Shield Generator (D69): only direct hits from inside the front arc reach it.
	local fromFront = false
	if byOther and not splash and target.condition.guardHp > 0 then
		local tx, tz = World.position(target)
		local ax, az = World.position(attacker :: World.Entity)
		local half = math.rad(Config.Weapons.shieldgen.arcDegrees / 2)
		fromFront = Combat2D.angleDiff(math.atan2(az - tz, ax - tx), target.aim) <= half
	end
	-- Underdog bonus (D53): lower levels hit higher levels harder.
	local scale = 1
	if byOther and not target.isDummy and not target.isBoss then
		scale = Stats.underdogFactor(Config, (attacker :: World.Entity).level, target.level)
	end
	local r = Condition.hit(target.condition, {
		amount = amount,
		splash = splash,
		t = t,
		roll = rng:NextNumber(),
		protected = not target.alive or target.god or t < target.protectedUntil,
		shielded = t < target.shieldUntil,
		fromFront = fromFront,
		scale = scale,
		shell = isShell(target),
	}, limitsOf(target), Config)
	if r.guardAbsorbed > 0 or r.stage == "guarded" then
		Combat.syncGuard(target)
		Remotes.Effect:FireAllClients("deflect", hx, hz, 1)
	end
	if r.stage ~= "landed" then
		return
	end

	if byOther then
		local a = attacker :: World.Entity
		-- Damaging a robot ends your own spawn protection (auto-fire alone does not).
		endProtection(a)
		-- Bosses remember everyone who hit them: they all share the reward (D39).
		if target.hitBy and a.player then
			target.hitBy[a.id] = true
		end
		target.lastDamagerId = a.id
		target.lastDamageAt = t
	end
	feedback(target, attacker, hx, hz, r.deflected, r.armorTaken, r.hpTaken)
	if r.deflected then
		Remotes.Effect:FireAllClients("deflect", hx, hz, 1.5)
		return
	end
	syncArmor(target)
	addPressure(target, (r.armorTaken + r.hpTaken) * Config.Bomber.pressure.perDamage) -- the shell turns hits into Pressure (D84)

	syncHp(target)
	if r.died then
		local killer = nil
		if target.lastDamagerId and t - target.lastDamageAt <= Config.Combat.KillCreditWindow then
			killer = World.entities[target.lastDamagerId]
		end
		World.hooks.onKill(target, killer)
	else
		World.hooks.markDirty(target)
	end
end

-- Booster pods (D34, D41). Health only ever comes from the map.
function Combat.applyPod(e: World.Entity, kind: string)
	local c = e.condition
	if Condition.pod(c, kind, now(), limitsOf(e), Config) then
		World.hooks.refreshStats(e) -- Fortify raised max HP
	end
	syncHp(e)
	syncArmor(e)
	if e.model then
		if kind == "regen" then
			e.model:SetAttribute("RegenUntil", c.regenUntil)
		elseif kind == "armor" then
			e.model:SetAttribute("TempArmorUntil", c.tempArmorUntil)
		elseif kind == "fortify" then
			e.model:SetAttribute("FortifyUntil", c.bonusHpUntil)
		end
	end
	World.hooks.markDirty(e)
end

-- Earth Wall ------------------------------------------------------------------

local function destroyWall(w: Wall)
	local i = table.find(walls, w)
	if i then
		table.remove(walls, i)
	end
	if w.part then
		Remotes.Effect:FireAllClients("wall", w.cx, w.cz, w.halfV)
		w.part:Destroy()
		w.part = nil
	end
end

local function damageWall(w: Wall, amount: number)
	w.hp -= amount
	if w.hp <= 0 then
		destroyWall(w)
	end
end

local function spawnWall(e: World.Entity, rank: number)
	local S = Config.Skills.skl_earthwall
	local width = S.width + S.widthPerRank * (rank - 1)
	local height = S.height + S.heightPerRank * (rank - 1)
	local x, z = World.position(e)
	local ux, uz = math.cos(e.aim), math.sin(e.aim)
	local reach = S.distance * e.stats.scale + S.thickness / 2
	local half = Arena.half() - 2
	local cx = math.clamp(x + ux * reach, -half, half)
	local cz = math.clamp(z + uz * reach, -half, half)

	nextWallId += 1
	local w: Wall = {
		id = nextWallId,
		cx = cx,
		cz = cz,
		ux = ux,
		uz = uz,
		halfU = S.thickness / 2,
		halfV = width / 2,
		hp = S.hp + S.hpPerRank * (rank - 1),
		part = nil,
	}
	-- Facing the aim: the part's -Z is the thickness axis, X is the wide axis.
	local top = CFrame.lookAt(Vector3.new(cx, height / 2, cz), Vector3.new(cx + ux, height / 2, cz + uz))
	local p = Instance.new("Part")
	p.Name = "EarthWall"
	p.Anchored = true
	p.Size = Vector3.new(width, height, S.thickness)
	p.Color = Color3.fromRGB(120, 92, 64)
	p.Material = Enum.Material.Rock
	p.CFrame = top - Vector3.new(0, height, 0) -- starts underground, rises
	p.Parent = wallFolder
	TweenService:Create(p, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = top }):Play()
	w.part = p
	table.insert(walls, w)
	Remotes.Effect:FireAllClients("wall", cx, cz, width / 2)
	task.delay(S.duration + S.durationPerRank * (rank - 1), function()
		if table.find(walls, w) then
			destroyWall(w)
		end
	end)
end

-- The Bomber's husk (D84): the empty shell left by the blast. A wall (blocks shots and
-- robots) with HP; the core climbs back in to be big again.
function Combat.removeHusk(e: World.Entity)
	local w = e.husk
	e.husk = nil
	e.reclaimT = 0
	if w and table.find(walls, w) then
		destroyWall(w)
	end
end

local function spawnHusk(e: World.Entity, x: number, z: number)
	Combat.removeHusk(e)
	local size = e.stats.hitRadius * 1.7
	nextWallId += 1
	local w: Wall = {
		id = nextWallId,
		cx = x,
		cz = z,
		ux = 1,
		uz = 0,
		halfU = size / 2,
		halfV = size / 2,
		hp = e.stats.maxHp * Config.Bomber.husk.hpFraction,
		part = nil,
	}
	local p = Instance.new("Part")
	p.Name = "BomberHusk"
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.Size = Vector3.one * size
	p.CFrame = CFrame.new(x, size * 0.3, z)
	p.Color = Color3.fromRGB(46, 42, 40)
	p.Material = Enum.Material.CorrodedMetal
	local glow = Instance.new("Part")
	glow.Name = "HuskCracks"
	glow.Shape = Enum.PartType.Cylinder
	glow.Anchored = true
	glow.CanCollide = false
	glow.CanQuery = false
	glow.CanTouch = false
	glow.Size = Vector3.new(0.3, size * 1.02, size * 1.02)
	glow.CFrame = p.CFrame * CFrame.Angles(0, 0, math.rad(90))
	glow.Color = Color3.fromRGB(255, 110, 30)
	glow.Material = Enum.Material.Neon
	glow.Parent = p
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 6
	smoke.Lifetime = NumberRange.new(1.5, 2.5)
	smoke.Speed = NumberRange.new(2, 4)
	smoke.Size = NumberSequence.new(1.5, 4)
	smoke.Color = ColorSequence.new(Color3.fromRGB(60, 56, 54))
	smoke.Transparency = NumberSequence.new(0.4, 1)
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.Parent = p
	-- A ring that fills in while the core reclaims it (tickBomber sizes it).
	local fill = Instance.new("Part")
	fill.Name = "ReclaimFill"
	fill.Shape = Enum.PartType.Cylinder
	fill.Anchored = true
	fill.CanCollide = false
	fill.CanQuery = false
	fill.CanTouch = false
	fill.Size = Vector3.new(0.12, 0.1, 0.1)
	fill.CFrame = CFrame.new(x, 0.1, z) * CFrame.Angles(0, 0, math.rad(90))
	fill.Color = Color3.fromRGB(90, 220, 255)
	fill.Material = Enum.Material.Neon
	fill.Transparency = 1
	fill.Parent = p
	-- Solid only after a moment, so the core it just popped out of isn't stuck inside.
	p.CanCollide = false
	task.delay(1, function()
		if p.Parent then
			p.CanCollide = true
		end
	end)
	p.Parent = wallFolder
	w.part = p
	table.insert(walls, w)
	e.husk = w
	e.reclaimT = 0
	task.delay(Config.Bomber.husk.life, function()
		if e.husk == w then
			Combat.removeHusk(e)
		elseif table.find(walls, w) then
			destroyWall(w)
		end
	end)
end

-- Splash and ricochet ---------------------------------------------------------

local function splash(p: Projectile, owner: World.Entity?, x: number, z: number, directId: number?, directCrate: number?)
	local r = p.splashRadius :: number
	local dmg = p.splashDamage :: number
	local edge = Config.Combat.SplashEdge
	Remotes.Effect:FireAllClients("explosion", x, z, r)
	for _, e in World.entities do
		if e.id ~= p.ownerId and e.id ~= directId and e.alive and e.root and not allies(owner, e) then
			local ex, ez = World.position(e)
			local dist = math.sqrt((ex - x) ^ 2 + (ez - z) ^ 2)
			local hr = World.hitRadius(e, Config)
			if dist <= r + hr then
				local falloff = Combat2D.splashFactor(math.max(0, dist - hr), r, edge)
				Combat.damage(e, dmg * falloff, owner, true, ex, ez)
				knock(e, x, z, (p.knockback or 0) * falloff)
			end
		end
	end
	if directId then
		local direct = World.entities[directId]
		if direct then
			knock(direct, x, z, p.knockback or 0)
		end
	end
	for _, c in Pickups.crates do
		if c.alive and c.id ~= directCrate and (c.x - x) ^ 2 + (c.z - z) ^ 2 <= (r + c.radius) ^ 2 then
			Pickups.damageCrate(c, dmg, owner)
		end
	end
end

local function ricochet(p: Projectile, owner: World.Entity, x: number, z: number, hitEntity: number?, hitCrate: number?)
	if not p.primary or p.bounced or p.splashRadius or (owner.build.stacks.mod_ricochet or 0) == 0 then
		return
	end
	local R = Config.Ricochet
	local tx, tz = nearestTarget(owner.id, x, z, R.range, true, hitEntity, hitCrate)
	if tx and tz then
		local angle = math.atan2(tz - z, tx - x)
		spawnProjectile(owner, x, z, angle, p.speed, R.range + 5, p.damage * R.damageFactor, p.radius, RICOCHET_BOUNCE_CODE, {
			bounced = true,
			skipEntity = hitEntity,
			skipCrate = hitCrate,
		})
	end
end

-- Firing ----------------------------------------------------------------------

-- Fire rate = shots per second. Combat2D.nextShot keeps an exact rhythm while
-- the trigger is held (tested in Balance.spec), and never double-fires on the
-- first shot (an earlier version did).
local function fireReady(e: World.Entity, key: string, rate: number, t: number): boolean
	local fire, nextAt = Combat2D.nextShot(e.nextFire[key] or 0, t, 1 / rate)
	e.nextFire[key] = nextAt
	return fire
end

-- Laser (D67): an instant straight beam that hits the first robot or crate,
-- and stops at cover.
local function fireBeam(e: World.Entity, ox: number, oz: number, angle: number, range: number, damage: number)
	local ex, ez = ox + math.cos(angle) * range, oz + math.sin(angle) * range
	local bestT = blockedAt(ox, oz, ex, ez)
	local best: Target? = nil
	for _, tg in targets(e.id, true) do
		local ht = Combat2D.segmentCircle(ox, oz, ex, ez, tg.x, tg.z, tg.r)
		if ht and (bestT == nil or ht < bestT) then
			bestT, best = ht, tg
		end
	end
	local f = bestT or 1
	local hx, hz = ox + (ex - ox) * f, oz + (ez - oz) * f
	Remotes.Effect:FireAllClients("laser", ox, oz, 0, hx, hz)
	if best and best.e then
		Combat.damage(best.e, damage, e, false, hx, hz)
	elseif best and best.crate then
		Pickups.damageCrate(best.crate, damage, e)
	end
end

-- Blaster, launcher and laser: barrels, Spreader Choke, kiting inaccuracy.
local function fireGun(e: World.Entity, kind: string, w)
	local s = e.stats
	local st = e.build.stacks
	local barrels = math.min(Config.Barrels.max, 1 + (st.stat_barrels or 0))
	local spread = (st.mod_spread or 0) > 0
	local B = Config.Barrels
	local factor = Stats.barrelFactor(Config, barrels) * (if spread then B.spreadDamage else 1)
	local range = w.range * s.rangeMult * (if spread then B.spreadRange else 1)
	local deviation = Stats.inaccuracy(Config, speedFraction(e))

	local x, z = World.position(e)
	local reach = (1.2 + Config.Robot.BarrelLength) * s.scale
	local ax, az = math.cos(e.aim), math.sin(e.aim)
	local px, pz = -az, ax -- perpendicular, for parallel barrels
	for i = 1, barrels do
		local offset = i - (barrels + 1) / 2
		local angle = e.aim + math.rad(rng:NextNumber(-deviation, deviation))
		local ox, oz = x + ax * reach, z + az * reach
		if spread then
			angle += math.rad(offset * B.spreadDegrees)
		else
			ox += px * offset * B.gap * s.scale
			oz += pz * offset * B.gap * s.scale
		end
		if kind == "beam" then
			fireBeam(e, ox, oz, angle, range, w.damage * s.damageMult * factor)
		elseif kind == "net" then
			local open = w.openRadius * (1 + (st.bmb_mesh or 0) * Config.Bomber.cards.meshWiden) -- Wide Mesh (D84)
			spawnProjectile(e, ox, oz, angle, w.speed * s.shotSpeedMult, range, 0, w.radius, w.code, { primary = true, net = true, openRadius = open, openPerStud = w.openPerStud })
		elseif w.pellets then
			-- Scrap Cannon (D84): a fan of pellets, stronger on marked robots.
			local n = Stats.pellets(Config, e.build)
			local bonus = w.markedBonus + (st.bmb_marked or 0) * Config.Bomber.cards.markedScrap
			for k = 1, n do
				local a = angle + math.rad((k - (n + 1) / 2) * w.spreadDegrees / math.max(1, n - 1) * 2)
				spawnProjectile(e, ox, oz, a, w.speed * s.shotSpeedMult, range, w.damage * s.damageMult, w.radius, w.code, { primary = true, markedBonus = bonus })
			end
		elseif kind == "rocket" then
			spawnProjectile(e, ox, oz, angle, w.launchSpeed * s.shotSpeedMult, range, w.damage * s.damageMult * factor, w.radius, w.code, {
				primary = true,
				accel = w.accel * s.shotSpeedMult,
				maxSpeed = w.speed * s.shotSpeedMult,
				splashDamage = w.splashDamage * s.damageMult * factor,
				splashRadius = w.splashRadius,
				knockback = w.knockback,
			})
		else
			local code = if (st.mod_ricochet or 0) > 0 then RICOCHET_CODE else w.code
			spawnProjectile(e, ox, oz, angle, w.speed * s.shotSpeedMult, range, w.damage * s.damageMult * factor, w.radius, code, { primary = true })
		end
	end
end

-- Brawler: every robot (and crate) in the front arc takes a hit and a shove.
-- Sledgehammer overhead smash (D71): clients swing it 180 degrees over the top (the
-- `counter` attribute), and the hit lands `windup` s later on an area of the
-- ground in front, in the aim direction. Range stacks reach further.
local function smash(e: World.Entity, w, damage: number, areaRadius: number, counter: string)
	if e.model then
		e.model:SetAttribute(counter, ((e.model:GetAttribute(counter) or 0) :: number) + 1)
	end
	local gen = e.generation
	task.delay(w.windup, function()
		if not e.alive or e.generation ~= gen or not e.root then
			return
		end
		local s = e.stats
		local x, z = World.position(e)
		local d = World.hitRadius(e, Config) + w.reach * s.scale * s.rangeMult
		local cx, cz = x + math.cos(e.aim) * d, z + math.sin(e.aim) * d
		local r = areaRadius * s.scale * s.rangeMult
		Remotes.Effect:FireAllClients("slam", cx, cz, r)
		for _, tg in targets(e.id, true) do
			if (tg.x - cx) ^ 2 + (tg.z - cz) ^ 2 <= (r + tg.r) ^ 2 then
				if tg.e then
					Combat.damage(tg.e, damage, e, true, tg.x, tg.z)
					knock(tg.e, cx, cz, w.knockback)
				elseif tg.crate then
					Pickups.damageCrate(tg.crate, damage, e)
				end
			end
		end
	end)
end

local function swingSaw(e: World.Entity, w)
	local s = e.stats
	local x, z = World.position(e)
	local reach = w.reach * s.scale * s.rangeMult + World.hitRadius(e, Config) -- Range stacks = longer reach (D71)
	local half = math.rad(w.arcDegrees / 2)
	for _, tg in targets(e.id, true) do
		if Combat2D.inArc(x, z, e.aim, half, reach, tg.x, tg.z, tg.r) then
			if tg.e then
				Combat.damage(tg.e, w.damage * s.damageMult, e, false, tg.x, tg.z)
				knock(tg.e, x, z, w.knockback)
			elseif tg.crate then
				Pickups.damageCrate(tg.crate, w.damage * s.damageMult, e)
			end
		end
	end
end

-- Scorcher: a cone of flame that cover and walls block, and sets robots burning.
local function flame(e: World.Entity, w, t: number)
	local s = e.stats
	local x, z = World.position(e)
	local range = w.range * s.rangeMult + World.hitRadius(e, Config)
	local half = math.rad((w.coneDegrees + s.coneBonus) / 2) -- Wider Flames (D71)
	for _, tg in targets(e.id, true) do
		if Combat2D.inArc(x, z, e.aim, half, range, tg.x, tg.z, tg.r) and not lineBlocked(x, z, tg.x, tg.z) then
			local dmg = w.damagePerTick * s.damageMult
			if tg.e then
				Combat.damage(tg.e, dmg, e, true, tg.x, tg.z)
				Condition.ignite(tg.e.condition, t + w.burnDuration, w.burnDps * s.damageMult, e.id)
			elseif tg.crate then
				Pickups.damageCrate(tg.crate, dmg, e)
			end
		end
	end
end

local function primaryOf(e: World.Entity)
	local c = Chassis.byId[e.chassisId] or Chassis.byId[Chassis.default]
	return (Upgrades.primaryFor(e.build.stacks) or Stats.form({ chassis = c, small = e.build.small }).primary) :: Chassis.Primary
end

local function firePrimary(e: World.Entity, t: number)
	if not e.firing then
		return
	end
	local prim = primaryOf(e)
	local w = W[prim.weapon]
	local isGun = prim.kind == "projectile" or prim.kind == "rocket" or prim.kind == "net"
	if isGun and e.liveProjectiles >= Config.Combat.ProjectileCapPerPlayer then
		return
	end
	if not fireReady(e, "primary", w.fireRate * e.stats.fireRateMult, t) then
		return
	end
	if isGun or prim.kind == "beam" then
		fireGun(e, prim.kind, w)
	elseif prim.kind == "melee" and w.smashRadius then
		smash(e, w, w.damage * e.stats.damageMult, w.smashRadius, "Smashes")
	elseif prim.kind == "melee" then
		swingSaw(e, w)
	elseif prim.kind == "cone" then
		flame(e, w, t)
	end
end

local function removeTrap(i: number)
	local tr = table.remove(traps, i)
	if tr and tr.part then
		tr.part:Destroy()
	end
end

-- Spike Traps (D88): MountFire picks the spot (behind the way you're moving); this
-- builds the trap there and retires your oldest past maxTraps.
local function placeTrap(e: World.Entity, def, x: number, z: number, damage: number, t: number)
	local mine = {}
	for i, tr in traps do
		if tr.ownerId == e.id then
			table.insert(mine, i)
		end
	end
	if #mine >= def.maxTraps then
		removeTrap(mine[1]) -- the oldest
	end
	-- A field of caltrops (D83, were hard to see): steel jacks with red tips, scattered
	-- over the trap's area, on a faint red ring that shows exactly where it bites.
	local p = Instance.new("Part")
	p.Name = "SpikeTrap"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.1, def.radius * 2, def.radius * 2)
	p.CFrame = CFrame.new(x, 0.06, z) * CFrame.Angles(0, 0, math.rad(90))
	p.Color = Color3.fromRGB(220, 50, 40)
	p.Material = Enum.Material.Neon
	p.Transparency = 0.75
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	local function piece(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material)
		local q = Instance.new("Part")
		q.Name = "Caltrop"
		q.Size = size
		q.CFrame = cf
		q.Color = color
		q.Material = material
		q.Anchored = true
		q.CanCollide = false
		q.CanQuery = false
		q.CanTouch = false
		q.CastShadow = false
		q.Parent = p
	end
	for k = 1, 4 do -- 4 jacks x 7 parts: cheap enough for many traps at once
		local a = k * 2 * math.pi / 4 + rng:NextNumber(-0.3, 0.3)
		local d = if k == 1 then 0 else def.radius * rng:NextNumber(0.35, 0.7)
		local centre = CFrame.new(x + math.cos(a) * d, 0.55, z + math.sin(a) * d) * CFrame.Angles(rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3))
		piece(Vector3.new(0.4, 0.4, 0.4), centre, Color3.fromRGB(70, 72, 78), Enum.Material.Metal)
		for _, axis in { CFrame.identity, CFrame.Angles(0, 0, math.rad(90)), CFrame.Angles(math.rad(90), 0, 0) } do
			piece(Vector3.new(0.18, 1.3, 0.18), centre * axis, Color3.fromRGB(150, 152, 158), Enum.Material.Metal)
			piece(Vector3.new(0.2, 0.2, 0.2), centre * axis * CFrame.new(0, 0.68, 0), Color3.fromRGB(230, 40, 30), Enum.Material.Neon)
		end
	end
	p.Parent = trapFolder
	table.insert(traps, { ownerId = e.id, x = x, z = z, armAt = t + def.armDelay, dieAt = t + def.life, damage = damage, part = p })
end

-- Armed traps hurt and pin the first enemy robot that drives over them.
local function tickTraps(t: number)
	local def = Config.Weapons.traps
	for i = #traps, 1, -1 do
		local tr = traps[i]
		if t >= tr.dieAt then
			removeTrap(i)
		elseif t >= tr.armAt then
			for _, e in World.entities do
				if e.id ~= tr.ownerId and e.root and isTargetable(e, t) and not allies(World.entities[tr.ownerId], e) then
					local ex, ez = World.position(e)
					local hr = World.hitRadius(e, Config)
					if (ex - tr.x) ^ 2 + (ez - tr.z) ^ 2 <= (def.radius + hr) ^ 2 then
						Combat.damage(e, tr.damage, World.entities[tr.ownerId], true, ex, ez)
						e.rootedUntil = t + def.root
						Remotes.Effect:FireAllClients("trap", tr.x, tr.z, def.radius)
						removeTrap(i)
						break
					end
				end
			end
		end
	end
end

-- Carries out what a mount did (D92): shots, hits (with any toss), lightning, traps.
local function runMountAction(e: World.Entity, def, a: MountFire.Action, list: { Target }, damage: number, t: number)
	if a.kind == "shot" then
		spawnProjectile(e, a.x :: number, a.z :: number, a.angle :: number, a.speed :: number, a.range :: number, damage, a.radius :: number, a.code :: number, a.opts)
	elseif a.kind == "hit" then
		local tg = list[a.target :: number]
		if tg.e then
			Combat.damage(tg.e, a.amount :: number, e, false, tg.x, tg.z)
			if a.knockback then
				local x, z = World.position(e)
				knock(tg.e, x, z, a.knockback)
			end
		elseif tg.crate then
			Pickups.damageCrate(tg.crate, a.amount :: number, e)
		end
	elseif a.kind == "beam" then
		-- The first bolt names its robot, so clients start it at the coil (D82).
		Remotes.Effect:FireAllClients("beam", a.x1, a.z1, 0, a.x2, a.z2, if a.first then e.id else nil)
	elseif a.kind == "trap" then
		placeTrap(e, def, a.x :: number, a.z :: number, damage, t)
	end
end

-- The robot as MountFire sees it, read fresh for every mount: an earlier mount's
-- kill can level you up (bigger, faster) within the same tick.
local function mountRobot(e: World.Entity): MountFire.Robot
	local s = e.stats
	local x, z = World.position(e)
	-- Mounts swivel within the hull's front arc, like the turret (D82), so they only
	-- shoot what they can visibly point at.
	local facing, vx, vz = e.aim, 0, 0
	if e.root then
		local look = e.root.CFrame.LookVector
		facing = math.atan2(look.Z, look.X)
		local v = e.root.AssemblyLinearVelocity
		vx, vz = v.X, v.Z
	end
	return {
		x = x,
		z = z,
		facing = facing,
		scale = s.scale,
		hitRadius = World.hitRadius(e, Config),
		speedFraction = speedFraction(e),
		vx = vx,
		vz = vz,
		hasRoot = e.root ~= nil,
		rangeMult = s.rangeMult,
		shotSpeedMult = s.shotSpeedMult,
		damageMult = s.damageMult,
		liveProjectiles = e.liveProjectiles,
	}
end

-- Mounts fire on their own timers. What each one does is MountFire's (D92); this
-- builds its snapshot of the robot and its targets and carries out the result.
local function fireMounts(e: World.Entity, t: number)
	if e.protectedUntil > t then
		return
	end
	local arcHalf = math.rad(Config.MountArcDegrees / 2)
	for _, weaponId in e.build.mounts do
		local s = e.stats
		local key = MOUNT_WEAPON[weaponId]
		local def = key and W[key]
		-- Passive mounts (Shield Generator) have no damage or fire rate (D72 crash fix).
		if not def or def.passive or t < (e.nextFire[weaponId] or 0) then
			continue
		end
		local rank = e.build.stacks[weaponId] or 1
		local damage, rate = Stats.weaponAtRank(def, rank)
		damage *= s.damageMult
		rate *= s.fireRateMult

		-- A fresh target list for each mount: an earlier mount's hits may have killed.
		local list = targets(e.id, true)
		local snapshot: { MountFire.Target } = table.create(#list)
		for i, tg in list do
			snapshot[i] = { x = tg.x, z = tg.z, r = tg.r, crate = tg.crate ~= nil }
		end
		local fired, actions = MountFire.fire(key, {
			robot = mountRobot(e),
			def = def,
			rank = rank,
			damage = damage,
			targets = snapshot,
			arcHalf = arcHalf,
			projectileCap = Config.Combat.ProjectileCapPerPlayer,
			rocketCount = Stats.rocketCount(rank),
			geom = Combat2D,
		})
		if fired then
			fireReady(e, weaponId, rate, t)
			for _, a in actions do
				runMountAction(e, def, a, list, damage, t)
			end
		end
	end
end

-- Projectile step -------------------------------------------------------------

type Body = { e: World.Entity, x: number, z: number, r: number }

local function boundaryT(x1: number, z1: number, x2: number, z2: number): number?
	local best: number? = nil
	local HALF = Arena.half()
	local function axis(a1: number, a2: number)
		if math.abs(a2) > HALF and a2 ~= a1 then
			local edge = if a2 > 0 then HALF else -HALF
			local t = (edge - a1) / (a2 - a1)
			if t >= 0 and t <= 1 and (best == nil or t < best) then
				best = t
			end
		end
	end
	axis(x1, x2)
	axis(z1, z2)
	return best
end

local function endProjectile(i: number, p: Projectile, notify: boolean)
	local last = #projectiles
	projectiles[i] = projectiles[last]
	projectiles[last] = nil
	local owner = World.entities[p.ownerId]
	if owner then
		owner.liveProjectiles = math.max(0, owner.liveProjectiles - 1)
	end
	if notify then
		table.insert(endQueue, p.id)
	end
end

local function stepProjectiles(dt: number, fields: { any })
	local bodies: { Body } = {}
	local t = now()
	for _, e in World.entities do
		if e.alive and e.root then
			local x, z = World.position(e)
			table.insert(bodies, { e = e, x = x, z = z, r = World.hitRadius(e, Config) })
		end
	end

	for i = #projectiles, 1, -1 do
		local p = projectiles[i]
		if p.accel > 0 then
			p.speed = Combat2D.rocketSpeed(p.speed, p.accel, p.maxSpeed, dt)
		end
		local slow = Combat2D.fieldFactor(p.x, p.z, p.ownerId, fields, Config.Skills.skl_nullfield.projectileSlow)
		local step = math.min(p.speed * dt * slow, p.remaining)
		local pa = p :: any
		if pa.openRadius then -- Bomber net opening up (D72)
			p.radius = math.min(pa.openRadius, p.radius + step * pa.openPerStud)
		end
		local x1, z1 = p.x, p.z
		local x2, z2 = x1 + p.dx * step, z1 + p.dz * step
		local owner = World.entities[p.ownerId]

		-- Solid things first: arena edge, cover, crates, Earth Walls.
		local bestT = boundaryT(x1, z1, x2, z2)
		local coverT = Arena.blockedAt(x1, z1, x2, z2, p.radius) -- the current map's cover (D81)
		if coverT and (bestT == nil or coverT < bestT) then
			bestT = coverT
		end
		local wallT = bestT
		local hitCrate: Pickups.Crate? = nil
		for _, c in Pickups.crates do
			if c.alive and c.id ~= p.skipCrate then
				local ht = Combat2D.segmentCircle(x1, z1, x2, z2, c.x, c.z, c.radius + p.radius)
				if ht and (bestT == nil or ht < bestT) then
					bestT, hitCrate = ht, c
				end
			end
		end
		local hitWall: Wall? = nil
		for _, w in walls do
			local ht = Combat2D.segmentOBB(x1, z1, x2, z2, w.cx, w.cz, w.ux, w.uz, w.halfU + p.radius, w.halfV + p.radius)
			if ht and (bestT == nil or ht < bestT) then
				bestT, hitCrate, hitWall = ht, nil, w
			end
		end

		-- Robots: a piercing railgun shot hits every robot before the first solid thing.
		local hitBody: Body? = nil
		for _, b in bodies do
			if b.e.id == p.ownerId or b.e.id == p.skipEntity or t < b.e.protectedUntil or not b.e.alive or allies(owner, b.e) then
				continue
			end
			if p.hitIds and p.hitIds[b.e.id] then
				continue
			end
			local ht = Combat2D.segmentCircle(x1, z1, x2, z2, b.x, b.z, b.r + p.radius)
			if not ht then
				continue
			end
			if p.pierce then
				if bestT == nil or ht < bestT then
					(p.hitIds :: { [number]: boolean })[b.e.id] = true
					Combat.damage(b.e, p.damage, owner, false, b.x, b.z)
				end
			elseif bestT == nil or ht < bestT then
				bestT, hitBody, hitCrate, hitWall = ht, b, nil, nil
			end
		end

		if bestT ~= nil then
			local hx, hz = x1 + (x2 - x1) * bestT, z1 + (z2 - z1) * bestT
			endProjectile(i, p, true)
			if hitBody and p.net then
				local shielded = t < hitBody.e.shieldUntil or hitBody.e.god
				if not shielded and not (Arena.isArena() and hitBody.e.player and owner and owner.player) then -- co-op arena: no nets on players
					Combat.applyNet(hitBody.e, hx, hz, owner)
				end
			elseif hitBody then
				-- Scrap Cannon pellets hit marked robots harder (D84).
				local bonus = if pa.markedBonus and t < hitBody.e.markedUntil then 1 + pa.markedBonus else 1
				Combat.damage(hitBody.e, p.damage * bonus, owner, false, hx, hz)
				if p.splashRadius then
					splash(p, owner, hx, hz, hitBody.e.id, nil)
				end
				if owner then
					ricochet(p, owner, hx, hz, hitBody.e.id, nil)
				end
			elseif hitCrate then
				if p.damage > 0 then -- Bomber nets just stop on crates
					Pickups.damageCrate(hitCrate, p.damage, owner)
				end
				if p.splashRadius then
					splash(p, owner, hx, hz, nil, hitCrate.id)
				end
				if owner then
					ricochet(p, owner, hx, hz, nil, hitCrate.id)
				end
			elseif hitWall then
				damageWall(hitWall, p.damage)
				if p.splashRadius then
					splash(p, owner, hx, hz, nil, nil)
				end
			elseif wallT ~= nil and p.splashRadius then
				splash(p, owner, hx, hz, nil, nil)
			end
		else
			p.x, p.z = x2, z2
			p.remaining -= step
			if p.remaining <= 1e-6 then
				endProjectile(i, p, false) -- clients stop at range on their own
				if p.splashRadius then
					splash(p, owner, x2, z2, nil, nil)
				end
			end
		end
	end
end

-- Replication -----------------------------------------------------------------

local function flushSpawns()
	local i = 1
	while i <= #spawnQueue do
		local n = math.min(SPAWN_PER_PACKET, #spawnQueue - i + 1)
		local buf = buffer.create(n * SPAWN_RECORD)
		for k = 0, n - 1 do
			local p = spawnQueue[i + k]
			local o = k * SPAWN_RECORD
			buffer.writeu32(buf, o, p.id)
			buffer.writeu8(buf, o + 4, p.code)
			buffer.writef32(buf, o + 5, p.x)
			buffer.writef32(buf, o + 9, p.z)
			buffer.writef32(buf, o + 13, p.angle)
			buffer.writef32(buf, o + 17, p.speed)
			buffer.writef32(buf, o + 21, p.remaining)
			buffer.writef32(buf, o + 25, p.accel)
			buffer.writef32(buf, o + 29, p.maxSpeed)
			buffer.writeu32(buf, o + 33, p.ownerId) -- so clients slow it in the same Null Fields
		end
		Remotes.ProjectilesSpawned:FireAllClients(buf)
		i += n
	end
	table.clear(spawnQueue)

	i = 1
	while i <= #endQueue do
		local n = math.min(END_PER_PACKET, #endQueue - i + 1)
		local buf = buffer.create(n * 4)
		for k = 0, n - 1 do
			buffer.writeu32(buf, k * 4, endQueue[i + k])
		end
		Remotes.ProjectilesEnded:FireAllClients(buf)
		i += n
	end
	table.clear(endQueue)
end

-- Skills ----------------------------------------------------------------------

local function dashCooldown(rank: number): number
	local d = Config.Skills.skl_dash
	return d.cooldown + d.cooldownPerRank * (rank - 1)
end

function Combat.consumeDash(e: World.Entity)
	local t = now()
	e.skillReadyAt = t + dashCooldown(e.build.skillRank)
	e.dashGrantAt = t
	World.hooks.markDirty(e)
end

local function useSkill(e: World.Entity)
	local t = now()
	local skill = e.build.skill
	if not e.alive or not skill or t < e.stunnedUntil then
		return -- flipped robots can't act (D72)
	end
	if skill == "skl_dash" then
		if t - e.dashGrantAt < Config.AntiCheat.DashWindow then
			return -- already charged when the movement check saw the dash
		end
		if t < e.skillReadyAt then
			return
		end
		Combat.consumeDash(e)
	elseif skill == "skl_shield" then
		if t < e.skillReadyAt then
			return
		end
		local S = Config.Skills.skl_shield
		local duration = S.duration + S.durationPerRank * (e.build.skillRank - 1)
		e.shieldUntil = t + duration
		e.skillReadyAt = t + S.cooldown
		local gen = e.generation
		if e.model then
			e.model:SetAttribute("Shield", true)
		end
		task.delay(duration, function()
			if e.generation == gen and e.model then
				e.model:SetAttribute("Shield", false)
			end
		end)
		World.hooks.markDirty(e)
	elseif skill == "skl_flipper" then
		if t < e.skillReadyAt then
			return
		end
		local S = Config.Skills.skl_flipper
		local rank = e.build.skillRank
		local flipTime = S.flipTime + S.flipTimePerRank * (rank - 1)
		local x, z = World.position(e)
		local reach = World.hitRadius(e, Config) + S.reach * e.stats.scale
		local half = math.rad(S.arcDegrees / 2)
		for _, tg in targets(e.id, false) do
			local v = tg.e
			-- Bosses are far too heavy to flip (D78).
			if v and not v.isBoss and t >= v.stunnedUntil and Combat2D.inArc(x, z, e.aim, half, reach, tg.x, tg.z, tg.r) then
				v.rootedUntil = math.max(v.rootedUntil, t + flipTime)
				v.stunnedUntil = math.max(v.stunnedUntil, t + flipTime)
				knock(v, x, z, S.knockback, flipTime)
				if not v.player then
					flipAnchored(v, x, z, flipTime) -- players flip on their own client
				end
				local gen = v.generation
				if v.model then
					v.model:SetAttribute("Flipped", true)
				end
				task.delay(flipTime, function()
					if v.generation == gen and v.model and now() >= v.stunnedUntil then
						v.model:SetAttribute("Flipped", false)
					end
				end)
			end
		end
		if e.model then
			e.model:SetAttribute("Flips", ((e.model:GetAttribute("Flips") or 0) :: number) + 1)
		end
		Remotes.Effect:FireAllClients("slam", x + math.cos(e.aim) * reach * 0.6, z + math.sin(e.aim) * reach * 0.6, reach * 0.5)
		e.skillReadyAt = t + S.cooldown + S.cooldownPerRank * (rank - 1)
		World.hooks.markDirty(e)
	elseif skill == "skl_bomb" then
		if t < e.skillReadyAt then
			return
		end
		local B = Config.Bomber
		if e.build.small then
			-- The core's Space is Boost (D84): a short dash, like skl_dash.
			if t - e.dashGrantAt < Config.AntiCheat.DashWindow then
				return
			end
			e.skillReadyAt = t + B.boost.cooldown
			e.dashGrantAt = t
			World.hooks.markDirty(e)
			return
		end
		local S = Config.Skills.skl_bomb
		local rank = e.build.skillRank
		local x, z = World.position(e)
		-- The blast fills the ring drawn around the Bomber (D80), Shaped Charge included.
		local c = Chassis.byId[e.chassisId] or Chassis.byId[Chassis.default]
		local radius = Stats.attackRange(Config, Upgrades.primaryFor(e.build.stacks) or c.primary, e.stats, e.build)
		-- The fuse (D83): the Bomber glows and beeps first, so robots nearby can run. It
		-- blasts wherever it is when the fuse runs out; dead Bombers don't.
		local fuse = if (e.build.stacks.bmb_hotfuse or 0) > 0 then B.cards.hotFuse else S.fuse
		e.skillReadyAt = t + fuse + S.cooldown
		Remotes.Effect:FireAllClients("fuse", x, z, radius, fuse, 0, e.id)
		local gen = e.generation
		task.delay(fuse, function()
			if not e.alive or e.generation ~= gen or e.build.small then
				return
			end
			local bx, bz = World.position(e)
			local tNow = now()
			-- Damage from the Pressure stored (D84), read when it goes off.
			local damage = Stats.bombDamage(Config, e.pressure, rank, e.stats.damageMult)
			Remotes.Effect:FireAllClients("detonation", bx, bz, radius)
			for _, tg in targets(e.id, true) do
				local dist = math.sqrt((tg.x - bx) ^ 2 + (tg.z - bz) ^ 2)
				if dist <= radius + tg.r then
					local falloff = Combat2D.splashFactor(math.max(0, dist - tg.r), radius, S.edge)
					local v = tg.e
					if v then
						local hit = damage * falloff
						local marked = tNow < v.markedUntil
						if v.isBoss then
							hit *= B.blast.bossFactor -- bosses resist it and are never knocked down
						elseif marked then
							hit *= 1 + B.blast.markedBonus
						end
						Combat.damage(v, hit, e, true, tg.x, tg.z)
						knock(v, bx, bz, S.knockback * falloff)
						if marked and not v.isBoss and v.alive then
							-- Knocked down: can't drive or attack for a moment.
							v.stunnedUntil = math.max(v.stunnedUntil, tNow + B.blast.knockdown)
							v.rootedUntil = math.max(v.rootedUntil, tNow + B.blast.knockdown)
							local vgen = v.generation
							if v.model then
								v.model:SetAttribute("Flipped", true)
							end
							task.delay(B.blast.knockdown, function()
								if v.generation == vgen and v.model and now() >= v.stunnedUntil then
									v.model:SetAttribute("Flipped", false)
								end
							end)
						end
					elseif tg.crate then
						Pickups.damageCrate(tg.crate, damage * falloff, e)
					end
				end
			end
			-- The shell is spent: it stays behind as the husk, and the core pops out.
			setPressure(e, 0)
			spawnHusk(e, bx, bz)
			Condition.set(e.condition, { hp = math.min(e.condition.hp, e.stats.maxHp * B.hpAfter), armor = 0 })
			syncHp(e)
			syncArmor(e)
			World.hooks.setSmall(e, true)
			e.skillReadyAt = now() + B.boost.cooldown * 0.5
			-- The core pops out of the smoke, away from the husk.
			knock(e, bx + math.cos(e.aim), bz + math.sin(e.aim), 8)
			World.hooks.markDirty(e)
		end)
	elseif skill == "skl_nullfield" then
		if t < e.skillReadyAt then
			return
		end
		local S = Config.Skills.skl_nullfield
		local rank = e.build.skillRank
		e.fieldUntil = t + S.duration + S.durationPerRank * (rank - 1)
		e.fieldRadius = S.radius + S.radiusPerRank * (rank - 1)
		e.skillReadyAt = t + S.cooldown
		if e.model then
			e.model:SetAttribute("Field", e.fieldRadius)
		end
		World.hooks.markDirty(e)
	elseif skill == "skl_earthwall" then
		if t < e.skillReadyAt then
			return
		end
		e.skillReadyAt = t + Config.Skills.skl_earthwall.cooldown
		spawnWall(e, e.build.skillRank)
		World.hooks.markDirty(e)
	end
end

-- Armor regen, Regen Pod healing, Armor Pod expiry and burn. Health itself
-- never regenerates (D33), except the small Bomber (D80).
-- The core becomes the shell again (D84): reclaimed husk or healed to rebuildAt.
local function rebuildShell(e: World.Entity, reclaimed: boolean)
	local B = Config.Bomber
	Combat.removeHusk(e)
	World.hooks.setSmall(e, false)
	if reclaimed then
		Condition.set(e.condition, { hp = math.max(e.condition.hp, e.stats.maxHp * B.rebuildAt), armor = e.stats.maxArmor })
		syncHp(e)
		syncArmor(e)
		local x, z = World.position(e)
		Remotes.Effect:FireAllClients("crate", x, z, 4) -- panels clanking back on
	end
	e.skillReadyAt = math.max(e.skillReadyAt, now() + Config.Skills.skl_bomb.cooldown)
	World.hooks.markDirty(e)
end

local function tickBomber(e: World.Entity, t: number, dt: number)
	local B = Config.Bomber
	if isShell(e) and e.pressure > 0 and t - e.pressureAt > B.pressure.drainDelay then
		local valve = e.build.stacks.bmb_valve or 0
		local before = math.floor(e.pressure)
		e.pressure = math.max(0, e.pressure - B.pressure.drain * (1 - B.cards.valveDrain * math.min(1, valve)) * dt)
		if math.floor(e.pressure) ~= before and e.model then
			e.model:SetAttribute("Pressure", math.floor(e.pressure))
		end
	end
	if not e.build.small then
		return
	end
	local hp = e.condition.hp
	if hp > 0 and hp < e.stats.maxHp then
		-- The core heals itself, the one exception to D33 (D80).
		Condition.heal(e.condition, e.stats.maxHp * B.smallRegenPerSecond * dt, e.stats.maxHp)
		syncHp(e)
	end
	if e.condition.hp >= e.stats.maxHp * B.rebuildAt then
		rebuildShell(e, false) -- healed: the bombs are back (D70)
		return
	end
	-- Reclaim: park on the husk, unhurt, for reclaim.hold s.
	local w = e.husk
	if w and not table.find(walls, w) then
		e.husk, w = nil, nil
	end
	if not w then
		return
	end
	local x, z = World.position(e)
	local close = (x - w.cx) ^ 2 + (z - w.cz) ^ 2 <= (w.halfU + World.hitRadius(e, Config) + B.reclaim.reach) ^ 2
	local before = e.reclaimT
	e.reclaimT = if close and t - e.condition.lastHitAt > 0.2 then e.reclaimT + dt else 0
	local fill = w.part and w.part:FindFirstChild("ReclaimFill") :: Part?
	local step = math.floor(e.reclaimT / B.reclaim.hold * 10) / 10
	if fill and step ~= math.floor(before / B.reclaim.hold * 10) / 10 then
		local r = (w.halfU + 2) * 2 * step
		fill.Size = Vector3.new(0.12, math.max(0.1, r), math.max(0.1, r))
		fill.Transparency = if step > 0 then 0.35 else 1
	end
	if e.reclaimT >= B.reclaim.hold then
		rebuildShell(e, true)
	end
end

local function tickSustain(e: World.Entity, t: number, dt: number)
	if e.chassisId == "bomber" then
		tickBomber(e, t, dt)
	end
	local r = Condition.tick(e.condition, t, dt, limitsOf(e), Config)
	if r.guardChanged then
		Combat.syncGuard(e)
	end
	if r.armorChanged then
		syncArmor(e)
	end
	if r.bonusExpired then
		World.hooks.refreshStats(e) -- Fortify ran out: clamps HP down to the normal max
	end
	if r.hpChanged or r.bonusExpired then
		syncHp(e)
	end
	-- Clients set burning robots alight (fire, smoke and a glow) from this attribute (D88).
	if e.model and e.model:GetAttribute("Burning") ~= r.burning then
		e.model:SetAttribute("Burning", r.burning)
	end
	if r.burnDamage > 0 then
		local x, z = World.position(e)
		Combat.damage(e, r.burnDamage, World.entities[r.burnSourceId or -1], true, x, z)
	end
end

-- Boot ------------------------------------------------------------------------

-- A map swap (D81): every shot, Earth Wall and Spike Trap on the old map goes.
function Combat.clearAll()
	for i = #projectiles, 1, -1 do
		endProjectile(i, projectiles[i], true)
	end
	for i = #walls, 1, -1 do
		destroyWall(walls[i])
	end
	for _, tr in traps do
		if tr.part then
			tr.part:Destroy()
		end
	end
	table.clear(traps)
end

function Combat.init()
	wallFolder = Instance.new("Folder")
	wallFolder.Name = "EarthWalls"
	wallFolder.Parent = Workspace
	trapFolder = Instance.new("Folder")
	trapFolder.Name = "SpikeTraps"
	trapFolder.Parent = Workspace

	Remotes.AimUpdate.OnServerEvent:Connect(function(player: Player, angle: any, firing: any)
		if not Guard.allow(player, "AimUpdate") then
			return
		end
		local e = World.byPlayer[player]
		if not e or not Guard.isFiniteNumber(angle) then
			return
		end
		e.aim = angle
		if type(firing) == "boolean" then
			setFiring(e, firing)
		end
	end)

	Remotes.SetFiring.OnServerEvent:Connect(function(player: Player, firing: any)
		if not Guard.allow(player, "SetFiring") or type(firing) ~= "boolean" then
			return
		end
		local e = World.byPlayer[player]
		if e then
			setFiring(e, firing)
		end
	end)

	Remotes.UseSkill.OnServerEvent:Connect(function(player: Player)
		if not Guard.allow(player, "UseSkill") then
			return
		end
		local e = World.byPlayer[player]
		if e then
			useSkill(e)
		end
	end)

	local aimAcc = 0
	local fields: { any } = {}
	local reported: { [string]: boolean } = {}
	RunService.Heartbeat:Connect(function(dt)
		local t = now()
		-- Active Null Fields (D68); expired ones switch off here.
		table.clear(fields)
		for _, e in World.entities do
			if e.fieldUntil > 0 then
				if t < e.fieldUntil and e.alive and e.root then
					local x, z = World.position(e)
					table.insert(fields, { x = x, z = z, r = e.fieldRadius, owner = e.id })
				else
					e.fieldUntil = 0
					if e.model then
						e.model:SetAttribute("Field", 0)
					end
				end
			end
		end
		for _, e in World.entities do
			if e.alive and e.root then
				local x, z = World.position(e)
				if e.netUntil > 0 and t >= e.netUntil then
					e.netUntil = 0
					if e.model then
						e.model:SetAttribute("Netted", false)
					end
				end
				if e.markedUntil > 0 and t >= e.markedUntil then
					e.markedUntil = 0
					if e.model then
						e.model:SetAttribute("Marked", false)
					end
				end
				local N = Config.Weapons.netgun
				local netted = if e.netUntil > 0 then (if e.isBoss then N.bossSlow else N.netSlow) else 1
				local slow = if t < e.rootedUntil then 0 else math.min(netted, Combat2D.fieldFactor(x, z, e.id, fields, Config.Skills.skl_nullfield.robotSlow))
				-- Lava (Q3): burns at lava.dps and slows while inside, then a short burn after.
				local L = Config.Maps.lava
				if not e.isBoss and MapQuery.inLava(Arena.map(), x, z) then
					slow *= L.slow
					e.inLava = true
					Condition.ignite(e.condition, t + 0.3, L.dps, nil)
				elseif e.inLava then
					e.inLava = false
					Condition.ignite(e.condition, t + L.burnDuration, L.burnDps, e.condition.burnSourceId)
				end
				if slow ~= e.slowFactor then
					e.slowFactor = slow
					Combat.applyWalkSpeed(e)
				end
			end
		end
		for _, e in World.entities do
			if not e.alive or not e.root then
				continue
			end
			if e.player and t >= e.stunnedUntil then -- dummies never shoot back; flipped robots can't
				-- A weapon bug must not stop healing, regen and form changes (D72),
				-- so errors are caught and reported once each.
				local ok, err = pcall(firePrimary, e, t)
				if ok then
					ok, err = pcall(fireMounts, e, t)
				end
				if not ok and not reported[tostring(err)] then
					reported[tostring(err)] = true
					warn("[Combat] weapon error for", e.name, err)
				end
			end
			if e.alive then
				tickSustain(e, t, dt)
			end
		end
		stepProjectiles(dt, fields)
		tickTraps(t)
		flushSpawns()

		aimAcc += dt
		if aimAcc >= 0.1 then
			aimAcc = 0
			local aims = {}
			for _, e in World.entities do
				if e.alive and e.player then
					table.insert(aims, e.player.UserId)
					table.insert(aims, math.floor(e.aim * 1000) / 1000)
				end
			end
			if #aims > 0 then
				Remotes.Aims:FireAllClients(aims)
			end
		end
	end)
end

return Combat
