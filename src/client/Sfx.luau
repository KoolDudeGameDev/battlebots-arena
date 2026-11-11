-- Sound effects (D78). Positional one-shots at a point, loops on a part, and flat
-- UI sounds. Distant sounds are skipped and each sound has a voice cap, so twenty
-- robots firing at once stay listenable. Client-only: nothing here crosses the network.
--
-- Defaults are free Creator Store sounds from Roblox and Pro Sound Effects (licensed
-- for every experience). To swap one, put a Sound named after its key in
-- ReplicatedStorage > Sounds (Rojo leaves extra children there alone); its SoundId,
-- Volume and PlaybackSpeed are used instead.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Sfx = {}

type Def = { id: string, volume: number, speed: number?, cut: number?, gap: number?, voices: number? }

local function asset(id: number): string
	return "rbxassetid://" .. id
end

-- cut = stop after this many seconds (long samples); gap = minimum seconds between
-- plays of this sound; voices = how many may overlap.
local SOUNDS: { [string]: Def } = {
	Blaster = { id = asset(9116237460), volume = 0.35, speed = 1.5, cut = 0.45, gap = 0.04, voices = 6 }, -- Laser Cannon 23
	Gatling = { id = asset(9116237460), volume = 0.22, speed = 2.1, cut = 0.25, gap = 0.05, voices = 5 },
	Railgun = { id = asset(9116229339), volume = 0.5, speed = 1.0, cut = 1.2, voices = 3 }, -- Laser Cannon 1405
	Laser = { id = asset(9114237705), volume = 0.25, speed = 1.4, cut = 0.25, gap = 0.12, voices = 3 }, -- Electric Arcing 6
	RocketLaunch = { id = asset(12222065), volume = 0.55, speed = 1.0, cut = 1.4, voices = 4 }, -- Launching rocket
	Explosion = { id = asset(9116973611), volume = 0.75, voices = 5 }, -- Mortar Explosion 3
	BigExplosion = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.9, voices = 3 },
	NetLaunch = { id = asset(9119227404), volume = 0.55, speed = 1.2, voices = 3 }, -- Slow Whoosh Beefy Airy Pass By 1
	NetLand = { id = asset(9113251117), volume = 0.5, voices = 3 }, -- Bag Grab Quick 8
	Flamethrower = { id = asset(9114429507), volume = 0.4 }, -- Fire Burst 1 (looped)
	FireBurst = { id = asset(9117985933), volume = 0.6, voices = 3 }, -- Pyro Fire Ball Burst 7
	SawLoop = { id = asset(9113809762), volume = 0.35 }, -- Circular Saw Blade 2 (looped)
	MetalHit = { id = asset(9125819216), volume = 0.4, gap = 0.05, voices = 5 }, -- Robot Impact Miscellaneous Metal Clangs
	HeavyHit = { id = asset(9116673678), volume = 0.55, voices = 4 }, -- Metal Impact Heavy Clunking Hits Scraping 1
	Slam = { id = asset(9125672726), volume = 0.8, voices = 3 }, -- Metal Impact Sledge Hammer Hits
	Rubble = { id = asset(9125869504), volume = 0.45, gap = 0.08, voices = 4 }, -- Rock Cracks Rock Hitting Rock Impact Debris
	Deflect = { id = asset(9119072660), volume = 0.4, gap = 0.06, voices = 3 }, -- Shield Clang As Hit Metal Sword Hubcap 1
	Zap = { id = asset(9116275998), volume = 0.16, gap = 0.15, voices = 2 }, -- Lightning Flashes Quick Electrical Bursts 13 (quieter, D83)
	Servo = { id = asset(9118360544), volume = 0.6, voices = 3 }, -- Robot Servo 1
	TrapSnap = { id = asset(9119074309), volume = 0.55, voices = 3 }, -- Shield Impacts 2
	Coin = { id = asset(9113849492), volume = 0.6, gap = 0.05, voices = 4 }, -- Coins Or Keys Jingle 6
	CoinBurst = { id = asset(9113849651), volume = 0.7, voices = 2 }, -- Coin Throws 3
	HitConfirm = { id = asset(9125819216), volume = 0.18, speed = 1.6, cut = 0.2, gap = 0.07, voices = 2 },
	LevelUp = { id = asset(9117887138), volume = 0.4, voices = 1 }, -- Power Up Sweeteners 3
}

local MAX_DISTANCE = 160 -- positional sounds further than this from you are skipped
local overrides: Folder? = nil
local holder: Part
local active: { [string]: number } = {}
local lastAt: { [string]: number } = {}

local function listener(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character.PrimaryPart
	if root then
		return root.Position
	end
	local cam = Workspace.CurrentCamera
	return cam and cam.CFrame.Position
end

-- A configured Sound for a key (an override from ReplicatedStorage.Sounds if present).
local function make(key: string): (Sound?, Def?)
	local def = SOUNDS[key]
	local custom = overrides and overrides:FindFirstChild(key)
	if custom and custom:IsA("Sound") then
		return custom:Clone(), def
	end
	if not def then
		return nil, nil
	end
	local s = Instance.new("Sound")
	s.Name = key
	s.SoundId = def.id
	s.Volume = def.volume
	s.PlaybackSpeed = def.speed or 1
	return s, def
end

-- May this sound play right now? (gap and voice cap)
local function admit(key: string, def: Def?): boolean
	local t = os.clock()
	local gap = def and def.gap or 0
	if t - (lastAt[key] or -1) < gap then
		return false
	end
	if (active[key] or 0) >= (def and def.voices or 4) then
		return false
	end
	lastAt[key] = t
	active[key] = (active[key] or 0) + 1
	return true
end

local function finish(key: string, sound: Sound, holderInstance: Instance, def: Def?)
	local done = false
	local function release()
		if done then
			return
		end
		done = true
		active[key] = math.max(0, (active[key] or 1) - 1)
		holderInstance:Destroy()
	end
	sound.Ended:Once(release)
	task.delay(def and def.cut or 4, release) -- a cut, or a safety net for long samples
end

-- A one-shot at a world position, e.g. a shot, impact or explosion.
function Sfx.at(key: string, pos: Vector3, volumeScale: number?)
	local from = listener()
	if from and (pos - from).Magnitude > MAX_DISTANCE then
		return
	end
	local def = SOUNDS[key]
	if not admit(key, def) then
		return
	end
	local sound = make(key)
	if not sound then
		active[key] -= 1
		return
	end
	local att = Instance.new("Attachment")
	att.WorldPosition = pos
	att.Parent = holder
	sound.Volume *= volumeScale or 1
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 12
	sound.RollOffMaxDistance = MAX_DISTANCE
	sound.Parent = att
	sound:Play()
	finish(key, sound, att, def)
end

-- A flat sound for you alone (hit confirm, coin, level up).
function Sfx.ui(key: string)
	local def = SOUNDS[key]
	if not admit(key, def) then
		return
	end
	local sound = make(key)
	if not sound then
		active[key] -= 1
		return
	end
	sound.Parent = SoundService
	sound:Play()
	finish(key, sound, sound, def)
end

-- A looping sound on a part (flamethrower, saw). The caller sets Playing and Volume;
-- it dies with the part.
function Sfx.loop(key: string, part: BasePart): Sound?
	local sound = make(key)
	if not sound then
		return nil
	end
	sound.Looped = true
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 10
	sound.RollOffMaxDistance = MAX_DISTANCE
	sound.Parent = part
	return sound
end

function Sfx.init(fx: Folder)
	overrides = ReplicatedStorage:FindFirstChild("Sounds") :: Folder?
	holder = Instance.new("Part")
	holder.Name = "SfxHolder"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one * 0.2
	holder.CFrame = CFrame.identity
	holder.Parent = fx
	-- Warm the cache in the background so the first shot isn't silent.
	task.spawn(function()
		local list = {}
		for key in SOUNDS do
			local s = make(key)
			if s then
				table.insert(list, s)
			end
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
	end)
end

return Sfx
