-- Client boot. Everything here is presentation and input; the server decides
-- every outcome.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local ClientState = require(script.ClientState)
local CameraController = require(script.CameraController)
local InputController = require(script.InputController)
local Robots = require(script.Robots)
local Projectiles = require(script.Projectiles)
local Orbs = require(script.Orbs)
local Effects = require(script.Effects)
local Vfx = require(script.Vfx)
local Sfx = require(script.Sfx)
local Hud = require(script.Hud)
local Garage = require(script.Garage)
local Crosshair = require(script.Crosshair)
local CrateBars = require(script.CrateBars)

-- Client-only visuals live here; nothing in this folder replicates.
local fx = Instance.new("Folder")
fx.Name = "ClientFx"
fx.Parent = Workspace

ClientState.actions.shake = CameraController.shake

Sfx.init(fx) -- first: every other module may play sounds
CameraController.init()
InputController.init()
Robots.init(fx)
Projectiles.init(fx)
Orbs.init(fx)
Vfx.init(fx)
Effects.init(fx)
Hud.init(InputController.aimTouchActive)
Garage.init()
Crosshair.init()
CrateBars.init()

Remotes.ClientReady:FireServer() -- asks for the orb snapshot now that handlers exist
