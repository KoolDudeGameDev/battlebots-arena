-- The crosshair (D83, was a white dot). Third-person: where your shots fly. Top-down
-- on PC: it replaces the mouse arrow. When a target is locked (InputController picks
-- the robot nearest your aim, within reach) the crosshair jumps onto it, turns red
-- and a ring closes round it; your shots go to that robot.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.ClientState)

local Crosshair = {}

local WHITE = Color3.fromRGB(245, 245, 245)
local RED = Color3.fromRGB(255, 70, 60)

local function frame(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	return f
end

function Crosshair.init()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.IgnoreGuiInset = true -- so mouse and viewport coordinates line up
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")

	local holder = frame(gui, { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(40, 40), BackgroundTransparency = 1 })
	local parts: { Frame } = {}
	-- Four ticks round a gap, and a small centre pip, each with a dark outline.
	for _, spec in { { 0.5, 0, 2, 9, 0.5, 0 }, { 0.5, 1, 2, 9, 0.5, 1 }, { 0, 0.5, 9, 2, 0, 0.5 }, { 1, 0.5, 9, 2, 1, 0.5 } } do
		table.insert(parts, frame(holder, { AnchorPoint = Vector2.new(spec[5], spec[6]), Position = UDim2.fromScale(spec[1], spec[2]) + UDim2.fromOffset((spec[5] - 0.5) * -10, (spec[6] - 0.5) * -10), Size = UDim2.fromOffset(spec[3], spec[4]) }))
	end
	table.insert(parts, frame(holder, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(3, 3) }))
	for _, p in parts do
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.4
		stroke.Parent = p
	end
	local ring = frame(holder, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundTransparency = 1, Visible = false })
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = ring
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Color = RED
	ringStroke.Thickness = 2
	ringStroke.Parent = ring

	local ringSize = 0
	RunService.RenderStepped:Connect(function(dt)
		local cam = Workspace.CurrentCamera
		local character = player.Character
		local root = character and character.PrimaryPart
		local third = ClientState.camMode == "third"
		local target = ClientState.lockTarget
		local targetRoot = target and target.Parent and target.PrimaryPart
		local menu = ClientState.menuOpen or ClientState.cursorFree
		local show = cam ~= nil and root ~= nil and not menu and (third or not ClientState.isTouch or targetRoot ~= nil)
		holder.Visible = show
		if not show or not cam or not root then
			ringSize = 0
			return
		end
		local at: Vector2
		if targetRoot then
			local v = cam:WorldToViewportPoint(targetRoot.Position + Vector3.new(0, 1.5, 0))
			at = Vector2.new(v.X, v.Y)
		elseif third then
			-- Where the shots fly: ahead along the aim, at gun height.
			local scale = character:GetAttribute("VisualScale") or 1
			local aim = Vector3.new(math.cos(ClientState.localAim), 0, math.sin(ClientState.localAim))
			local v = cam:WorldToViewportPoint(root.Position + Vector3.new(0, 3 * scale, 0) + aim * 30)
			at = Vector2.new(v.X, v.Y)
		else
			at = UserInputService:GetMouseLocation()
		end
		holder.Position = UDim2.fromOffset(at.X, at.Y)
		local color = if targetRoot then RED else WHITE
		for _, p in parts do
			p.BackgroundColor3 = color
		end
		-- The lock ring closes in round the target's body.
		ring.Visible = targetRoot ~= nil
		if targetRoot then
			local hit = (target :: Model):GetAttribute("HitRadius") or 3
			local edge = cam:WorldToViewportPoint(targetRoot.Position + cam.CFrame.RightVector * hit * 1.3)
			local want = math.clamp(math.abs(edge.X - at.X) * 2, 36, 260)
			ringSize = if ringSize == 0 then want * 1.8 else ringSize + (want - ringSize) * math.min(1, dt * 12)
			ring.Size = UDim2.fromOffset(ringSize, ringSize)
		else
			ringSize = 0
		end
	end)
end

return Crosshair
