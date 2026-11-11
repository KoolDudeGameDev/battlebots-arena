-- Remote rate limits and the movement sanity check (GDD section 17).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local World = require(script.Parent.World)
local Arena = require(script.Parent.Arena)

local Guard = {}

type Bucket = { tokens: number, at: number }
local buckets: { [Player]: { [string]: Bucket } } = {}

-- Token bucket per player per remote; burst is twice the per-second budget.
function Guard.allow(player: Player, remote: string): boolean
	local rate = Config.RateLimits[remote] or 10
	local now = os.clock()
	local mine = buckets[player]
	if not mine then
		mine = {}
		buckets[player] = mine
	end
	local b = mine[remote]
	if not b then
		b = { tokens = rate * 2, at = now }
		mine[remote] = b
	end
	b.tokens = math.min(rate * 2, b.tokens + (now - b.at) * rate)
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

function Guard.isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v > -1e6 and v < 1e6
end

local function snapBack(e: World.Entity, root: BasePart)
	local last = e.lastValidPos :: Vector3
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(last) * root.CFrame.Rotation
end

local function check(e: World.Entity, interval: number)
	local root = e.root
	if not root or not root.Parent then
		return
	end
	local pos = root.Position
	local last = e.lastValidPos
	if not last then
		e.lastValidPos = pos
		return
	end
	local AC = Config.AntiCheat
	local half = Arena.half()
	if math.abs(pos.X) > half or math.abs(pos.Z) > half or pos.Y > 20 or pos.Y < -10 then
		snapBack(e, root)
		return
	end

	local disp = math.sqrt((pos.X - last.X) ^ 2 + (pos.Z - last.Z) ^ 2)
	local allowed = e.stats.speed * interval * AC.Tolerance + AC.Slack
	local now = Workspace:GetServerTimeNow()
	if now - e.pushGrantAt < 0.8 then
		allowed += e.pushRoom * 1.2 + 2 -- a server-sent knockback is moving this robot
	end
	if disp <= allowed then
		e.lastValidPos = pos
		return
	end

	-- A dash may show up in physics before its UseSkill request arrives.
	-- The Bomber core's Boost (D84) is a shorter dash with its own cooldown.
	local boost = e.chassisId == "bomber" and e.build.small
	if e.build.skill == "skl_dash" or boost then
		local dashRoom = (if boost then Config.Bomber.boost.distance else Config.Skills.skl_dash.distance) * e.stats.scale
		local recentGrant = now - e.dashGrantAt < AC.DashWindow
		if disp <= allowed + dashRoom and (recentGrant or now >= e.skillReadyAt) then
			if not recentGrant and boost then
				e.skillReadyAt = now + Config.Bomber.boost.cooldown
				e.dashGrantAt = now
			elseif not recentGrant then
				World.hooks.consumeDash(e) -- moved like a dash: charge the cooldown
			end
			e.lastValidPos = pos
			return
		end
	end
	snapBack(e, root)
end

function Guard.init()
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
	local interval = Config.AntiCheat.Interval
	task.spawn(function()
		while true do
			local dt = task.wait(interval)
			for _, e in World.entities do
				if e.alive and e.player then
					check(e, dt)
				end
			end
		end
	end)
end

return Guard
