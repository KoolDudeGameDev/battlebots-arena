-- Saved profiles (Phase 4a, D73): coins, owned robots and the equipped robot.
-- ProfileStore (vendor/, Apache-2.0, by loleris) autosaves and session-locks each
-- profile, so the same player on two servers can't duplicate coins. In Studio
-- without API access it falls back to a mock store that forgets on shutdown.
-- Every money rule lives in shared/Shop.luau (tested); this only applies them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Remotes)
local Shop = require(Shared.Shop)
local Chassis = require(Shared.Chassis)
local World = require(script.Parent.World)
local Guard = require(script.Parent.Guard)
local ProfileStore = require(script.Parent.vendor.ProfileStore)

local STORE_NAME = "Profiles_v1"
local store = ProfileStore.New(STORE_NAME, Shop.template())

local profiles: { [Player]: any } = {}

local Profiles = {}

local function notify(player: Player, message: string)
	Remotes.Notice:FireClient(player, message)
end

local function dirty(player: Player)
	local e = World.byPlayer[player]
	if e then
		e.dirty = true
	end
end

-- Starts the player's save session; false if it failed (the player is kicked) or they left.
function Profiles.load(player: Player): boolean
	local profile = store:StartSessionAsync(`Player_{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})
	if not profile then
		if player.Parent == Players then
			player:Kick("Your save couldn't load. Please rejoin in a moment.")
		end
		return false
	end
	profile:AddUserId(player.UserId)
	profile:Reconcile()
	Shop.repair(profile.Data, Chassis.byId, Chassis.default)
	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		if player.Parent == Players then
			player:Kick("Your save was opened on another server. Please rejoin.")
		end
	end)
	if player.Parent ~= Players then
		profile:EndSession()
		return false
	end
	profiles[player] = profile
	return true
end

function Profiles.release(player: Player)
	local profile = profiles[player]
	if profile then
		profiles[player] = nil
		profile:EndSession()
	end
end

-- The live saved data (coins, owned, equipped), or nil before it loads.
function Profiles.data(player: Player): Shop.Data?
	local profile = profiles[player]
	return if profile then profile.Data else nil
end

function Profiles.addCoins(player: Player, amount: number)
	local data = Profiles.data(player)
	if data then
		Shop.addCoins(data, amount)
		dirty(player)
	end
end

-- Debug only (/resetprofile): back to a brand-new player.
function Profiles.reset(player: Player)
	local data = Profiles.data(player)
	if data then
		local fresh = Shop.template()
		data.coins, data.owned, data.equipped = fresh.coins, fresh.owned, fresh.equipped
		dirty(player)
	end
end

local REASONS = {
	unknown = "That robot doesn't exist.",
	soon = "That robot is coming soon.",
	owned = "You already own that robot.",
	coins = "Not enough coins yet.",
	locked = "Buy that robot first.",
}

function Profiles.init()
	Remotes.BuyRobot.OnServerEvent:Connect(function(player: Player, id: any)
		local data = Profiles.data(player)
		if not Guard.allow(player, "BuyRobot") or not data or type(id) ~= "string" then
			return
		end
		local c = Chassis.byId[id]
		local ok, why = Shop.buy(data, c)
		if ok then
			notify(player, `Bought the {c.name}! Equip it in the Garage.`)
		else
			notify(player, REASONS[why or "unknown"])
		end
		dirty(player)
	end)
	Remotes.EquipRobot.OnServerEvent:Connect(function(player: Player, id: any)
		local data = Profiles.data(player)
		if not Guard.allow(player, "EquipRobot") or not data or type(id) ~= "string" then
			return
		end
		local c = Chassis.byId[id]
		local ok, why = Shop.equip(data, c)
		if ok then
			notify(player, `{c.name} equipped: you'll drive it from your next spawn.`)
		else
			notify(player, REASONS[why or "unknown"])
		end
		dirty(player)
	end)
end

return Profiles
