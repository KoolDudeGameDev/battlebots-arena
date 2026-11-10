-- Bosses and arena hazards (Phase 4b, D39, D74).
-- Every 7-10 min with at least 2 players, a 20 s warning, then one of three
-- giant bosses hunts the nearest robot. Everyone who damaged it gets the same
-- 60 coins and 600 XP when it falls, more scatters on the ground, and the boss
-- leaves its hazard on the arena for 6 min. It leaves after 4 min if nobody
-- beats it. Timing rules live in shared/HazardTiming.luau (tested).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Combat2D = require(Shared.Combat2D)
local HazardTiming = require(Shared.HazardTiming)
local World = require(script.Parent.World)
local Pickups = require(script.Parent.Pickups)
local Combat = require(script.Parent.Combat)
local Match = require(script.Parent.Match)
local Profiles = require(script.Parent.Profiles)

local B = Config.Bosses
local H = Config.Hazards
local HALF = Config.Arena.HalfSize
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
}
local active: Active? = nil
local warningUntil = 0

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
			Combat.damage(e, damage, a.e, true, ex, ez)
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
					Combat.damage(v, atk.damage / ticks, e, true, vx, vz)
					v.burnUntil = now() + atk.burnDuration
					v.burnDps = atk.burnDps
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

local scheduleNext: () -> ()

function Bosses.summon(key: string)
	local def = B.list[key]
	if not def or active then
		return false
	end
	local x, z = 0, 0 -- the centre of the plaza
	local hp = HazardTiming.bossHp(B, #Players:GetPlayers())
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
	}
	announce(`{def.name} has entered the arena! Everyone who hits it shares the reward.`)
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
			World.hooks.addXp(p, B.reward.xp, "boss")
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
	Bosses.startHazard(a.def.hazard)
	scheduleNext()
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
	if t - a.spawnedAt >= B.despawnAfter then
		announce(`{a.def.name} got bored and left. No reward this time.`)
		removeBoss(a)
		scheduleNext()
		return
	end
	local atk = a.def.attack
	local x, z = World.position(e)

	-- Charging (Grinder): straight line, hurting each robot once.
	if a.chargeDir and t < a.busyUntil then
		local dir = a.chargeDir.Unit
		local step = a.def.speed * atk.speedMult * e.slowFactor * dt
		local nx = math.clamp(x + dir.X * step, -HALF + 12, HALF - 12)
		local nz = math.clamp(z + dir.Z * step, -HALF + 12, HALF - 12)
		face(a, nx, nz, dir)
		local reach = World.hitRadius(e, Config)
		for _, v in aliveRobots() do
			if not a.chargeHit[v.id] then
				local vx, vz = World.position(v)
				if (vx - nx) ^ 2 + (vz - nz) ^ 2 <= (reach + World.hitRadius(v, Config)) ^ 2 then
					a.chargeHit[v.id] = true
					Combat.damage(v, atk.damage, e, false, vx, vz)
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

type Spot = { x: number, z: number, offset: number, parts: { [string]: BasePart }, last: string, hitAt: { [number]: number }, track: { number }? }
local hazard: { kind: string, startedAt: number, untilT: number, spots: { Spot }, folder: Folder }? = nil

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

local function ringPoints(radius: number, startDeg: number): { { number } }
	local out = {}
	for k = 0, 7 do
		local ang = math.rad(startDeg + k * 45)
		table.insert(out, { math.cos(ang) * radius, math.sin(ang) * radius })
	end
	return out
end

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
	if kind == "vents" then
		for i, p in ringPoints(def.ring, 22.5) do
			local s: Spot = { x = p[1], z = p[2], offset = i * 0.75, parts = {}, last = "", hitAt = {} }
			s.parts.grate = part(folder, "Vent", Vector3.new(0.4, def.radius * 2, def.radius * 2), CFrame.new(s.x, 0.2, s.z) * UPRIGHT, Color3.fromRGB(50, 50, 55), Enum.Material.DiamondPlate, Enum.PartType.Cylinder)
			s.parts.fire = part(folder, "VentFire", Vector3.new(10, def.radius * 1.6, def.radius * 1.6), CFrame.new(s.x, 5, s.z) * UPRIGHT, Color3.fromRGB(255, 120, 30), Enum.Material.Neon, Enum.PartType.Cylinder)
			s.parts.fire.Transparency = 1
			table.insert(spots, s)
		end
	elseif kind == "hammers" then
		for i, p in ringPoints(def.ring, 0) do
			local s: Spot = { x = p[1], z = p[2], offset = i * 0.7, parts = {}, last = "", hitAt = {} }
			s.parts.mark = part(folder, "HammerMark", Vector3.new(0.2, def.radius * 2, def.radius * 2), CFrame.new(s.x, 0.15, s.z) * UPRIGHT, Color3.fromRGB(200, 60, 50), Enum.Material.Neon, Enum.PartType.Cylinder)
			s.parts.mark.Transparency = 0.7
			s.parts.head = part(folder, "HammerHead", Vector3.new(def.radius * 1.4, 4, def.radius * 1.4), CFrame.new(s.x, 18, s.z), Color3.fromRGB(70, 74, 82), Enum.Material.Metal)
			table.insert(spots, s)
		end
	elseif kind == "saws" then
		for k = 0, 3 do
			local ang = k * math.pi / 2
			local c, sn = math.cos(ang), math.sin(ang)
			local function turn(px: number, pz: number): (number, number)
				return px * c - pz * sn, px * sn + pz * c
			end
			local x1, z1 = turn(-def.reach, def.side)
			local x2, z2 = turn(def.reach, def.side)
			local s: Spot = { x = x1, z = z1, offset = k * 2, parts = {}, last = "", hitAt = {}, track = { x1, z1, x2, z2 } }
			local len = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
			part(folder, "SawTrack", Vector3.new(len, 0.15, 1.2), CFrame.lookAt(Vector3.new((x1 + x2) / 2, 0.08, (z1 + z2) / 2), Vector3.new(x2, 0.08, z2)) * CFrame.Angles(0, math.rad(90), 0), Color3.fromRGB(60, 60, 66), Enum.Material.Metal)
			s.parts.saw = part(folder, "FloorSaw", Vector3.new(0.4, def.radius * 2, def.radius * 2), CFrame.new(x1, def.radius * 0.7, z1), Color3.fromRGB(190, 195, 205), Enum.Material.Metal, Enum.PartType.Cylinder)
			table.insert(spots, s)
		end
	end
	folder.Parent = Workspace
	local t = now()
	hazard = { kind = kind, startedAt = t, untilT = t + B.hazardDuration, spots = spots, folder = folder }
	announce(`{def.name} are active for {math.floor(B.hazardDuration / 60)} minutes. Watch your step!`)
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
	if t >= hz.untilT then
		Bosses.stopHazard()
		announce("The arena is calm again.")
		return
	end
	local def = H[hz.kind]
	local elapsed = t - hz.startedAt
	for _, s in hz.spots do
		if hz.kind == "vents" then
			local name = HazardTiming.phase(def.cycle, elapsed + s.offset)
			if name ~= s.last then
				s.last = name
				s.parts.grate.Color = if name == "idle" then Color3.fromRGB(50, 50, 55) else Color3.fromRGB(255, 110, 30)
				s.parts.grate.Material = if name == "idle" then Enum.Material.DiamondPlate else Enum.Material.Neon
				s.parts.fire.Transparency = if name == "flame" then 0.25 else 1
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

-- Schedule -------------------------------------------------------------------

local nextBossAt = math.huge

scheduleNext = function()
	nextBossAt = now() + rng:NextNumber(B.every[1], B.every[2])
end

function Bosses.status(): string
	if active then
		return `{active.def.name} is in the arena ({math.floor(active.e.hp)} HP).`
	end
	return `Next boss in about {math.max(0, math.floor((nextBossAt - now()) / 60 + 0.5))} min (needs {B.minPlayers}+ players).`
end

function Bosses.init()
	scheduleNext()
	World.hooks.bossDied = Bosses.died
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(function()
			tickBoss(dt)
			tickHazard()
		end)
		if not ok then
			warn("[Bosses]", err)
		end
		local t = now()
		if not active and warningUntil == 0 and t >= nextBossAt then
			if #Players:GetPlayers() >= B.minPlayers then
				warningUntil = t + B.warning
				announce(`A boss is coming in {B.warning} seconds!`)
			else
				scheduleNext() -- not enough players: try again later
			end
		elseif warningUntil > 0 and t >= warningUntil then
			warningUntil = 0
			local keys = {}
			for key in B.list do
				table.insert(keys, key)
			end
			table.sort(keys)
			Bosses.summon(keys[rng:NextInteger(1, #keys)])
		end
	end)
end

return Bosses
