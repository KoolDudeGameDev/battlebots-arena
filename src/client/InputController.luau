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
local cursorToggled = false -- Ctrl: the cursor stays free until Ctrl again (D89)
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

-- Lock-on (D83): the enemy robot closest to your aim line, within your weapon's reach
-- and a few degrees of the aim (more for robots close enough to fill the view). Your
-- shots then go straight at it; the crosshair shows the lock.
local LOCK_DEGREES = 7
local function lockOn(root: BasePart, aim: number): (Model?, number?)
	local me = player.Character
	local reach = (me and me:GetAttribute("AttackRange")) or SOFT_AIM_RANGE
	local coop = string.sub(Workspace:GetAttribute("Map") or "", 1, 6) == "arena_" -- players are allies here
	local p = root.Position
	local best: Model?, bestAngle: number?, bestScore = nil, nil, math.huge
	for _, model in CollectionService:GetTagged("Robot") do
		if model == me or not model:IsA("Model") or model:GetAttribute("Protected") then
			continue
		end
		if coop and (model:GetAttribute("UserId") or 0) ~= 0 then
			continue
		end
		local r = model.PrimaryPart
		if not r then
			continue
		end
		local dx, dz = r.Position.X - p.X, r.Position.Z - p.Z
		local dist = math.sqrt(dx * dx + dz * dz)
		local hit = model:GetAttribute("HitRadius") or 3
		if dist - hit > reach then
			continue
		end
		local angle = math.atan2(dz, dx)
		local off = math.abs((angle - aim + math.pi) % (2 * math.pi) - math.pi)
		local allowed = math.max(math.rad(LOCK_DEGREES), math.atan(hit / math.max(dist, 1)))
		if off <= allowed and off / allowed < bestScore then
			best, bestAngle, bestScore = model, angle, off / allowed
		end
	end
	return best, bestAngle
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
	local F = Config.Skills.skl_flipper
	local airTime = math.min(F.flipAirTime, duration)
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
		local height = F.flipHeight * 4 * k * (1 - k) -- up and down, flipHeight at the top
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

-- Third-person look up and down: positive = mouse moved down = camera higher.
local function lookUpDown(delta: number)
	local C = Config.Camera
	ClientState.camPitch = math.clamp((ClientState.camPitch or C.PitchDefault) + delta, C.PitchMin, C.PitchMax)
end

-- Hull steering (D78). Guns only swivel 90 degrees either side of the hull's front,
-- so the hull keeps the aim inside that arc: it faces where it drives, but backs up
-- (instead of turning round) when you drive away from your aim, and turns on the
-- spot when you stand still and aim behind. Heavy robots turn slower.
local reversing = false
local function steerHull(root: BasePart, humanoid: Humanoid, dt: number)
	if humanoid.AutoRotate then
		humanoid.AutoRotate = false
	end
	if humanoid.PlatformStand then
		return -- mid-flip: the somersault owns the root
	end
	local model = root.Parent :: Model
	local P = Config.Presentation
	local chassis = model:GetAttribute("Chassis") or "rookie"
	local rate = if chassis == "bomber" and model:GetAttribute("Small") then P.turnRate.bomberSmall else P.turnRate[chassis] or P.turnRate.rookie
	local aim = Vector3.new(math.cos(ClientState.localAim), 0, math.sin(ClientState.localAim))
	local look = root.CFrame.LookVector
	local facing = Vector3.new(look.X, 0, look.Z)
	if facing.Magnitude < 1e-3 then
		return
	end
	facing = facing.Unit
	local move = humanoid.MoveDirection
	move = Vector3.new(move.X, 0, move.Z)
	local want: Vector3
	if move.Magnitude > 0.1 then
		move = move.Unit
		-- Hysteresis, so strafing across the 90-degree line doesn't flicker.
		local dot = move:Dot(aim)
		if dot < P.reverseDot then
			reversing = true
		elseif dot > -P.reverseDot then
			reversing = false
		end
		want = if reversing then -move else move
	else
		reversing = false
		local swivel = math.rad(P.swivelDegrees) * 0.9
		if facing:Dot(aim) >= math.cos(swivel) then
			return -- the turret can reach the aim: the hull stays put
		end
		want = aim
	end
	local current = math.atan2(facing.Z, facing.X)
	local target = math.atan2(want.Z, want.X)
	local diff = (target - current + math.pi) % (2 * math.pi) - math.pi
	local step = math.clamp(diff, -rate * dt, rate * dt)
	if math.abs(step) < 1e-4 then
		return
	end
	local yaw = current + step
	local pos = root.Position
	root.CFrame = CFrame.lookAt(pos, pos + Vector3.new(math.cos(yaw), 0, math.sin(yaw)))
end

local function performDash(root: BasePart, scale: number, distance: number)
	local humanoid = (root.Parent :: Model):FindFirstChildOfClass("Humanoid")
	local dir = if humanoid and humanoid.MoveDirection.Magnitude > 0.1
		then humanoid.MoveDirection
		else Vector3.new(math.cos(ClientState.localAim), 0, math.sin(ClientState.localAim))
	dir = Vector3.new(dir.X, 0, dir.Z).Unit
	slide(root, dir, distance * scale, Config.Skills.skl_dash.duration)
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
	local root = myRoot()
	local model = root and root.Parent :: Model
	if root and model then
		local scale = model:GetAttribute("VisualScale") or 1
		if s.skill == "skl_dash" then
			performDash(root, scale, Config.Skills.skl_dash.distance)
		elseif s.skill == "skl_bomb" and model:GetAttribute("Small") then
			performDash(root, scale, Config.Bomber.boost.distance) -- the Bomber core's Boost (D84)
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
		elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl then
			cursorToggled = not cursorToggled -- like Roblox's Shift Lock switch, on Ctrl (D89)
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

	-- Third-person: the mouse turns the camera (cursor locked to the centre and
	-- hidden behind the crosshair) and looks up and down (D78).
	UserInputService.InputChanged:Connect(function(input)
		if ClientState.camMode == "third" and not ClientState.cursorFree and input.UserInputType == Enum.UserInputType.MouseMovement then
			ClientState.camYaw += input.Delta.X * MOUSE_YAW
			lookUpDown(input.Delta.Y * MOUSE_YAW)
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
			lookUpDown((pos.Y - lastTouchPos.Y) * TOUCH_YAW)
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
			-- Ctrl switches the cursor on and off (D89); holding Left Alt frees it for a
			-- moment. Either way you can click upgrade cards.
			if not ClientState.isTouch then
				local free = cursorToggled or UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or ClientState.menuOpen
				ClientState.cursorFree = free
				UserInputService.MouseBehavior = if free then Enum.MouseBehavior.Default else Enum.MouseBehavior.LockCenter
				-- The locked cursor is hidden; the crosshair shows where you aim (D78).
				UserInputService.MouseIconEnabled = free
			end
			ClientState.localAim = ClientState.camYaw
		else
			-- Top-down on PC: the crosshair replaces the arrow, except in menus (D83).
			UserInputService.MouseIconEnabled = ClientState.isTouch or ClientState.menuOpen
		end
		if not third and root then
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

		-- Lock onto the robot under the crosshair (D83).
		ClientState.lockTarget = nil
		if root then
			local target, angle = lockOn(root, ClientState.localAim)
			if target and angle then
				ClientState.lockTarget = target
				ClientState.localAim = angle
			end
		end

		local humanoid = root and (root.Parent :: Model):FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			steerHull(root, humanoid, dt)
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
