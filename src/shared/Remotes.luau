-- The one list of remotes. The server creates them; clients wait for them.
--
-- Client -> server (intent only):
--   AimUpdate (U)    angle: number, firing: boolean            20 Hz
--   SetFiring        firing: boolean                           on change
--   UseSkill         ()
--   PickUpgrade      offerId: number, cardIndex: number
--   ClientReady      ()                                        once, asks for the orb snapshot
-- Server -> client:
--   State            private HUD state for the owner
--   ProjectilesSpawned (U)  buffer of 37-byte records: id, code, x, z, angle, speed, range, accel, maxSpeed, ownerEntityId
--   ProjectilesEnded (U)    { id, ... }
--   Aims (U)         { userId, angle, ... }                    10 Hz
--   OrbsSnapshot     { {id, kind, x, z}, ... }
--   OrbsSpawned      { {id, kind, x, z}, ... }
--   OrbsCollected    { {id, userId}, ... }
--   HitFeedback (U)  targetId, x, z, amount, kind              to shooter and victim;
--                    kind = "dealt" | "taken" | "armor" | "block"
--   Effect (U)       kind, x, z, radius                        explosions, deflect sparks
--   KillFeed         killerName, victimName, victimLevel
--   Leaderboard      { {name, score, level, userId}, ... }     1 Hz
--   Death            { killerName, killerLevel, level, score, respawnAt }
--   Notice           text                                      a system line in chat
--   Knockback        dx, dz                                    studs to push your own robot
--   Effect "beam"    kind, x1, z1, 0, x2, z2                   Shock Coil chain segment
--   Effect "laser"   kind, x1, z1, 0, x2, z2                   Laser Gun beam (10 per second while firing)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RELIABLE = {
	"SetFiring",
	"UseSkill",
	"PickUpgrade",
	"ClientReady",
	"State",
	"OrbsSnapshot",
	"OrbsSpawned",
	"OrbsCollected",
	"KillFeed",
	"Leaderboard",
	"Death",
	"Notice",
	"Knockback",
	"BuyRobot",
	"EquipRobot",
	"Announce", -- big centre banner (boss warnings, hazards)
	"MapSwap", -- fade colour before the map changes (D81)
	"CoverBroken", -- a boss smashed a destructible cover piece (kind, id)
}
local UNRELIABLE = {
	"AimUpdate",
	"ProjectilesSpawned",
	"ProjectilesEnded",
	"Aims",
	"HitFeedback",
	"Effect",
}

local Remotes = {}

local folder: Folder
if RunService:IsServer() then
	folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, name in RELIABLE do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	for _, name in UNRELIABLE do
		local r = Instance.new("UnreliableRemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	folder.Parent = ReplicatedStorage
else
	folder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
end

for _, name in RELIABLE do
	Remotes[name] = folder:WaitForChild(name)
end
for _, name in UNRELIABLE do
	Remotes[name] = folder:WaitForChild(name)
end

return Remotes
