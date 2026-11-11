-- Bosses, the map flow and hazards (Phase 4b D39/D74, maps D79/D81).
-- Every 7-10 min of grassland time with at least 2 players, a 20 s warning, then
-- everyone is moved to the boss's own arena (a fade and a map swap). There it hunts
-- the nearest robot; PvP is off. Everyone who damaged it gets the same 100 coins
-- and 600 XP when it falls, more scatters on the ground, and 6 s later the
-- overworld comes back as the boss's biome with its hazard built in, for 6 min.
-- If nobody beats it in 4 min it leaves and everyone goes home. The phase logic
-- lives in shared/MapFlow.luau, timings in shared/HazardTiming.luau (both tested).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Combat2D = require(Shared.Combat2D)
local HazardTiming = require(Shared.HazardTiming)
local MapFlow = require(Shared.MapFlow)
local MapQuery = require(Shared.MapQuery)
local MapLayouts = require(Shared.MapLayouts)
local World = require(script.Parent.World)
local Arena = require(script.Parent.Arena)
local Pickups = require(script.Parent.Pickups)
local Combat = require(script.Parent.Combat)
local Match = require(script.Parent.Match)
local Profiles = require(script.Parent.Profiles)

local B = Config.Bosses
local H = Config.Hazards
local rng = Random.new()

local Bosses = {}

local function now(): number
	return Workspace:GetServerTimeNow()
end

local function announce(text: string)
	Remotes.Announce:FireAllClients(text)
	Remotes.Notice:FireAllClients(text)
end

-- Boss -----------------------------------------------------------------------

type Active = {
	e: World.Entity,
	key: string,
	def: any,
	spawnedAt: number,
	nextAttackAt: number,
	busyUntil: number, -- mid-attack: it stops walking
	chargeDir: Vector3?,
	chargeHit: { [number]: boolean },
	dmg: number, -- damage multiplier from the players' levels (D82)
}
local active: Active? = nil
local flow: MapFlow.State = MapFlow.new(Config, 0, 0.5) -- replaced in init

local function aliveRobots(): { World.Entity }
	local out = {}
	for _, e in World.entities do
		if e.alive and e.root and not e.isBoss and now() >= e.protectedUntil then
			table.insert(out, e)
		end
	end
	return out
end

local function nearest(x: number, z: number, range: number): World.Entity?
	local best, bestD = nil, range
	for _, e in aliveRobots() do
		local ex, ez = World.position(e)
		local d = math.sqrt((ex - x) ^ 2 + (ez - z) ^ 2)
		if d < bestD then
			best, bestD = e, d
		end
	end
	return best
end

local function face(a: Active, x: number, z: number, dir: Vector3)
	local root = a.e.root
	if not root or dir.Magnitude < 1e-3 then
		return
	end
	local flat = Vector3.new(dir.X, 0, dir.Z).Unit
	local pos = Vector3.new(x, root.Position.Y, z)
	root.CFrame = CFrame.lookAt(pos, pos + flat)
	a.e.aim = math.atan2(flat.Z, flat.X)
end

local function hitArea(a: Active, cx: number, cz: number, radius: number, damage: number, knockback: number)
	for _, e in aliveRobots() do
		local ex, ez = World.position(e)
		local r = World.hitRadius(e, Config)
		if (ex - cx) ^ 2 + (ez - cz) ^ 2 <= (radius + r) ^ 2 then
			Combat.damage(e, damage * a.dmg, a.e, true, ex, ez)
			Combat.knock(e, cx, cz, knockback)
		end
	end
end

-- Inferno Giant: a cone of fire in front for `duration` s, burning what it touches.
local function flameAttack(a: Active, atk)
	local e = a.e
	local gen = e.generation
	if e.model then
		e.model:SetAttribute("Firing", true)
	end
	local ticks = 5
	for i = 1, ticks do
		task.delay(atk.duration * (i - 1) / ticks, function()
			if not e.alive or e.generation ~= gen then
				return
			end
			local x, z = World.position(e)
			local half = math.rad(atk.coneDegrees / 2)
			local reach = atk.range + World.hitRadius(e, Config)
			for _, v in aliveRobots() do
				local vx, vz = World.position(v)
				if Combat2D.inArc(x, z, e.aim, half, reach, vx, vz, World.hitRadius(v, Config)) then
					Combat.damage(v, atk.damage * a.dmg / ticks, e, true, vx, vz)
					v.burnUntil = now() + atk.burnDuration
					v.burnDps = atk.burnDps * a.dmg
					v.burnSourceId = e.id
				end
			end
			for k = 1, 3 do
				local d = reach * k / 3
				Remotes.Effect:FireAllClients("fire", x + math.cos(e.aim) * d, z + math.sin(e.aim) * d, 3 + k)
			end
		end)
	end
	task.delay(atk.duration, function()
		if e.model and e.generation == gen then
			e.model:SetAttribute("Firing", false)
		end
	end)
	a.busyUntil = now() + atk.duration
end

-- Forge Titan: a red warning circle in front, then the hammer smashes down on it.
local function smashAttack(a: Active, atk)
	local e = a.e
	local gen = e.generation
	local x, z = World.position(e)
	local d = World.hitRadius(e, Config) + atk.reach
	local cx, cz = x + math.cos(e.aim) * d, z + math.sin(e.aim) * d
	Remotes.Effect:FireAllClients("warn", cx, cz, atk.radius)
	a.busyUntil = now() + atk.windup + 0.4
	-- The client swing takes 0.2 s from the raised pose, so start it to land on time.
	task.delay(math.max(0, atk.windup - 0.2), function()
		if e.model and e.generation == gen then
			e.model:SetAttribute("Smashes", ((e.model:GetAttribute("Smashes") or 0) :: number) + 1)
		end
	end)
	task.delay(atk.windup, function()
		if not e.alive or e.generation ~= gen then
			return
		end
		Remotes.Effect:FireAllClients("slam", cx, cz, atk.radius)
		hitArea(a, cx, cz, atk.radius, atk.damage, atk.knockback)
	end)
end

-- Grinder: charges in a straight line at its target, saws spinning.
local function chargeAttack(a: Active, atk, target: World.Entity)
	local x, z = World.position(a.e)
	local tx, tz = World.position(target)
	a.chargeDir = Vector3.new(tx - x, 0, tz - z)
	a.chargeHit = {}
	a.busyUntil = now() + atk.duration
	if a.e.model then
		a.e.model:SetAttribute("Firing", true)
	end
end

local function removeBoss(a: Active)
	local e = a.e
	e.alive = false
	e.generation += 1
	if e.model then
		e.model:Destroy()
	end
	e.model, e.root = nil, nil
	World.entities[e.id] = nil
	if active == a then
		active = nil
	end
end

-- The boss walks out of its arena's gate (called after the swap to the arena).
local function spawnArenaBoss(key: string)
	local def = B.list[key]
	local gate = Arena.map().gate
	local x, z = 0, 0
	if gate then
		local d = math.sqrt(gate.x ^ 2 + gate.z ^ 2)
		x, z = gate.x * (1 - 18 / d), gate.z * (1 - 18 / d) -- just inside the doorway
	end
	-- HP and damage scale with the levels of the players in the fight (D82).
	local levels = {}
	for _, p in World.entities do
		if p.player then
			table.insert(levels, p.level)
		end
	end
	local hp = HazardTiming.bossHp(B, levels)
	local e = Match.spawnBoss(def, x, z, hp)
	active = {
		e = e,
		key = key,
		def = def,
		spawnedAt = now(),
		nextAttackAt = now() + 3,
		busyUntil = 0,
		chargeDir = nil,
		chargeHit = {},
		dmg = HazardTiming.bossDamageMult(B, levels),
	}
	announce(`{def.name} is here! Everyone who hits it shares the reward.`)
end

-- Debug (/boss key): skip the timer and the warning; the swap starts next frame.
function Bosses.summon(key: string): boolean
	if not B.list[key] or (flow.phase ~= "grassland" and flow.phase ~= "warning") then
		return false
	end
	flow = { phase = "warning", map = "grassland", boss = key, lastBoss = flow.lastBoss, endsAt = now(), nextBossAt = math.huge }
	return true
end

-- The boss fell at (x, z) (called from Match.onKill through World.hooks.bossDied).
function Bosses.died(e: World.Entity, x: number, z: number)
	local a = active
	if not a or a.e ~= e then
		return
	end
	local paid = 0
	for id in e.hitBy :: { [number]: boolean } do
		local p = World.entities[id]
		if p and p.player then
			Profiles.addCoins(p.player, B.reward.coins)
			if p.alive then
				World.hooks.addXp(p, B.reward.xp, "boss")
			else
				task.spawn(function() -- respawning in the arena: pay the XP once it's back
					for _ = 1, 30 do
						task.wait(0.5)
						if p.alive then
							World.hooks.addXp(p, B.reward.xp, "boss")
							return
						end
					end
				end)
			end
			paid += 1
		end
	end
	for _ = 1, B.reward.scatterCoins do
		local ang, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(4, 16)
		Pickups.spawnCoin(x + math.cos(ang) * r, z + math.sin(ang) * r)
	end
	Pickups.spill(x, z, B.reward.scatterOrbs, B.reward.scatterOrbValue)
	announce(`{a.def.name} destroyed! {paid} player{if paid == 1 then "" else "s"} earned {B.reward.coins} coins and {B.reward.xp} XP.`)
	active = nil
	Bosses.stopHazard()
	flow = MapFlow.defeated(Config, flow, now())
	Bosses.publish()
end

-- Debug (/killboss): beats the boss as if `by` landed the last hit.
function Bosses.killActive(by: World.Entity?)
	local a = active
	if a then
		if by then
			(a.e.hitBy :: { [number]: boolean })[by.id] = true
		end
		a.e.hp, a.e.armor, a.e.tempArmor = 1, 0, 0
		Combat.damage(a.e, 10, nil, true, 0, 0)
	end
end

-- In its arena a boss walks through destructible cover and smashes it (D79, Q5).
local function smashCover(e: World.Entity)
	local map = Arena.map()
	if map.kind ~= "arena" then
		return
	end
	local x, z = World.position(e)
	local r = World.hitRadius(e, Config)
	local function debris(kind: string, cx: number?, cz: number?, size: number)
		if cx and cz then
			Remotes.Effect:FireAllClients(if kind == "stone" or kind == "obsidian" then "wall" else "crate", cx, cz, size)
		end
	end
	for _, b in map.boxes do
		if b.d and not Arena.broken[b.id] and MapQuery.touchesBox(b, x, z, r) then
			local cx, cz = Arena.breakPiece("box", b.id)
			debris(b.kind, cx, cz, math.max(b.hu, b.hv))
		end
	end
	for _, c in map.circles do
		if c.d and not Arena.broken[MapQuery.CIRCLE_KEY + c.id] and (c.x - x) ^ 2 + (c.z - z) ^ 2 <= (c.r + r) ^ 2 then
			local cx, cz = Arena.breakPiece("circle", c.id)
			debris(c.kind, cx, cz, c.r)
		end
	end
end

local function tickBoss(dt: number)
	local a = active
	if not a then
		return
	end
	local e = a.e
	if not e.alive or not e.root then
		active = nil
		return
	end
	local t = now()
	local atk = a.def.attack
	smashCover(e)
	local x, z = World.position(e)

	-- Charging (Grinder): straight line, hurting each robot once.
	if a.chargeDir and t < a.busyUntil then
		local dir = a.chargeDir.Unit
		local step = a.def.speed * atk.speedMult * e.slowFactor * dt
		local HALF = Arena.half()
		local nx = math.clamp(x + dir.X * step, -HALF + 12, HALF - 12)
		local nz = math.clamp(z + dir.Z * step, -HALF + 12, HALF - 12)
		face(a, nx, nz, dir)
		local reach = World.hitRadius(e, Config)
		for _, v in aliveRobots() do
			if not a.chargeHit[v.id] then
				local vx, vz = World.position(v)
				if (vx - nx) ^ 2 + (vz - nz) ^ 2 <= (reach + World.hitRadius(v, Config)) ^ 2 then
					a.chargeHit[v.id] = true
					Combat.damage(v, atk.damage * a.dmg, e, false, vx, vz)
					Combat.knock(v, nx, nz, atk.knockback)
				end
			end
		end
		return
	elseif a.chargeDir then
		a.chargeDir = nil
		if e.model then
			e.model:SetAttribute("Firing", false)
		end
	end
	if t < a.busyUntil or t < e.stunnedUntil then
		return -- mid-attack, or flipped
	end

	-- Walk toward the nearest robot (or the centre) and attack when close enough.
	local target = nearest(x, z, B.chaseRange)
	local tx, tz = 0, 0
	if target then
		tx, tz = World.position(target)
	end
	local to = Vector3.new(tx - x, 0, tz - z)
	local dist = to.Magnitude
	local attackRange = if atk.kind == "flame" then atk.range * 0.8 elseif atk.kind == "smash" then atk.reach + atk.radius else 60
	if dist > 1 then
		face(a, x, z, to)
		if not target or dist > attackRange then
			-- Nets and traps slow or stop bosses too (slowFactor).
			local step = math.min(a.def.speed * e.slowFactor * dt, dist)
			face(a, x + to.Unit.X * step, z + to.Unit.Z * step, to)
		end
	end
	if target and dist <= attackRange + World.hitRadius(e, Config) and t >= a.nextAttackAt then
		a.nextAttackAt = t + atk.every
		if atk.kind == "flame" then
			flameAttack(a, atk)
		elseif atk.kind == "smash" then
			smashAttack(a, atk)
		else
			chargeAttack(a, atk, target)
		end
	end
end

-- Hazards ----------------------------------------------------------------------

type Spot = { x: number, z: number, offset: number, parts: { [string]: BasePart }, last: string, hitAt: { [number]: number }, track: { number }?, warnT: number? }
local hazard: { kind: string, startedAt: number, spots: { Spot }, folder: Folder }? = nil

local function part(folder: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	if shape then
		p.Shape = shape
	end
	p.Parent = folder
	return p
end

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- a cylinder standing up

function Bosses.stopHazard()
	if hazard then
		hazard.folder:Destroy()
		hazard = nil
	end
end

function Bosses.startHazard(kind: string)
	Bosses.stopHazard()
	local def = H[kind]
	if not def then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "Hazard"
	local spots: { Spot } = {}
	local map = Arena.map()
	if kind == "vents" then
		for i, p in map.vents do
			local s: Spot = { x = p.x, z = p.z, offset = i * 0.75, parts = {}, last = "", hitAt = {} }
			s.parts.grate = part(folder, "Vent", Vector3.new(0.4, def.radius * 2, def.radius * 2), CFrame.new(s.x, 0.2, s.z) * UPRIGHT, Color3.fromRGB(50, 50, 55), Enum.Material.DiamondPlate, Enum.PartType.Cylinder)
			s.parts.fire = part(folder, "VentFire", Vector3.new(10, def.radius * 1.6, def.radius * 1.6), CFrame.new(s.x, 5, s.z) * UPRIGHT, Color3.fromRGB(255, 120, 30), Enum.Material.Neon, Enum.PartType.Cylinder)
			s.parts.fire.Transparency = 1
			-- D82: a red warning disc on the ground (the full hurt radius) before the fire.
			s.parts.warn = part(folder, "VentWarning", Vector3.new(0.15, def.radius * 2 + 1, def.radius * 2 + 1), CFrame.new(s.x, 0.45, s.z) * UPRIGHT, Color3.fromRGB(255, 40, 30), Enum.Material.Neon, Enum.PartType.Cylinder)
			s.parts.warn.Transparency = 1
			local flames = Instance.new("ParticleEmitter")
			flames.Texture = "rbxasset://textures/particles/fire_main.dds"
			flames.EmissionDirection = Enum.NormalId.Right -- up, on a standing cylinder
			flames.Rate = 70
			flames.Lifetime = NumberRange.new(0.5, 0.8)
			flames.Speed = NumberRange.new(14, 22)
			flames.SpreadAngle = Vector2.new(12, 12)
			flames.Size = NumberSequence.new(3, 1)
			flames.LightEmission = 1
			flames.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 70, 20))
			flames.Enabled = false
			flames.Parent = s.parts.grate
			table.insert(spots, s)
		end
	elseif kind == "hammers" then
		for i, p in map.hammers do
			local s: Spot = { x = p.x, z = p.z, offset = i * 0.7, parts = {}, last = "", hitAt = {} }
			s.parts.mark = part(folder, "HammerMark", Vector3.new(0.2, def.radius * 2, def.radius * 2), CFrame.new(s.x, 0.15, s.z) * UPRIGHT, Color3.fromRGB(200, 60, 50), Enum.Material.Neon, Enum.PartType.Cylinder)
			s.parts.mark.Transparency = 0.7
			s.parts.head = part(folder, "HammerHead", Vector3.new(def.radius * 1.4, 4, def.radius * 1.4), CFrame.new(s.x, 18, s.z), Color3.fromRGB(70, 74, 82), Enum.Material.Metal)
			table.insert(spots, s)
		end
	elseif kind == "saws" then
		for k, run in map.saws do
			local x1, z1, x2, z2 = run.x1, run.z1, run.x2, run.z2
			local s: Spot = { x = x1, z = z1, offset = k * 2, parts = {}, last = "", hitAt = {}, track = { x1, z1, x2, z2 } }
			local len = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
			part(folder, "SawTrack", Vector3.new(len, 0.15, 1.2), CFrame.lookAt(Vector3.new((x1 + x2) / 2, 0.08, (z1 + z2) / 2), Vector3.new(x2, 0.08, z2)) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
			s.parts.saw = part(folder, "FloorSaw", Vector3.new(0.4, def.radius * 2, def.radius * 2), CFrame.new(x1, def.radius * 0.7, z1), Color3.fromRGB(190, 195, 205), Enum.Material.Metal, Enum.PartType.Cylinder)
			table.insert(spots, s)
		end
	end
	folder.Parent = Workspace
	local t = now()
	hazard = { kind = kind, startedAt = t, spots = spots, folder = folder }
end

-- The current map's own hazard, from its anchors (vents, hammers or saw runs).
-- Returns the hazard's name, or nil when the map has none.
function Bosses.startMapHazard(): string?
	local map = Arena.map()
	for _, kind in { "vents", "hammers", "saws" } do
		if #map[kind] > 0 then
			Bosses.startHazard(kind)
			return H[kind].name
		end
	end
	Bosses.stopHazard()
	return nil
end

local function robotsNear(x: number, z: number, radius: number): { World.Entity }
	local out = {}
	for _, e in aliveRobots() do
		local ex, ez = World.position(e)
		if (ex - x) ^ 2 + (ez - z) ^ 2 <= (radius + World.hitRadius(e, Config)) ^ 2 then
			table.insert(out, e)
		end
	end
	return out
end

local function tickHazard()
	local hz = hazard
	if not hz then
		return
	end
	local t = now()
	local def = H[hz.kind]
	local elapsed = t - hz.startedAt
	for _, s in hz.spots do
		if hz.kind == "vents" then
			local name, progress = HazardTiming.phase(def.cycle, elapsed + s.offset)
			if name ~= s.last then
				s.last = name
				s.parts.grate.Color = if name == "idle" then Color3.fromRGB(50, 50, 55) else Color3.fromRGB(255, 110, 30)
				s.parts.grate.Material = if name == "idle" then Enum.Material.DiamondPlate else Enum.Material.Neon
				s.parts.fire.Transparency = if name == "flame" then 0.25 else 1
				local flames = s.parts.grate:FindFirstChildOfClass("ParticleEmitter")
				if flames then
					flames.Enabled = name == "flame"
				end
			end
			-- The warning blinks faster as the fire gets close, then stays faint while it burns.
			local warnT = if name == "glow" then 0.2 + 0.4 * (0.5 + 0.5 * math.cos(progress * math.pi * (3 + 6 * progress)))
				elseif name == "flame" then 0.6
				else 1
			warnT = math.floor(warnT * 5 + 0.5) / 5 -- a few steps, so it replicates rarely
			if warnT ~= s.warnT then
				s.warnT = warnT
				s.parts.warn.Transparency = warnT
			end
			if name == "flame" then
				for _, e in robotsNear(s.x, s.z, def.radius) do
					if t - (s.hitAt[e.id] or 0) >= 0.25 then
						s.hitAt[e.id] = t
						Combat.damage(e, def.dps * 0.25, nil, true, s.x, s.z)
					end
				end
			end
		elseif hz.kind == "hammers" then
			local name, progress = HazardTiming.phase(def.cycle, elapsed + s.offset)
			local head = s.parts.head
			if name == "raise" then
				head.CFrame = CFrame.new(s.x, 2 + 16 * progress, s.z)
			elseif name == "shake" then
				head.CFrame = CFrame.new(s.x + rng:NextNumber(-0.4, 0.4), 18, s.z + rng:NextNumber(-0.4, 0.4))
				s.parts.mark.Transparency = 0.3
			else
				head.CFrame = CFrame.new(s.x, 2, s.z)
				if s.last ~= "slam" then
					s.parts.mark.Transparency = 0.7
					Remotes.Effect:FireAllClients("slam", s.x, s.z, def.radius)
					for _, e in robotsNear(s.x, s.z, def.radius) do
						Combat.damage(e, def.damage, nil, true, s.x, s.z)
						Combat.knock(e, s.x, s.z, def.knockback)
					end
				end
			end
			s.last = name
		elseif hz.kind == "saws" then
			local tr = s.track :: { number }
			local len = math.sqrt((tr[3] - tr[1]) ^ 2 + (tr[4] - tr[2]) ^ 2)
			local d = HazardTiming.pingPong(len, def.speed, elapsed + s.offset)
			local fx, fz = (tr[3] - tr[1]) / len, (tr[4] - tr[2]) / len
			local x, z = tr[1] + fx * d, tr[2] + fz * d
			s.x, s.z = x, z
			local spin = elapsed * 12
			s.parts.saw.CFrame = CFrame.lookAt(Vector3.new(x, def.radius * 0.7, z), Vector3.new(x + fx, def.radius * 0.7, z + fz)) * CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(spin, 0, 0)
			for _, e in robotsNear(x, z, def.radius) do
				if t - (s.hitAt[e.id] or 0) >= def.hitEvery then
					s.hitAt[e.id] = t
					Combat.damage(e, def.damage, nil, false, x, z)
					Combat.knock(e, x, z, def.knockback)
				end
			end
		end
	end
end

-- The map flow ----------------------------------------------------------------

local swapping = false
local nextPadAt = 0

-- Workspace attributes the HUD reads: the phase and when it ends (server time).
function Bosses.publish()
	Workspace:SetAttribute("MapPhase", flow.phase)
	Workspace:SetAttribute("MapEndsAt", if flow.endsAt == math.huge then 0 else flow.endsAt)
	Workspace:SetAttribute("MapBoss", if flow.boss then B.list[flow.boss].name else "")
end

-- Close everyone's blast doors (D82) with the new map's name and a line under it,
-- swap the map under them, place them on it, open the doors.
local function swapTo(name: string, after: (() -> ())?, subtitle: string?)
	swapping = true
	local c = Config.Maps.fadeColor[name]
	Remotes.MapSwap:FireAllClients(Color3.fromRGB(c[1], c[2], c[3]), MapLayouts[name].displayName, subtitle or "")
	task.delay(Config.Maps.fade, function()
		Bosses.stopHazard()
		Combat.clearAll()
		Arena.load(name)
		Pickups.setMode(if Arena.isArena() then "arena" else "overworld")
		Match.placeEveryone(rng)
		nextPadAt = 0
		swapping = false
		if after then
			after()
		end
	end)
end

local function onEvent(ev: string)
	local boss = flow.boss
	local def = if boss then B.list[boss] else nil
	if ev == "warning" and def then
		announce(`{def.name} approaches! Everyone goes to its lair in {B.warning} seconds.`)
	elseif ev == "arena" and boss then
		swapTo(flow.map, function()
			spawnArenaBoss(boss)
			Bosses.startMapHazard()
		end, if def then `The {def.name}'s lair` else nil)
	elseif ev == "escape" then
		local a = active
		if a then
			announce(`{a.def.name} got bored and left. No reward this time.`)
			removeBoss(a)
		end
		swapTo("grassland", nil, "Back to the overworld")
	elseif ev == "biome" then
		swapTo(flow.map, function()
			local name = Bosses.startMapHazard()
			announce(`{Arena.map().displayName}! {name or "Hazards"} for {math.floor(B.hazardDuration / 60)} minutes. Watch your step!`)
		end, `Changed for {math.floor(B.hazardDuration / 60)} minutes`)
	elseif ev == "revert" then
		announce(`{Arena.map().displayName} fades in {Config.Maps.revertWarning} seconds.`)
	elseif ev == "grassland" then
		swapTo("grassland", function()
			announce("The arena is calm again.")
		end, "Back to the overworld")
	end
	Bosses.publish()
end

-- Arena health pads: a Health Pod reappears on each empty pad every pads.every s.
local function tickPads(t: number)
	if swapping or not Arena.isArena() or t < nextPadAt then
		return
	end
	nextPadAt = t + Config.Maps.pads.every
	for _, p in Arena.map().pads do
		if not Pickups.hasPodNear("health", p.x, p.z, 4) then
			Pickups.spawnPod("health", p.x, p.z)
		end
	end
end

function Bosses.status(): string
	local a = active
	if a then
		return `{a.def.name} is in its arena ({math.floor(a.e.hp)} HP).`
	end
	if flow.phase == "grassland" then
		return `Next boss in about {math.max(0, math.floor((flow.nextBossAt - now()) / 60 + 0.5))} min (needs {B.minPlayers}+ players).`
	end
	return `{flow.phase}: {math.max(0, math.floor(flow.endsAt - now()))} s left on {flow.map}.`
end

-- Debug (/map name): load any map now, outside the flow. Returns false if unknown.
function Bosses.debugLoad(name: string): boolean
	if not Config.Maps.fadeColor[name] then
		return false
	end
	swapTo(name, function()
		Bosses.startMapHazard()
	end)
	return true
end

function Bosses.init()
	flow = MapFlow.new(Config, now(), rng:NextNumber())
	Bosses.publish()
	World.hooks.bossDied = Bosses.died
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(function()
			tickBoss(dt)
			tickHazard()
			local t = now()
			tickPads(t)
			if not swapping then
				local s, ev = MapFlow.tick(Config, flow, t, #Players:GetPlayers(), rng:NextNumber())
				flow = s
				if ev then
					onEvent(ev)
				end
			end
		end)
		if not ok then
			warn("[Bosses]", err)
		end
	end)
end

return Bosses
