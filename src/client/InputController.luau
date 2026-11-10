-- PC and touch controls (GDD section 8). Movement stays on the default Roblox
-- controls (WASD / left thumbstick); this module owns aiming, the trigger,
-- auto-fire with mobile soft-aim, the skill key and the 1/2/3 pick keys.
-- It sends intent only: the aim angle and whether the trigger is held.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local ClientState = require(script.Parent.ClientState)

local InputController = {}

local player = Players.LocalPlayer
local SOFT_AIM_RANGE = Config.Weapons.blaster.range
local STICK_DEADZONE = 12
local MOUSE_YAW = 0.0045 -- radians per pixel, third-person
local TOUCH_YAW = 0.008

local mouseDown = false
local aimTouch: InputObject? = nil
local aimOrigin = Vector2.zero
local lastTouchPos = Vector2.zero
local lastSentFiring = false

local function myRoot(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function mouseAim(root: BasePart): number?
	local cam = Workspace.CurrentCamera
	local m = UserInputService:GetMouseLocation()
	local ray = cam:ViewportPointToRay(m.X, m.Y)
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local t = -ray.Origin.Y / ray.Direction.Y
	local hit = ray.Origin + ray.Direction * t
	local p = root.Position
	return math.atan2(hit.Z - p.Z, hit.X - p.X)
end

-- Nearest enemy robot in range, else the nearest crate (mobile auto-fire).
local function softAim(root: BasePart): number?
	local p = root.Position
	local bestAngle, bestD = nil, math.huge
	for _, model in CollectionService:GetTagged("Robot") do
		if model ~= player.Character and model:IsA("Model") and not model:GetAttribute("Protected") then
			local r = model.PrimaryPart
			if r then
				local d = (r.Position - p).Magnitude
				if d < SOFT_AIM_RANGE and d < bestD then
					bestAngle, bestD = math.atan2(r.Position.Z - p.Z, r.Position.X - p.X), d
				end
			end
		end
	end
	if bestAngle then
		return bestAngle
	end
	for _, scrap in CollectionService:GetTagged("Crate") do -- scrap heaps and wrecks
		if scrap:IsA("PVInstance") then
			local pos = scrap:GetPivot().Position
			local d = (pos - p).Magnitude
			if d < SOFT_AIM_RANGE and d < bestD then
				bestAngle, bestD = math.atan2(pos.Z - p.Z, pos.X - p.X), d
			end
		end
	end
	return bestAngle
end

-- Dash -------------------------------------------------------------------------

local dashParams = RaycastParams.new()
dashParams.FilterType = Enum.RaycastFilterType.Include

-- Slides your own robot (you own its physics): used by Dash and by knockback,
-- stopping short of walls, cover, crates and Earth Walls.
-- Flipper (D72): your robot is tossed up and turns a full somersault, then lands
-- upright. Driven here because this client owns its character's physics.
local function flipOver(root: BasePart, push: Vector3, duration: number)
	local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local axis = if push.Magnitude > 0.05 then push.Unit:Cross(Vector3.yAxis) * -1 else root.CFrame.RightVector
	local start = root.CFrame
	local airTime = math.min(0.8, duration)
	humanoid.PlatformStand = true
	local t = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		if not root.Parent then
			conn:Disconnect()
			return
		end
		t += dt
		local k = math.min(1, t / airTime)
		local height = 6 * 4 * k * (1 - k) -- up and down, 6 studs at the top
		local flat = root.Position * Vector3.new(1, 0, 1) + Vector3.new(0, start.Position.Y, 0)
		root.AssemblyLinearVelocity = Vector3.zero
		root.CFrame = CFrame.new(flat + Vector3.new(0, height, 0)) * CFrame.fromAxisAngle(axis, k * 2 * math.pi) * start.Rotation
		if k >= 1 then
			conn:Disconnect()
			root.CFrame = CFrame.new(flat) * start.Rotation
			humanoid.PlatformStand = false
		end
	end)
end

local function slide(root: BasePart, dir: Vector3, distance: number, duration: number)
	local filter = {}
	for _, name in { "Arena", "Crates", "EarthWalls" } do
		local f = Workspace:FindFirstChild(name)
		if f then
			table.insert(filter, f)
		end
	end
	dashParams.FilterDescendantsInstances = filter
	local hit = Workspace:Raycast(root.Position, dir * (distance + 3), dashParams)
	if hit then
		distance = math.max(0, (hit.Position - root.Position).Magnitude - 3)
	end
	if distance <= 0 then
		return
	end
	local moved = 0
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt)
		if not root.Parent then
			conn:Disconnect()
			return
		end
		local step = math.min(distance - moved, distance / duration * dt)
		root.CFrame += dir * step
		moved += step
		if moved >= distance - 1e-3 then
			conn:Disconnect()
		end
	end)
end

local function performDash(root: BasePart, scale: number)
	local humanoid = (root.Parent :: Model):FindFirstChildOfClass("Humanoid")
	local dir = if humanoid and humanoid.MoveDirection.Magnitude > 0.1
		then humanoid.MoveDirection
		else Vector3.new(math.cos(ClientState.localAim), 0, math.sin(ClientState.localAim))
	dir = Vector3.new(dir.X, 0, dir.Z).Unit
	local D = Config.Skills.skl_dash
	slide(root, dir, D.distance * scale, D.duration)
end

function InputController.useSkill()
	local s = ClientState.state
	if not s or not s.alive or not s.skill then
		return
	end
	local t = Workspace:GetServerTimeNow()
	if t < math.max(s.skillReadyAt or 0, ClientState.localSkillReadyAt) then
		return
	end
	ClientState.localSkillReadyAt = t + (s.skillCooldown or 0)
	Remotes.UseSkill:FireServer()
	if s.skill == "skl_dash" then
		local root = myRoot()
		if root then
			local model = root.Parent :: Model
			performDash(root, model:GetAttribute("VisualScale") or 1)
		end
	end
end

function InputController.toggleAuto()
	ClientState.autoFire = not ClientState.autoFire
end

-- Switches between the top-down and third-person views (V / CAM button).
function InputController.toggleCam()
	if ClientState.camMode == "top" then
		ClientState.camMode = "third"
		ClientState.camYaw = ClientState.localAim -- keep facing where you were aiming
	else
		ClientState.camMode = "top"
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

-- Boot -------------------------------------------------------------------------

function InputController.init()
	-- Explosions and melee hits push you; the server allows for the movement.
	Remotes.Knockback.OnClientEvent:Connect(function(dx: any, dz: any, flip: any)
		local root = myRoot()
		if root and type(dx) == "number" and type(dz) == "number" then
			local v = Vector3.new(dx, 0, dz)
			if v.Magnitude > 0.05 then
				slide(root, v.Unit, math.min(v.Magnitude, 30), 0.18)
			end
			if type(flip) == "number" and flip > 0 then
				flipOver(root, v, math.min(flip, 3))
			end
		end
	end)

	ContextActionService:BindActionAtPriority("BattleSkill", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			InputController.useSkill()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.Q)

	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseDown = not processed
		elseif processed then
			return
		elseif input.KeyCode == Enum.KeyCode.E then
			InputController.toggleAuto()
		elseif input.KeyCode == Enum.KeyCode.V then
			InputController.toggleCam()
		elseif input.KeyCode == Enum.KeyCode.G and ClientState.actions.garage then
			ClientState.actions.garage()
		elseif ClientState.actions.pick then
			local index = ({ [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3 })[input.KeyCode]
			if index then
				ClientState.actions.pick(index)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseDown = false
		end
	end)

	-- Third-person: the mouse turns the camera (cursor locked to the centre).
	UserInputService.InputChanged:Connect(function(input)
		if ClientState.camMode == "third" and not ClientState.cursorFree and input.UserInputType == Enum.UserInputType.MouseMovement then
			ClientState.camYaw += input.Delta.X * MOUSE_YAW
		end
	end)

	-- Right-half touch: an aim stick in top-down (drag to aim, hold to fire);
	-- a camera drag in third-person (fire with the FIRE button).
	UserInputService.TouchStarted:Connect(function(touch, processed)
		if processed or aimTouch then
			return
		end
		local cam = Workspace.CurrentCamera
		if touch.Position.X > cam.ViewportSize.X / 2 then
			aimTouch = touch
			aimOrigin = Vector2.new(touch.Position.X, touch.Position.Y)
			lastTouchPos = aimOrigin
		end
	end)
	UserInputService.TouchMoved:Connect(function(touch)
		if touch ~= aimTouch then
			return
		end
		local pos = Vector2.new(touch.Position.X, touch.Position.Y)
		if ClientState.camMode == "third" then
			ClientState.camYaw += (pos.X - lastTouchPos.X) * TOUCH_YAW
			lastTouchPos = pos
			return
		end
		local v = pos - aimOrigin
		if v.Magnitude > STICK_DEADZONE then
			ClientState.localAim = math.atan2(v.Y, v.X) -- screen down = world +Z
		end
	end)
	UserInputService.TouchEnded:Connect(function(touch)
		if touch == aimTouch then
			aimTouch = nil
		end
	end)

	local sendAcc = 0
	RunService.RenderStepped:Connect(function(dt)
		local root = myRoot()
		local third = ClientState.camMode == "third"
		-- Auto-fire always shoots, even at a wall or into empty space. It no longer
		-- costs spawn protection: that only ends when you actually damage a robot.
		local autoHasTarget = true
		if third then
			-- Roblox resets MouseBehavior each frame, so it is re-applied here.
			-- Holding Left Alt frees the cursor, e.g. to click upgrade cards.
			if not ClientState.isTouch then
				local free = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or ClientState.menuOpen
				ClientState.cursorFree = free
				UserInputService.MouseBehavior = if free then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
			end
			ClientState.localAim = ClientState.camYaw
		elseif root then
			if ClientState.isTouch then
				if not aimTouch and ClientState.autoFire then
					local a = softAim(root)
					if a then
						ClientState.localAim = a
						autoHasTarget = true
					end
				end
			else
				local a = mouseAim(root)
				if a then
					ClientState.localAim = a
				end
			end
		end

		local stickFiring = aimTouch ~= nil and not third -- in third-person the drag only turns the camera
		local firing = (mouseDown or stickFiring or ClientState.fireButtonHeld or (ClientState.autoFire and autoHasTarget)) and root ~= nil
		ClientState.firing = firing
		if firing ~= lastSentFiring then
			lastSentFiring = firing
			Remotes.SetFiring:FireServer(firing)
		end
		sendAcc += dt
		if sendAcc >= 0.05 and root then
			sendAcc = 0
			Remotes.AimUpdate:FireServer(ClientState.localAim, firing)
		end
	end)

	ClientState.actions.useSkill = InputController.useSkill
	ClientState.actions.toggleAuto = InputController.toggleAuto
	ClientState.actions.toggleCam = InputController.toggleCam
	InputController.aimTouchActive = function()
		return aimTouch ~= nil and ClientState.camMode == "top", aimOrigin
	end
end

return InputController
