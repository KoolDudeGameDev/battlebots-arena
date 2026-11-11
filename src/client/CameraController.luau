-- Two views (D37): the default third-person camera behind the robot that turns
-- with ClientState.camYaw, and the fixed top-down camera (about 66 degrees of tilt),
-- which pulls back as your weapon's reach grows (D82). Both follow your robot, hold on the death point, snap to
-- a new robot, and shake when you are hit.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local ClientState = require(script.Parent.ClientState)

local CameraController = {}

local player = Players.LocalPlayer
local C = Config.Camera
local THIRD_DIST = 18 -- camera distance from the robot (16 back and 8 up at the default pitch)
local THIRD_LOOK_AHEAD = 30
local trauma = 0

function CameraController.shake(amount: number)
	trauma = math.min(1, trauma + amount)
end

function CameraController.init()
	local focus = Vector3.zero
	local zoom = 1
	local lastCharacter: Model? = nil
	local rng = Random.new()

	RunService:BindToRenderStep("BattleCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		cam.CameraType = Enum.CameraType.Scriptable

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local scale = 1
		if root then
			local p = root.Position
			local target = Vector3.new(p.X, 0, p.Z)
			scale = (character :: Model):GetAttribute("VisualScale") or 1
			if character ~= lastCharacter then
				lastCharacter = character
				focus = target -- snap on respawn
				local look = root.CFrame.LookVector
				ClientState.camYaw = math.atan2(look.Z, look.X) -- start behind the new robot
			else
				local alpha = 1 - (1 - C.Lerp) ^ (dt * 60)
				focus = focus:Lerp(target, alpha)
			end
		else
			-- Out of a boss fight (D85): watch the boss until the fight ends.
			local boss = CollectionService:GetTagged("Boss")[1]
			local bossRoot = boss and boss:IsA("Model") and boss.PrimaryPart
			if bossRoot then
				local p = bossRoot.Position
				focus = focus:Lerp(Vector3.new(p.X, 0, p.Z), 1 - (1 - C.Lerp * 0.3) ^ (dt * 60))
			end
		end

		trauma = math.max(0, trauma - dt * 1.8)
		local s = trauma * trauma * 1.5
		local offset = Vector3.new(rng:NextNumber(-s, s), 0, rng:NextNumber(-s, s))

		if ClientState.camMode == "third" then
			cam.FieldOfView = 70
			local yaw = ClientState.camYaw
			local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
			local base = focus + Vector3.new(0, 3 * scale, 0) + offset
			-- Mouse up and down swings the camera lower (look out across the arena) or
			-- higher (look down on the fight) round the robot (D78).
			local pitch = ClientState.camPitch or C.PitchDefault
			local eye = base - dir * math.cos(pitch) * THIRD_DIST * scale + Vector3.new(0, math.sin(pitch) * THIRD_DIST * scale, 0)
			cam.CFrame = CFrame.lookAt(eye, base + dir * THIRD_LOOK_AHEAD)
		else
			-- Zoom out with your weapon's reach (D82), never closer than the default view.
			local reach = if character then character:GetAttribute("AttackRange") else nil
			local want = math.clamp((if type(reach) == "number" then reach else 0) / C.ZoomBaseRange, 1, C.ZoomMax)
			zoom += (want - zoom) * math.min(1, dt * 3)
			cam.FieldOfView = C.Fov
			local look = focus + offset
			cam.CFrame = CFrame.lookAt(look + Vector3.new(0, C.Height * zoom, C.Back * zoom), look)
		end
	end)
end

return CameraController
