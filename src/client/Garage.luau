-- The Garage (Phase 4a, D73): every robot with its stats and a short
-- description, bought and equipped with saved coins. The server decides every
-- purchase (shared/Shop.luau); this panel only shows the state and asks.
-- Open with G or the GARAGE button. An equipped robot drives from your next spawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Chassis = require(Shared.Chassis)
local Stats = require(Shared.Stats)
local Shop = require(Shared.Shop)
local ClientState = require(script.Parent.ClientState)

local Garage = {}

local PANEL = Color3.fromRGB(20, 22, 28)
local CARD = Color3.fromRGB(32, 35, 44)
local TEXT = Color3.fromRGB(240, 242, 246)
local MUTED = Color3.fromRGB(165, 170, 180)
local GOLD = Color3.fromRGB(255, 196, 40)
local GOLD_HOVER = Color3.fromRGB(232, 172, 20)
local GOLD_DARK = Color3.fromRGB(150, 100, 0)
local INK = Color3.fromRGB(28, 22, 6)
local OUTLINE = Color3.fromRGB(70, 76, 90)
local OK_GREEN = Color3.fromRGB(110, 210, 140)
local ROLE = { gun_mounts = "Ranged", melee_mounts = "Melee", special_mounts = "Special" }
local STAT_ROWS = { { key = "hp", label = "HP" }, { key = "armor", label = "Armor" }, { key = "speed", label = "Speed" }, { key = "range", label = "Reach" } }
local FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer
local gui: ScreenGui
local overlay: Frame
local coinLabel: TextLabel
local cards: { [string]: { button: TextButton, status: TextLabel, stroke: UIStroke, gradient: UIGradient, mode: string } } = {}

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent: Instance, r: number)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, parent)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base, parent)
end

local function roleOf(c): string
	for tag, role in ROLE do
		if table.find(c.tags, tag) then
			return role
		end
	end
	return ""
end

-- The largest value of each stat across the roster, so the bars compare robots.
local function maxima(): { [string]: number }
	local m = { hp = 1, armor = 1, speed = 1, range = 1 }
	for _, c in Chassis.list do
		if not c.comingSoon then
			local card = Shop.card(Config, Stats, c)
			for k in m do
				m[k] = math.max(m[k], (card :: any)[k])
			end
		end
	end
	return m
end

local function statRow(parent: Instance, order: number, name: string, value: number, max: number)
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = order }, parent)
	label(row, { Size = UDim2.new(0, 48, 1, 0), Text = name, TextColor3 = MUTED, TextSize = 12 })
	local back = new("Frame", { Position = UDim2.new(0, 52, 0.5, -4), Size = UDim2.new(1, -96, 0, 8), BackgroundColor3 = Color3.fromRGB(50, 54, 64), BorderSizePixel = 0 }, row)
	corner(back, 4)
	local fill = new("Frame", { Size = UDim2.fromScale(math.clamp(value / max, 0.02, 1), 1), BackgroundColor3 = GOLD, BorderSizePixel = 0 }, back)
	corner(fill, 4)
	label(row, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 40, 1, 0), Text = tostring(math.floor(value + 0.5)), TextXAlignment = Enum.TextXAlignment.Right, TextSize = 12 })
end

-- The card's button: primary (gold, raised) to Buy, outline to Equip, flat when unavailable.
local function styleButton(entry, mode: string, text: string)
	entry.mode = mode
	local b = entry.button
	b.Text = text
	b.AutoButtonColor = false
	if mode == "buy" then
		b.BackgroundColor3, b.TextColor3, b.BackgroundTransparency = GOLD, INK, 0
		entry.stroke.Color, entry.stroke.Transparency = GOLD_DARK, 0
		entry.gradient.Enabled = true
	elseif mode == "equip" then
		b.BackgroundColor3, b.TextColor3, b.BackgroundTransparency = CARD, TEXT, 0
		entry.stroke.Color, entry.stroke.Transparency = GOLD, 0
		entry.gradient.Enabled = false
	else -- "equipped", "poor", "soon": not clickable
		b.BackgroundColor3, b.TextColor3, b.BackgroundTransparency = Color3.fromRGB(44, 48, 58), if mode == "equipped" then OK_GREEN else MUTED, 0
		entry.stroke.Color, entry.stroke.Transparency = OUTLINE, 0.4
		entry.gradient.Enabled = false
	end
end

local function buildCard(parent: Instance, c, order: number, maxes)
	local card = new("Frame", { BackgroundColor3 = CARD, LayoutOrder = order }, parent)
	corner(card, 10)
	new("UIStroke", { Color = OUTLINE, Transparency = 0.5 }, card)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10) }, card)
	local list = new("Frame", { Size = UDim2.new(1, 0, 1, -46), BackgroundTransparency = 1 }, card)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5) }, list)

	label(list, { Size = UDim2.new(1, 0, 0, 22), Text = c.name, Font = Enum.Font.GothamBold, TextSize = 20, LayoutOrder = 1 })
	local meta = `Class {c.class}` .. (if c.comingSoon then "" else ` · {roleOf(c)}`)
	label(list, { Size = UDim2.new(1, 0, 0, 14), Text = meta, TextColor3 = MUTED, TextSize = 12, LayoutOrder = 2 })
	local status = label(list, { Size = UDim2.new(1, 0, 0, 16), Text = "", TextColor3 = GOLD, Font = Enum.Font.GothamBold, TextSize = 13, LayoutOrder = 3 })

	local button = new("TextButton", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 38),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Text = "",
	}, card)
	corner(button, 8)
	local stroke = new("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 1.5 }, button)
	-- A light top edge and a darker bottom make the primary button read as pressable.
	local gradient = new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 205)),
	}, button)
	local entry = { button = button, status = status, stroke = stroke, gradient = gradient, mode = "soon" }

	if c.comingSoon then
		label(list, { Size = UDim2.new(1, 0, 0, 60), Text = "A new robot is on its way.", TextColor3 = MUTED, TextSize = 13, LayoutOrder = 4 })
		styleButton(entry, "soon", "Coming soon")
		cards[c.id] = entry
		return
	end

	local s = Shop.card(Config, Stats, c)
	for i, row in STAT_ROWS do
		statRow(list, 3 + i, row.label, (s :: any)[row.key], maxes[row.key])
	end
	label(list, { Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = s.attack, TextSize = 12, LayoutOrder = 9 })
	label(list, { Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, Text = c.blurb, TextColor3 = MUTED, TextSize = 12, LayoutOrder = 10 })

	button.MouseEnter:Connect(function()
		if entry.mode == "buy" then
			TweenService:Create(button, FAST, { BackgroundColor3 = GOLD_HOVER }):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		if entry.mode == "buy" then
			TweenService:Create(button, FAST, { BackgroundColor3 = GOLD }):Play()
		end
	end)
	button.Activated:Connect(function()
		if entry.mode == "buy" then
			Remotes.BuyRobot:FireServer(c.id)
		elseif entry.mode == "equip" then
			Remotes.EquipRobot:FireServer(c.id)
		end
	end)
	cards[c.id] = entry
end

local function build()
	gui = new("ScreenGui", { Name = "Garage", ResetOnSpawn = false, DisplayOrder = 5, IgnoreGuiInset = true, Enabled = false }, player:WaitForChild("PlayerGui"))
	overlay = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45 }, gui)
	local panel = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.94, 0.88),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.05,
	}, overlay)
	new("UISizeConstraint", { MaxSize = Vector2.new(1100, 720) }, panel)
	corner(panel, 12)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12) }, panel)

	label(panel, { Size = UDim2.new(1, -200, 0, 28), Text = "GARAGE", Font = Enum.Font.GothamBold, TextSize = 24 })
	label(panel, { Position = UDim2.fromOffset(0, 30), Size = UDim2.new(1, -200, 0, 16), Text = "Buy robots with coins. An equipped robot drives from your next spawn.", TextColor3 = MUTED, TextSize = 13 })
	coinLabel = label(panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -52, 0, 4), Size = UDim2.fromOffset(150, 26), Text = "0 coins", TextColor3 = GOLD, Font = Enum.Font.GothamBold, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Right })
	local close = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(40, 34),
		BackgroundColor3 = CARD,
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		TextColor3 = TEXT,
		Text = "X",
	}, panel)
	corner(close, 8)
	close.Activated:Connect(function()
		Garage.toggle(false)
	end)

	local scroll = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 56),
		Size = UDim2.new(1, 0, 1, -56),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	new("UIPadding", { PaddingRight = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, scroll)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(250, 330), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder }, scroll)

	local maxes = maxima()
	for i, c in Chassis.list do
		buildCard(scroll, c, i, maxes)
	end
end

-- Updates coins and every card from the latest server state.
function Garage.refresh()
	local s = ClientState.state
	if not gui or not s then
		return
	end
	local coins = s.coins or 0
	coinLabel.Text = `{coins} coins`
	for _, c in Chassis.list do
		local entry = cards[c.id]
		if entry and not c.comingSoon then
			local owned = s.owned and s.owned[c.id]
			if s.equipped == c.id then
				entry.status.Text, entry.status.TextColor3 = "Equipped", OK_GREEN
				styleButton(entry, "equipped", "Equipped")
			elseif owned then
				entry.status.Text, entry.status.TextColor3 = "Owned", TEXT
				styleButton(entry, "equip", "Equip")
			elseif coins >= c.price then
				entry.status.Text, entry.status.TextColor3 = `{c.price} coins`, GOLD
				styleButton(entry, "buy", `Buy for {c.price}`)
			else
				entry.status.Text, entry.status.TextColor3 = `{c.price} coins`, GOLD
				styleButton(entry, "poor", `Need {c.price - coins} more`)
			end
		end
	end
end

function Garage.toggle(open: boolean?)
	if not gui then
		build()
	end
	local show = if open == nil then not gui.Enabled else open
	gui.Enabled = show
	ClientState.menuOpen = show -- frees the mouse in third-person
	if show then
		Garage.refresh()
	end
end

function Garage.init()
	ClientState.actions.garage = Garage.toggle
	ClientState.actions.garageRefresh = Garage.refresh
end

return Garage
