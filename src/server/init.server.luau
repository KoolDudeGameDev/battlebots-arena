-- Server boot: build the arena, wire the services together, start the loops.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

Players.CharacterAutoLoads = false

require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes")) -- creates the remotes

local World = require(script.World)
local Arena = require(script.Arena)
local RobotBuilder = require(script.RobotBuilder)
local Guard = require(script.Guard)
local Pickups = require(script.Pickups)
local Combat = require(script.Combat)
local Match = require(script.Match)
local Profiles = require(script.Profiles)
local Bosses = require(script.Bosses)
local DebugCommands = require(script.DebugCommands)

World.hooks.onKill = Match.onKill
World.hooks.addXp = Match.addXp
World.hooks.markDirty = function(e)
	e.dirty = true
end
World.hooks.spill = Pickups.spill
World.hooks.refreshStats = Match.refreshStats
World.hooks.spawnDummy = Match.spawnDummy
World.hooks.consumeDash = Combat.consumeDash
World.hooks.applyPod = Combat.applyPod
World.hooks.spawnPod = Pickups.spawnPod
World.hooks.setSmall = Match.setSmall
World.hooks.addCoins = function(e, amount)
	if e.player then
		Profiles.addCoins(e.player, amount)
	end
end

Arena.build()
RobotBuilder.installStarterCharacter()
Guard.init()
Pickups.init()
Combat.init()
Profiles.init()
Bosses.init()
DebugCommands.init()
Match.init() -- last: starts spawning players
