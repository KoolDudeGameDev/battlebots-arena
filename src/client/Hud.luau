-- The HUD (GDD section 18): HP and XP bars, the non-blocking upgrade tray,
-- leaderboard, kill feed, death screen, comeback badge, skill and auto-fire
-- controls. Built in code; Phase 3 restyles it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local Upgrades = require(Shared.Upgrades)
local XpCurve = require(Shared.XpCurve)
local ClientState = require(script.Parent.ClientState)

local Hud = {
	aimTouchActive = nil :: (() -> (boolean, Vector2))?,
}

local player = Players.LocalPlayer
local PANEL = Color3.fromRGB(20, 22, 28)
local TEXT = Color3.fromRGB(240, 242, 246)
local MUTED = Color3.fromRGB(165, 170, 180)
local isTouch = ClientState.isTouch
local BODY = if isTouch then 16 else 14

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

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		TextSize = BODY,
		TextColor3 = TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base, parent)
end

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function fmt(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end

local gui: ScreenGui
local hpFill: Frame
local hpText: TextLabel
local xpFill: Frame
local levelText: TextLabel
local xpText: TextLabel
local comebackBadge: TextLabel
local armorBack: Frame
local armorFill: Frame
local armorText: TextLabel
local regenPill: TextLabel
local armorPill: TextLabel
local fortifyPill: TextLabel
local crosshair: Frame
local camButton: TextButton?
local fireButton: TextButton?
local tray: Frame
local cardHolder: Frame
local queueBadge: TextLabel
local collapsed: TextButton
local board: Frame
local feed: Frame
local deathPanel: Frame
local deathTitle: TextLabel
local deathInfo: TextLabel
local deathTimer: TextLabel
local skillLabel: TextLabel
local autoLabel: TextLabel
local skillButton: TextButton?
local autoButton: TextButton?
local stickRing: Frame

local shownOfferId: number? = nil
local pickedOfferId: number? = nil
local offerShownAt = 0
local trayCollapsed = false
local deathRespawnAt: number? = nil

-- Bars --------------------------------------------------------------------------

local function buildBars()
	local bars = new("Frame", {
		Name = "Bars",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(0.5, 0, 0, 44),
		BackgroundTransparency = 1,
	}, gui)
	new("UISizeConstraint", { MinSize = Vector2.new(260, 44), MaxSize = Vector2.new(440, 44) }, bars)

	local hpBack = new("Frame", { Size = UDim2.new(1, 0, 0, 20), BackgroundColor3 = PANEL, BackgroundTransparency = 0.2 }, bars)
	corner(hpBack, 6)
	hpFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(90, 210, 110) }, hpBack)
	corner(hpFill, 6)
	hpText = text(hpBack, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, Text = "100 / 100", ZIndex = 2 })

	local xpBack = new("Frame", { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 16), BackgroundColor3 = PANEL, BackgroundTransparency = 0.2 }, bars)
	corner(xpBack, 6)
	xpFill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Color3.fromRGB(110, 170, 255) }, xpBack)
	corner(xpFill, 6)
	levelText = text(xpBack, { Position = UDim2.fromOffset(8, 0), Size = UDim2.fromScale(0.5, 1), Font = Enum.Font.GothamBold, Text = "Lv 0", TextSize = 13, ZIndex = 2 })
	xpText = text(xpBack, { Position = UDim2.new(0.5, -8, 0, 0), Size = UDim2.fromScale(0.5, 1), TextXAlignment = Enum.TextXAlignment.Right, Text = "", TextSize = 13, ZIndex = 2 })

	comebackBadge = text(bars, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(1, 8, 1, 0),
		Size = UDim2.fromOffset(150, 22),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(235, 130, 40),
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "COMEBACK x2.5",
		Visible = false,
	})
	corner(comebackBadge, 11)

	-- Armor bar sits above health and only shows once you have armor (D33).
	armorBack = new("Frame", { Position = UDim2.fromOffset(0, -14), Size = UDim2.new(1, 0, 0, 10), BackgroundColor3 = PANEL, BackgroundTransparency = 0.2, Visible = false }, bars)
	corner(armorBack, 5)
	armorFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(110, 170, 255) }, armorBack)
	corner(armorFill, 5)
	armorText = text(armorBack, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 10, Text = "", ZIndex = 2 })

	-- Booster timers (Regen Pod, Armor Pod), stacked left of the bars.
	local pills = new("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0, -8, 1, 0),
		Size = UDim2.fromOffset(136, 76),
		BackgroundTransparency = 1,
	}, bars)
	new("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, pills)
	local function pill(color: Color3): TextLabel
		local p = text(pills, {
			Size = UDim2.fromOffset(136, 22),
			BackgroundTransparency = 0,
			BackgroundColor3 = color,
			Font = Enum.Font.GothamBold,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Center,
			Visible = false,
		})
		corner(p, 11)
		return p
	end
	regenPill = pill(Color3.fromRGB(70, 170, 70))
	armorPill = pill(Color3.fromRGB(60, 130, 210))
	fortifyPill = pill(Color3.fromRGB(200, 80, 160))
end

-- Upgrade tray --------------------------------------------------------------------

local function kindText(card): string
	if card.kind == "new" then
		return "NEW"
	elseif card.kind == "replace" then
		local old = card.replaces and Upgrades.byId[card.replaces]
		return "Replaces " .. (if old then old.name else "skill")
	elseif card.kind == "fallback" then
		return "Backup"
	elseif card.category == "Stat" then
		return "Stack " .. card.rank
	end
	return "Rank " .. card.rank
end

local function buildTray()
	tray = new("Frame", {
		Name = "Tray",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -86),
		Size = UDim2.fromOffset(470, 128),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)
	cardHolder = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, tray)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, cardHolder)
	queueBadge = text(tray, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 6, 0, 0),
		Size = UDim2.fromOffset(40, 24),
		BackgroundTransparency = 0,
		BackgroundColor3 = Color3.fromRGB(235, 80, 70),
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 3,
		Visible = false,
	})
	corner(queueBadge, 12)

	collapsed = new("TextButton", {
		Name = "LevelUp",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -86),
		Size = UDim2.fromOffset(190, 40),
		BackgroundColor3 = Color3.fromRGB(70, 140, 255),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = TEXT,
		Text = "LEVEL UP",
		Visible = false,
		AutoButtonColor = true,
	}, gui)
	corner(collapsed, 20)
	collapsed.Activated:Connect(function()
		trayCollapsed = false
		offerShownAt = os.clock()
	end)
end

local function fillTray(offer)
	for _, child in cardHolder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i, card in offer.cards do
		local color = rgb(Config.RarityColors[card.rarity] or Config.RarityColors.Common)
		local button = new("TextButton", {
			LayoutOrder = i,
			Size = UDim2.fromOffset(150, 128),
			BackgroundColor3 = PANEL,
			BackgroundTransparency = 0.08,
			Text = "",
			AutoButtonColor = true,
		}, cardHolder)
		corner(button, 10)
		new("UIStroke", { Color = color, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, button)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}, button)
		text(button, { Size = UDim2.new(1, 0, 0, 14), Text = string.upper(card.category) .. " · " .. card.rarity, TextSize = 11, TextColor3 = color, Font = Enum.Font.GothamBold })
		text(button, { Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 20), Text = card.name, TextSize = 16, Font = Enum.Font.GothamBold, TextTruncate = Enum.TextTruncate.AtEnd })
		text(button, { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 16), Text = kindText(card), TextSize = 13, TextColor3 = MUTED })
		text(button, { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 1, -54), Text = card.text, TextSize = 13, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
		if not isTouch then
			text(button, { AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(24, 16), Text = "[" .. i .. "]", TextSize = 12, TextColor3 = MUTED, TextXAlignment = Enum.TextXAlignment.Right })
		end
		button.Activated:Connect(function()
			ClientState.actions.pick(i)
		end)
	end
end

function Hud.pick(index: number)
	local s = ClientState.state
	if not s or not s.offer or not s.offer.cards[index] then
		return
	end
	if s.offer.id == pickedOfferId then
		return -- already picked; waiting for the next offer
	end
	pickedOfferId = s.offer.id
	Remotes.PickUpgrade:FireServer(s.offer.id, index)
	tray.Visible = false
	collapsed.Visible = false
end

local function updateTray(s)
	local offer = s.offer
	if not offer or not s.alive then
		tray.Visible = false
		collapsed.Visible = false
		return
	end
	if offer.id ~= shownOfferId then
		shownOfferId = offer.id
		fillTray(offer)
		offerShownAt = os.clock()
		trayCollapsed = false
	end
	local queued = (s.pending or 1) - 1
	queueBadge.Visible = queued > 0
	queueBadge.Text = "+" .. queued
	collapsed.Text = "LEVEL UP (" .. (s.pending or 1) .. ")"
end

-- Leaderboard and kill feed -----------------------------------------------------

local function buildBoard()
	board = new("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(220, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
	}, gui)
	corner(board, 8)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, board)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, board)

	feed = new("Frame", {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(300, 120),
		BackgroundTransparency = 1,
	}, gui)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, feed)
end

local function updateBoard(rows)
	for _, child in board:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	text(board, { LayoutOrder = 0, Size = UDim2.new(1, 0, 0, 18), Text = "LEADERBOARD", Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = MUTED })
	local myRank = nil
	for i, row in rows do
		if row.userId == player.UserId then
			myRank = i
		end
	end
	local function line(i: number, row, order: number)
		local mine = row.userId == player.UserId
		text(board, {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 18),
			Text = string.format("%d. %s  ·  Lv %d  ·  %s", i, row.name, row.level, fmt(row.score)),
			TextSize = 13,
			Font = if mine then Enum.Font.GothamBold else Enum.Font.GothamMedium,
			TextColor3 = if mine then Color3.fromRGB(255, 220, 110) else TEXT,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end
	for i = 1, math.min(5, #rows) do
		line(i, rows[i], i)
	end
	if myRank and myRank > 5 then
		line(myRank, rows[myRank], 6)
	end
end

local function addFeed(killerName: string, victimName: string, victimLevel: number)
	local entry = text(feed, {
		LayoutOrder = math.floor(os.clock() * 1000) % 1e9,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 0.35,
		BackgroundColor3 = PANEL,
		Text = string.format("  %s destroyed %s (Lv %d)", killerName, victimName, victimLevel),
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	corner(entry, 6)
	local entries = {}
	for _, c in feed:GetChildren() do
		if c:IsA("TextLabel") then
			table.insert(entries, c)
		end
	end
	table.sort(entries, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #entries > 4 do
		local oldest = table.remove(entries, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(5, function()
		if entry.Parent then
			entry:Destroy()
		end
	end)
end

-- Death screen ------------------------------------------------------------------

local function buildDeath()
	deathPanel = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(340, 130),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.1,
		Visible = false,
	}, gui)
	corner(deathPanel, 12)
	deathTitle = text(deathPanel, { Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBlack, TextSize = 24, TextColor3 = Color3.fromRGB(255, 110, 90), Text = "DESTROYED" })
	deathInfo = text(deathPanel, { Position = UDim2.fromOffset(0, 50), Size = UDim2.new(1, 0, 0, 40), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, Text = "" })
	deathTimer = text(deathPanel, { Position = UDim2.fromOffset(0, 96), Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = MUTED, Text = "" })
end

-- Skill and auto-fire controls --------------------------------------------------

local function skillName(id: string?): string
	local def = id and Upgrades.byId[id]
	return if def then def.name else "No skill"
end

-- Coins and the Garage button (D73), top centre (the kill feed is top left).
local coinText: TextLabel
local coinScale: UIScale
local lastCoins: number? = nil

local function buildWallet()
	local bar = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
	}, gui)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Center }, bar)
	local pill = new("Frame", { Size = UDim2.fromOffset(0, 32), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = PANEL, BackgroundTransparency = 0.25, LayoutOrder = 1 }, bar)
	corner(pill, 16)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, pill)
	coinScale = new("UIScale", {}, pill)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, pill)
	-- A gold coin glyph: rim, bright field and a darker centre (D78).
	local glyph = new("Frame", { Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Color3.fromRGB(255, 206, 72), LayoutOrder = 0 }, pill)
	corner(glyph, 9)
	new("UIStroke", { Color = Color3.fromRGB(176, 120, 24), Thickness = 2 }, glyph)
	local dot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = Color3.fromRGB(214, 158, 36) }, glyph)
	corner(dot, 4)
	coinText = text(pill, { Size = UDim2.fromOffset(0, 32), AutomaticSize = Enum.AutomaticSize.X, Text = "0 coins", TextColor3 = Color3.fromRGB(255, 196, 40), Font = Enum.Font.GothamBold, LayoutOrder = 1 })
	local garage: TextButton = new("TextButton", {
		Size = UDim2.fromOffset(if isTouch then 104 else 120, 32),
		BackgroundColor3 = Color3.fromRGB(255, 196, 40),
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(28, 22, 6),
		Text = if isTouch then "GARAGE" else "GARAGE (G)",
		LayoutOrder = 2,
	}, bar)
	corner(garage, 16)
	new("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Color3.fromRGB(150, 100, 0), Thickness = 1.5 }, garage)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 205)) }, garage)
	garage.Activated:Connect(function()
		if ClientState.actions.garage then
			ClientState.actions.garage()
		end
	end)
end

local function updateWallet(coins: number)
	coinText.Text = fmt(coins) .. " coins"
	if lastCoins and coins > lastCoins then
		-- A quick pop when coins come in (under 200 ms).
		coinScale.Scale = 1.15
		game:GetService("TweenService"):Create(coinScale, TweenInfo.new(0.18), { Scale = 1 }):Play()
	end
	lastCoins = coins
end

-- Boss HP bar and the centre banner (Phase 4b, D74) ---------------------------------

local function buildBoss()
	local CollectionService = game:GetService("CollectionService")
	local TweenService = game:GetService("TweenService")
	local frame = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 50),
		Size = UDim2.fromOffset(if isTouch then 300 else 380, 40),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = false,
	}, gui)
	corner(frame, 8)
	local name = text(frame, { Position = UDim2.fromOffset(10, 2), Size = UDim2.new(1, -20, 0, 18), Text = "", Font = Enum.Font.GothamBold, TextSize = 14 })
	local back = new("Frame", { Position = UDim2.fromOffset(10, 22), Size = UDim2.new(1, -20, 0, 10), BackgroundColor3 = Color3.fromRGB(50, 30, 30), BorderSizePixel = 0 }, frame)
	corner(back, 5)
	local fill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.fromRGB(230, 70, 50), BorderSizePixel = 0 }, back)
	corner(fill, 5)
	RunService.Heartbeat:Connect(function()
		local boss = CollectionService:GetTagged("Boss")[1]
		frame.Visible = boss ~= nil
		if boss then
			local hp = (boss:GetAttribute("HP") or 0) :: number
			local max = math.max(1, (boss:GetAttribute("MaxHP") or 1) :: number)
			name.Text = `{boss:GetAttribute("BossName") or "Boss"}   {fmt(hp)} / {fmt(max)}`
			fill.Size = UDim2.fromScale(math.clamp(hp / max, 0, 1), 1)
		end
	end)

	local banner = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.28),
		Size = UDim2.new(0.8, 0, 0, 40),
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = if isTouch then 20 else 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	-- The map flow (D81): which map is up and how long it lasts.
	local Workspace = game:GetService("Workspace")
	local mapLabel = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 94),
		Size = UDim2.new(0.6, 0, 0, 22),
		Text = "",
		Font = Enum.Font.GothamBold,
		TextSize = if isTouch then 14 else 17,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.5,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	local function clock(seconds: number): string
		local s2 = math.max(0, math.floor(seconds))
		return string.format("%d:%02d", s2 // 60, s2 % 60)
	end
	RunService.Heartbeat:Connect(function()
		local phase = Workspace:GetAttribute("MapPhase") or "grassland"
		local left = ((Workspace:GetAttribute("MapEndsAt") or 0) :: number) - Workspace:GetServerTimeNow()
		local display = Workspace:GetAttribute("MapDisplay") or ""
		local boss = Workspace:GetAttribute("MapBoss") or "Boss"
		mapLabel.Text = if phase == "warning" then `{boss} approaches · {clock(left)}`
			elseif phase == "arena" then `{display} · {boss} leaves in {clock(left)}`
			elseif phase == "victory" then `Victory! Back to the overworld in {clock(left)}`
			elseif phase == "biome" then `{display} · {clock(left)}`
			elseif phase == "revert" then `{display} fades in {clock(left)}`
			else ""
	end)

	-- The swap fade (D81): to the new map's colour and back, 0.5 s each way.
	local fade = new("Frame", {
		Position = UDim2.fromScale(-0.1, -0.1),
		Size = UDim2.fromScale(1.2, 1.2),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 50,
	}, gui)
	local fadeId = 0
	local function fadeIn(id: number)
		if fadeId == id then
			TweenService:Create(fade, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		end
	end
	Remotes.MapSwap.OnClientEvent:Connect(function(color)
		fadeId += 1
		local id = fadeId
		fade.BackgroundColor3 = if typeof(color) == "Color3" then color else Color3.new(0, 0, 0)
		TweenService:Create(fade, TweenInfo.new(0.5), { BackgroundTransparency = 0 }):Play()
		local conn
		conn = Workspace:GetAttributeChangedSignal("Map"):Connect(function()
			conn:Disconnect()
			task.delay(0.15, fadeIn, id)
		end)
		task.delay(2, function() -- never stay dark, even if the map didn't change
			conn:Disconnect()
			fadeIn(id)
		end)
	end)

	local shownAt = 0
	Remotes.Announce.OnClientEvent:Connect(function(message)
		if type(message) ~= "string" then
			return
		end
		banner.Text = message
		banner.TextTransparency, banner.TextStrokeTransparency = 0, 0.4
		shownAt = os.clock()
		local mine = shownAt
		task.delay(4, function()
			if shownAt == mine then
				TweenService:Create(banner, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end)
	end)
end

local function buildControls()
	local hint = new("Frame", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -14),
		Size = UDim2.fromOffset(200, 112),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = not isTouch,
	}, gui)
	corner(hint, 8)
	skillLabel = text(hint, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, Text = "SPACE · No skill" })
	autoLabel = text(hint, { Position = UDim2.fromOffset(10, 25), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "E · Auto-fire OFF" })
	text(hint, { Position = UDim2.fromOffset(10, 46), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "V · Switch camera" })
	text(hint, { Position = UDim2.fromOffset(10, 67), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "1 / 2 / 3 · Pick upgrade" })
	text(hint, { Position = UDim2.fromOffset(10, 88), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "Hold ALT · Free the mouse" })

	-- Third-person crosshair (D37)
	crosshair = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.2,
		Visible = false,
	}, gui)
	corner(crosshair, 5)
	new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1.5, Transparency = 0.3 }, crosshair)

	if isTouch then
		local skill: TextButton = new("TextButton", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -28, 1, -150),
			Size = UDim2.fromOffset(84, 84),
			BackgroundColor3 = Color3.fromRGB(60, 120, 230),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextWrapped = true,
			TextColor3 = TEXT,
			Text = "SKILL",
		}, gui)
		corner(skill, 42)
		skill.Activated:Connect(function()
			ClientState.actions.useSkill()
		end)
		skillButton = skill
		local auto: TextButton = new("TextButton", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -126, 1, -100),
			Size = UDim2.fromOffset(64, 64),
			BackgroundColor3 = PANEL,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextWrapped = true,
			TextColor3 = TEXT,
			Text = "AUTO\nOFF",
		}, gui)
		corner(auto, 32)
		auto.Activated:Connect(function()
			ClientState.actions.toggleAuto()
		end)
		autoButton = auto

		local cam: TextButton = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -240, 0, 12),
			Size = UDim2.fromOffset(56, 40),
			BackgroundColor3 = PANEL,
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = TEXT,
			Text = "CAM",
		}, gui)
		corner(cam, 10)
		cam.Activated:Connect(function()
			ClientState.actions.toggleCam()
		end)
		camButton = cam

		-- Third-person on phone: the right side turns the camera, so firing needs its own button.
		local fire: TextButton = new("TextButton", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -28, 1, -250),
			Size = UDim2.fromOffset(84, 84),
			BackgroundColor3 = Color3.fromRGB(220, 70, 60),
			Font = Enum.Font.GothamBlack,
			TextSize = 16,
			TextColor3 = TEXT,
			Text = "FIRE",
			Visible = false,
		}, gui)
		corner(fire, 42)
		fire.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				ClientState.fireButtonHeld = true
			end
		end)
		fire.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
				ClientState.fireButtonHeld = false
			end
		end)
		fireButton = fire
	end

	stickRing = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(110, 110),
		BackgroundTransparency = 0.85,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Visible = false,
	}, gui)
	corner(stickRing, 55)
	new("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.5, Thickness = 2 }, stickRing)
end

-- Per-frame updates -------------------------------------------------------------

local function perFrame()
	local s = ClientState.state
	local t = Workspace:GetServerTimeNow()

	-- HP and armor from the robot's attributes (smooth), max HP from state.
	local character = player.Character
	if s and character then
		local hp = character:GetAttribute("HP") or 0
		local maxHp = s.maxHp or 100
		hpFill.Size = UDim2.fromScale(math.clamp(hp / maxHp, 0, 1), 1)
		hpText.Text = string.format("%d / %d", hp, maxHp)

		local armor = character:GetAttribute("Armor") or 0
		local maxArmor = character:GetAttribute("MaxArmor") or 0
		armorBack.Visible = armor > 0 or maxArmor > 0
		armorFill.Size = UDim2.fromScale(math.clamp(armor / math.max(maxArmor, armor, 1), 0, 1), 1)
		armorText.Text = string.format("ARMOR %d", armor)

		local regenLeft = (character:GetAttribute("RegenUntil") or 0) - t
		regenPill.Visible = regenLeft > 0
		regenPill.Text = string.format("REGEN %ds", math.ceil(regenLeft))
		local armorLeft = (character:GetAttribute("TempArmorUntil") or 0) - t
		armorPill.Visible = armorLeft > 0
		armorPill.Text = string.format("ARMOR+ %ds", math.ceil(armorLeft))
		local fortifyLeft = (character:GetAttribute("FortifyUntil") or 0) - t
		fortifyPill.Visible = fortifyLeft > 0
		-- Fortify is temporary: the number is how long the extra max HP lasts.
		fortifyPill.Text = string.format("+%d MAX HP · %ds", Config.Pods.fortify.bonusHp, math.ceil(fortifyLeft))
	end

	-- Camera mode
	local third = ClientState.camMode == "third"
	crosshair.Visible = third
	if fireButton then
		fireButton.Visible = third
		if not third then
			ClientState.fireButtonHeld = false
		end
	end
	if camButton then
		camButton.Text = if third then "TOP" else "3RD"
	end

	-- Tray collapse after TrayCollapseAfter seconds untouched.
	if s and s.offer and s.alive and shownOfferId == s.offer.id then
		if not trayCollapsed and os.clock() - offerShownAt > Config.TrayCollapseAfter then
			trayCollapsed = true
		end
		local waitingForServer = s.offer.id == pickedOfferId
		tray.Visible = not trayCollapsed and not waitingForServer
		collapsed.Visible = trayCollapsed and not waitingForServer
	end

	-- Skill cooldown
	if s then
		local ready = math.max(s.skillReadyAt or 0, ClientState.localSkillReadyAt)
		local remaining = math.max(0, ready - t)
		local name = skillName(s.skill)
		local cd = if s.skill and remaining > 0 then string.format("  (%.1fs)", remaining) else ""
		skillLabel.Text = "SPACE · " .. (if s.skillNote then s.skillNote else name .. cd)
		if skillButton then
			skillButton.Text = if s.skillNote then "HEAL" elseif s.skill then (if remaining > 0 then string.format("%.1f", remaining) else name) else "SKILL"
			skillButton.BackgroundTransparency = if s.skill and remaining <= 0 then 0 else 0.5
		end
	end
	local auto = ClientState.autoFire
	autoLabel.Text = "E · Auto-fire " .. (if auto then "ON" else "OFF")
	autoLabel.TextColor3 = if auto then Color3.fromRGB(120, 230, 140) else MUTED
	if autoButton then
		autoButton.Text = "AUTO\n" .. (if auto then "ON" else "OFF")
		autoButton.BackgroundColor3 = if auto then Color3.fromRGB(60, 170, 90) else PANEL
	end

	-- Death countdown
	if deathRespawnAt then
		local left = math.max(0, deathRespawnAt - t)
		deathTimer.Text = string.format("Respawning in %.0f…", math.ceil(left))
	end

	-- Aim stick ring
	local active, origin = false, Vector2.zero
	if Hud.aimTouchActive then
		active, origin = Hud.aimTouchActive()
	end
	stickRing.Visible = active
	if active then
		stickRing.Position = UDim2.fromOffset(origin.X, origin.Y)
	end
end

local lastSkill: string? = nil
local function onState(s)
	if s.skill ~= lastSkill then
		ClientState.localSkillReadyAt = 0 -- a new skill has no cooldown yet
		lastSkill = s.skill
	end
	ClientState.state = s
	updateWallet(s.coins or 0)
	if ClientState.actions.garageRefresh then
		ClientState.actions.garageRefresh()
	end
	if s.xpNeed and s.xpNeed > 0 then
		xpFill.Size = UDim2.fromScale(math.clamp(s.xp / s.xpNeed, 0, 1), 1)
		xpText.Text = fmt(s.xp) .. " / " .. fmt(s.xpNeed)
	else
		xpFill.Size = UDim2.fromScale(1, 1)
		xpText.Text = "MAX"
	end
	local nextOffer = XpCurve.nextOfferLevel(s.level)
	levelText.Text = "Lv " .. s.level .. (if nextOffer then "   ·   upgrade at Lv " .. nextOffer else "")
	comebackBadge.Visible = s.comeback ~= nil
	if s.comeback then
		comebackBadge.Text = string.format("COMEBACK x%.1f", s.comeback.mult)
	end
	if s.alive then
		deathPanel.Visible = false
		deathRespawnAt = nil
	end
	updateTray(s)
end

function Hud.init(aimTouchActive)
	Hud.aimTouchActive = aimTouchActive
	for _, t in { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Health, Enum.CoreGuiType.Backpack, Enum.CoreGuiType.EmotesMenu } do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(t, false)
		end)
	end
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCore("ResetButtonCallback", false)
			end)
			if ok then
				break
			end
			task.wait(0.5)
		end
	end)

	gui = new("ScreenGui", { Name = "Hud", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	buildBars()
	buildTray()
	buildBoard()
	buildDeath()
	buildControls()
	buildWallet()
	buildBoss()

	ClientState.actions.pick = Hud.pick

	Remotes.State.OnClientEvent:Connect(onState)
	Remotes.Leaderboard.OnClientEvent:Connect(updateBoard)
	Remotes.KillFeed.OnClientEvent:Connect(addFeed)
	Remotes.Death.OnClientEvent:Connect(function(info)
		deathPanel.Visible = true
		tray.Visible = false
		collapsed.Visible = false
		deathTitle.Text = "DESTROYED"
		deathInfo.Text = string.format("by %s (Lv %d)\nYou reached Lv %d · Score %s", info.killerName, info.killerLevel, info.level, fmt(info.score))
		deathRespawnAt = info.respawnAt
	end)
	-- Debug command output and other system lines appear in chat.
	Remotes.Notice.OnClientEvent:Connect(function(message)
		if type(message) ~= "string" then
			return
		end
		pcall(function()
			local channels = TextChatService:WaitForChild("TextChannels", 5)
			local general = channels and channels:FindFirstChild("RBXGeneral") :: TextChannel?
			if general then
				general:DisplaySystemMessage(message)
			end
		end)
	end)
	Remotes.Aims.OnClientEvent:Connect(function(flat)
		for i = 1, #flat - 1, 2 do
			ClientState.aims[flat[i]] = flat[i + 1]
		end
	end)

	RunService.RenderStepped:Connect(perFrame)
end

return Hud
