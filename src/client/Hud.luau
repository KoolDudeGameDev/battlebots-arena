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
local HudLayout = require(script.Parent.HudLayout)

local Hud = {
	aimTouchActive = nil :: (() -> (boolean, Vector2))?,
}

local player = Players.LocalPlayer
local PANEL = Color3.fromRGB(20, 22, 28)
local TEXT = Color3.fromRGB(240, 242, 246)
local MUTED = Color3.fromRGB(165, 170, 180)
local isTouch = ClientState.isTouch
local BODY = if isTouch then 16 else 14
-- Sizes that depend only on the device kind come from the layout plan (D91);
-- positions come from it too, in applyLayout, whenever the screen size changes.
local SIZES = HudLayout.sizes(isTouch)
local BOARD_ROWS = SIZES.boardRows

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
local armorRow: Frame
local armorFill: Frame
local armorText: TextLabel
local regenPill: TextLabel
local armorPill: TextLabel
local fortifyPill: TextLabel
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
local camHint: TextLabel
local tipLimit: UISizeConstraint
-- The view tip (D87): shown on your first spawn until you switch views once.
local viewTip: TextLabel
local tipShown = false
local camSwitched = false
local startMode = ClientState.camMode
local skillButton: TextButton?
local autoButton: TextButton?
local stickRing: Frame

local shownOfferId: number? = nil
local pickedOfferId: number? = nil
local offerShownAt = 0
local trayCollapsed = false
local deathRespawnAt: number? = nil

-- Bars --------------------------------------------------------------------------

-- Top left (D87, D88): health, armor under it, XP, with no panel behind them. Under
-- them: timed boosts, then the kill feed.
local PANEL_W = SIZES.panelW
local leftColumn: Frame
local chipsFrame: Frame

local function barRow(parent: Instance, order: number, glyph: string, height: number, color: Color3): (Frame, Frame, Frame)
	local row = new("Frame", { LayoutOrder = order, Size = UDim2.new(1, 0, 0, height), BackgroundTransparency = 1 }, parent)
	text(row, { Size = UDim2.fromOffset(20, height), Text = glyph, TextSize = math.min(16, height + 2), TextXAlignment = Enum.TextXAlignment.Center })
	local back = new("Frame", { Position = UDim2.fromOffset(26, 0), Size = UDim2.new(1, -26, 1, 0), BackgroundColor3 = Color3.fromRGB(8, 9, 12), BackgroundTransparency = 0.3 }, row)
	corner(back, height // 2)
	local fill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = color }, back)
	corner(fill, height // 2)
	return row, back, fill
end

local function buildBars()
	leftColumn = new("Frame", {
		Name = "Build",
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(PANEL_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, gui)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, leftColumn)

	local panel = new("Frame", { LayoutOrder = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, leftColumn)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5) }, panel)

	local _hpRow, hpBack
	_hpRow, hpBack, hpFill = barRow(panel, 1, "❤️", 20, Color3.fromRGB(90, 210, 110))
	hpText = text(hpBack, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 13, Text = "100 / 100", TextStrokeTransparency = 0.6, ZIndex = 2 })

	-- Armor sits under health and only shows once you have armor (D33, D87).
	local armorBar
	armorRow, armorBar, armorFill = barRow(panel, 2, "🛡️", 12, Color3.fromRGB(110, 170, 255))
	armorRow.Visible = false
	armorText = text(armorBar, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBold, TextSize = 10, Text = "", ZIndex = 2 })

	local _xpRow, xpBack
	_xpRow, xpBack, xpFill = barRow(panel, 3, "⭐", 16, Color3.fromRGB(240, 190, 60))
	xpFill.Size = UDim2.fromScale(0, 1)
	-- Level on the left 60%, XP on the right 40%, so the two never run into each other.
	levelText = text(xpBack, { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(0.6, -8, 1, 0), Font = Enum.Font.GothamBold, Text = "Lv 0", TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 0.6, ZIndex = 2 })
	xpText = text(xpBack, { Position = UDim2.fromScale(0.6, 0), Size = UDim2.new(0.4, -8, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, Text = "", TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextStrokeTransparency = 0.6, ZIndex = 2 })

	-- Status chips (comeback, Regen Pod, Armor Pod, Fortify), under the bars.
	local chips = new("Frame", { Name = "Chips", LayoutOrder = 2, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, leftColumn)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, chips)
	local function chip(order: number, color: Color3): TextLabel
		local p = text(chips, {
			LayoutOrder = order,
			Size = UDim2.fromOffset(SIZES.chipW, 22),
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
	comebackBadge = chip(1, Color3.fromRGB(235, 130, 40))
	regenPill = chip(2, Color3.fromRGB(70, 170, 70))
	armorPill = chip(3, Color3.fromRGB(60, 130, 210))
	fortifyPill = chip(4, Color3.fromRGB(200, 80, 160))
	chipsFrame = chips
end

-- Upgrade tray --------------------------------------------------------------------

local function kindText(card): string
	if card.kind == "new" then
		return "NEW"
	elseif card.kind == "replace" then
		local old = card.replaces and Upgrades.byId[card.replaces]
		return "Replaces " .. (if old then old.name else "skill")
	elseif card.kind == "fallback" then
		return "Bonus"
	elseif card.category == "Stat" then
		return "Stack " .. card.rank
	end
	return "Rank " .. card.rank
end

-- Upgrade cards sit at the bottom; HudLayout places them (D91).
local CARD_W = SIZES.cardW

local function buildTray()
	tray = new("Frame", {
		Name = "Tray",
		Size = UDim2.fromOffset(CARD_W * 3 + 20, 128),
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
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 4), -- inside the tray, so it stays in the plan's rect
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
		Size = UDim2.fromOffset(190, 44),
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
			Size = UDim2.fromOffset(CARD_W, 128),
			BackgroundColor3 = PANEL,
			BackgroundTransparency = 0.08,
			Text = "",
			AutoButtonColor = true,
		}, cardHolder)
		corner(button, 10)
		new("UIStroke", { Color = color, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, button)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}, button)
		text(button, { Size = UDim2.new(1, 0, 0, 14), Text = string.upper(card.category) .. (if isTouch then "" else " · " .. card.rarity), TextSize = 11, TextColor3 = color, Font = Enum.Font.GothamBold, TextTruncate = Enum.TextTruncate.AtEnd })
		text(button, { Position = UDim2.fromOffset(0, 16), Size = UDim2.new(1, 0, 0, 20), Text = card.name, TextSize = if isTouch then 14 else 16, Font = Enum.Font.GothamBold, TextTruncate = Enum.TextTruncate.AtEnd })
		text(button, { Position = UDim2.fromOffset(0, 36), Size = UDim2.new(1, 0, 0, 16), Text = kindText(card), TextSize = 12, TextColor3 = MUTED })
		-- Long card text shrinks to fit rather than spilling out of the card.
		local about = text(button, { Position = UDim2.fromOffset(0, 54), Size = UDim2.new(1, 0, 1, if isTouch then -54 else -70), Text = card.text, TextScaled = true, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
		new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 9 }, about)
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

local boardRows: Frame
local boardGui: ScreenGui
local boardOpen = true

local function setBoardOpen(open: boolean)
	boardOpen = open
	if isTouch then
		boardRows.Visible = open -- phones keep the header to tap it open again
	else
		board.Visible = open
	end
end

local function buildBoard()
	-- Like Roblox's own player list (D88): top right, level with the Roblox buttons
	-- (its own ScreenGui ignores the top bar, but keeps clear of a phone's notch).
	-- Tab shows and hides it; on phones, tapping its header does.
	boardGui = new("ScreenGui", { Name = "Board", ResetOnSpawn = false, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets }, gui.Parent)
	board = new("Frame", {
		Size = UDim2.fromOffset(if isTouch then 200 else 220, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
	}, boardGui)
	corner(board, 8)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, board)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, board)
	local header: TextButton = new("TextButton", {
		LayoutOrder = 0,
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = if isTouch then "LEADERBOARD" else "LEADERBOARD  ·  Tab",
	}, board)
	header.Activated:Connect(function()
		setBoardOpen(not boardOpen)
	end)
	boardRows = new("Frame", { LayoutOrder = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, board)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, boardRows)
	game:GetService("UserInputService").InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.Tab then
			setBoardOpen(not boardOpen)
		end
	end)

	-- The kill feed runs under the build panel and its boost chips (D87).
	feed = new("Frame", {
		LayoutOrder = 3,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, leftColumn)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, feed)
end

local function updateBoard(rows)
	for _, child in boardRows:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	local myRank = nil
	for i, row in rows do
		if row.userId == player.UserId then
			myRank = i
		end
	end
	local function line(i: number, row, order: number)
		local mine = row.userId == player.UserId
		text(boardRows, {
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 18),
			Text = string.format("%d. %s  ·  Lv %d  ·  %s pts", i, row.name, row.level, fmt(row.score)),
			TextSize = 13,
			Font = if mine then Enum.Font.GothamBold else Enum.Font.GothamMedium,
			TextColor3 = if mine then Color3.fromRGB(255, 220, 110) else TEXT,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end
	for i = 1, math.min(BOARD_ROWS, #rows) do
		line(i, rows[i], i)
	end
	if myRank and myRank > BOARD_ROWS then
		line(myRank, rows[myRank], BOARD_ROWS + 1)
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
	while #entries > SIZES.feedRows do -- phones: the lower left is the move stick
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

local walletBar: Frame

local function buildWallet()
	local bar = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
	}, gui)
	walletBar = bar
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
	coinText = text(pill, { Size = UDim2.fromOffset(0, 32), AutomaticSize = Enum.AutomaticSize.X, Text = if isTouch then "0" else "0 coins", TextColor3 = Color3.fromRGB(255, 196, 40), Font = Enum.Font.GothamBold, LayoutOrder = 1 })
	local garage: TextButton = new("TextButton", {
		Size = UDim2.fromOffset(if isTouch then 96 else 120, 32),
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
	-- Phones: the coin icon says "coins", and 10,000 and up shows as "12.3k" so the pill
	-- stays inside its HudLayout slot (D91).
	coinText.Text = if not isTouch then fmt(coins) .. " coins"
		elseif coins >= 10000 then string.format("%.1fk", math.floor(coins / 100) / 10)
		else fmt(coins)
	if lastCoins and coins > lastCoins then
		-- A quick pop when coins come in (under 200 ms).
		coinScale.Scale = 1.15
		game:GetService("TweenService"):Create(coinScale, TweenInfo.new(0.18), { Scale = 1 }):Play()
	end
	lastCoins = coins
end

-- Boss HP bar and the centre banner (Phase 4b, D74) ---------------------------------

local bossFrame: Frame
local banner: TextLabel
local bannerUntil = 0 -- an announcement holds the message slot until then
local mapLabel: TextLabel

local function buildBoss()
	local CollectionService = game:GetService("CollectionService")
	local TweenService = game:GetService("TweenService")
	local frame = new("Frame", {
		Size = UDim2.fromOffset(380, 40),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = false,
	}, gui)
	corner(frame, 8)
	bossFrame = frame
	local name = text(frame, { Position = UDim2.fromOffset(10, 2), Size = UDim2.new(1, -20, 0, 18), Text = "", Font = Enum.Font.GothamBold, TextSize = if isTouch then 12 else 14, TextTruncate = Enum.TextTruncate.AtEnd })
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
			-- Phones: just the HP left, so the name and the number both fit (D91).
			name.Text = if isTouch then `{boss:GetAttribute("BossName") or "Boss"}   {fmt(hp)}` else `{boss:GetAttribute("BossName") or "Boss"}   {fmt(hp)} / {fmt(max)}`
			fill.Size = UDim2.fromScale(math.clamp(hp / max, 0, 1), 1)
		end
	end)

	-- Announcements share the message slot with the view tip (D91): one replaces the other.
	banner = text(gui, {
		Text = "",
		Font = Enum.Font.GothamBold,
		TextScaled = true, -- shrinks to fit its slot (D91)
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	-- The map flow (D81): which map is up and how long it lasts.
	mapLabel = text(gui, {
		Text = "",
		Font = Enum.Font.GothamBold,
		TextScaled = true, -- shrinks rather than cutting off the countdown (D91)
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.5,
		TextStrokeColor3 = Color3.new(0, 0, 0),
	})
	new("UITextSizeConstraint", { MaxTextSize = if isTouch then 14 else 17, MinTextSize = 10 }, mapLabel)
	new("UITextSizeConstraint", { MaxTextSize = SIZES.bannerText, MinTextSize = 11 }, banner)
	local function clock(seconds: number): string
		local s2 = math.max(0, math.floor(seconds))
		return string.format("%d:%02d", s2 // 60, s2 % 60)
	end
	RunService.Heartbeat:Connect(function()
		local phase = Workspace:GetAttribute("MapPhase") or "grassland"
		local left = ((Workspace:GetAttribute("MapEndsAt") or 0) :: number) - Workspace:GetServerTimeNow()
		local display = Workspace:GetAttribute("MapDisplay") or ""
		local boss = Workspace:GetAttribute("MapBoss") or "Boss"
		-- Phones drop the map name in the arena and shorten the victory line, so the
		-- countdown always fits (D91).
		mapLabel.Text = if phase == "warning" then `{boss} approaches · {clock(left)}`
			elseif phase == "arena" then (if isTouch then `{boss} leaves in {clock(left)}` else `{display} · {boss} leaves in {clock(left)}`)
			elseif phase == "victory" then (if isTouch then `Victory! Overworld in {clock(left)}` else `Victory! Back to the overworld in {clock(left)}`)
			elseif phase == "biome" then `{display} · {clock(left)} left`
			elseif phase == "revert" then `{display} fades in {clock(left)}`
			else ""
	end)

	-- The swap transition (D82, was a flat colour fade): two steel blast doors slam
	-- shut, edged with hazard stripes and a light strip in the new map's colour, with
	-- its name across them; once the map has changed underneath, they slide open.
	local STEEL = Color3.fromRGB(46, 48, 54)
	local closedTop, openTop = UDim2.fromScale(-0.1, 0.5), UDim2.fromScale(-0.1, -0.15)
	local closedBottom, openBottom = UDim2.fromScale(-0.1, 0.5), UDim2.fromScale(-0.1, 1.15)
	local function door(anchorY: number, edgeY: number): (Frame, Frame)
		local d = new("Frame", {
			AnchorPoint = Vector2.new(0, anchorY),
			Position = if anchorY == 1 then openTop else openBottom,
			Size = UDim2.fromScale(1.2, 0.65),
			BackgroundColor3 = STEEL,
			BorderSizePixel = 0,
			ZIndex = 50,
			Visible = false,
		}, gui)
		new("UIGradient", { -- darker toward the seam, like a heavy plate catching light
			Rotation = 90,
			Color = ColorSequence.new(if anchorY == 1 then Color3.new(1, 1, 1) else Color3.fromRGB(120, 120, 120), if anchorY == 1 then Color3.fromRGB(120, 120, 120) else Color3.new(1, 1, 1)),
		}, d)
		-- Hazard stripes along the meeting edge.
		local keys = {}
		for i = 0, 9 do
			local c = if i % 2 == 0 then Color3.fromRGB(255, 205, 40) else Color3.fromRGB(25, 25, 25)
			table.insert(keys, ColorSequenceKeypoint.new(i / 10, c))
			-- Roblox rejects a ColorSequence whose last key isn't at exactly 1, and that
			-- error stopped the whole HUD from starting (D82 bug).
			table.insert(keys, ColorSequenceKeypoint.new(if i == 9 then 1 else (i + 1) / 10 - 0.0001, c))
		end
		local stripes = new("Frame", {
			AnchorPoint = Vector2.new(0, edgeY),
			Position = UDim2.fromScale(0, edgeY),
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			ZIndex = 51,
		}, d)
		new("UIGradient", { Color = ColorSequence.new(keys), Rotation = 8 }, stripes)
		local strip = new("Frame", {
			AnchorPoint = Vector2.new(0, edgeY),
			Position = UDim2.new(0, 0, edgeY, if edgeY == 1 then -18 else 18),
			Size = UDim2.new(1, 0, 0, 5),
			BorderSizePixel = 0,
			ZIndex = 51,
		}, d)
		return d, strip
	end
	local topDoor, topStrip = door(1, 1)
	local bottomDoor, bottomStrip = door(0, 0)
	local swapTitle = text(gui, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0.5, -30),
		Size = UDim2.new(0.9, 0, 0, 56),
		Font = Enum.Font.GothamBlack,
		TextSize = if isTouch then 34 else 46,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		ZIndex = 52,
		Text = "",
	})
	local swapSub = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 30),
		Size = UDim2.new(0.9, 0, 0, 28),
		Font = Enum.Font.GothamBold,
		TextSize = if isTouch then 16 else 20,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = MUTED,
		TextTransparency = 1,
		ZIndex = 52,
		Text = "",
	})
	local swapId = 0
	local CLOSE = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local OPEN = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local function openDoors(id: number)
		if swapId ~= id then
			return
		end
		TweenService:Create(swapTitle, OPEN, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		TweenService:Create(swapSub, OPEN, { TextTransparency = 1 }):Play()
		TweenService:Create(topDoor, OPEN, { Position = openTop }):Play()
		local last = TweenService:Create(bottomDoor, OPEN, { Position = openBottom })
		last.Completed:Once(function()
			if swapId == id then
				topDoor.Visible, bottomDoor.Visible = false, false
			end
		end)
		last:Play()
	end
	Remotes.MapSwap.OnClientEvent:Connect(function(color, title, subtitle)
		swapId += 1
		local id = swapId
		local accent = if typeof(color) == "Color3" then color:Lerp(Color3.new(1, 1, 1), 0.35) else Color3.new(1, 0.6, 0.2)
		topStrip.BackgroundColor3, bottomStrip.BackgroundColor3 = accent, accent
		swapTitle.TextColor3 = accent:Lerp(Color3.new(1, 1, 1), 0.5)
		swapTitle.Text = if type(title) == "string" then string.upper(title) else ""
		swapSub.Text = if type(subtitle) == "string" then subtitle else ""
		topDoor.Visible, bottomDoor.Visible = true, true
		TweenService:Create(topDoor, CLOSE, { Position = closedTop }):Play()
		local shut = TweenService:Create(bottomDoor, CLOSE, { Position = closedBottom })
		shut.Completed:Once(function()
			if swapId == id then
				if ClientState.actions.shake then
					ClientState.actions.shake(0.25)
				end
				TweenService:Create(swapTitle, TweenInfo.new(0.15), { TextTransparency = 0, TextStrokeTransparency = 0.4 }):Play()
				TweenService:Create(swapSub, TweenInfo.new(0.15), { TextTransparency = 0 }):Play()
			end
		end)
		shut:Play()
		-- Hold until the map has changed underneath (and the name has been read).
		local conn
		conn = Workspace:GetAttributeChangedSignal("Map"):Connect(function()
			conn:Disconnect()
			task.delay(0.7, openDoors, id)
		end)
		task.delay(2.5, function() -- never stay shut, even if the map didn't change
			conn:Disconnect()
			openDoors(id)
		end)
	end)

	-- Map check (D89): a few seconds after each swap, log what this client actually has:
	-- the map's parts, ground under your robot, and whether the place streams. Tells
	-- "the server never built it" apart from "it never reached this client".
	Workspace:GetAttributeChangedSignal("Map"):Connect(function()
		local mapName = Workspace:GetAttribute("Map")
		task.delay(4, function()
			if Workspace:GetAttribute("Map") ~= mapName then
				return
			end
			local arena = Workspace:FindFirstChild("Arena")
			local parts = if arena then #arena:GetDescendants() else 0
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local ground = "no robot"
			if root then
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Include
				params.FilterDescendantsInstances = { Workspace.Terrain }
				ground = if Workspace:Raycast(root.Position + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), params) then "yes" else "NONE"
			end
			local line = `[MapCheck] {mapName}: {parts} map parts here, ground under you: {ground}, streaming: {if Workspace.StreamingEnabled then "on" else "off"}`
			if parts == 0 or ground == "NONE" then
				warn(line)
			else
				print(line)
			end
		end)
	end)

	local shownAt = 0
	Remotes.Announce.OnClientEvent:Connect(function(message)
		if type(message) ~= "string" then
			return
		end
		banner.Text = message
		banner.TextTransparency, banner.TextStrokeTransparency = 0, 0.4
		bannerUntil = os.clock() + 4.2
		viewTip.Visible = false -- the announcement takes the message slot
		shownAt = os.clock()
		local mine = shownAt
		task.delay(4, function()
			if shownAt == mine then
				TweenService:Create(banner, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
			end
		end)
	end)
end

local hintFrame: Frame

local function buildControls()
	local hint = new("Frame", {
		Size = UDim2.fromOffset(200, 133),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		Visible = not isTouch,
	}, gui)
	corner(hint, 8)
	hintFrame = hint
	skillLabel = text(hint, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, Text = "SPACE · No skill" })
	autoLabel = text(hint, { Position = UDim2.fromOffset(10, 25), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "E · Auto-fire OFF" })
	camHint = text(hint, { Position = UDim2.fromOffset(10, 46), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "V · Top-down view" })

	viewTip = text(gui, {
		AnchorPoint = Vector2.new(0.5, 0), -- centred in the message slot (applyLayout)
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 0.2,
		BackgroundColor3 = PANEL,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	})
	corner(viewTip, 14)
	tipLimit = new("UISizeConstraint", {}, viewTip) -- applyLayout caps it at the message slot
	new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, viewTip)
	text(hint, { Position = UDim2.fromOffset(10, 67), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "1 / 2 / 3 · Pick upgrade" })
	text(hint, { Position = UDim2.fromOffset(10, 88), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "Ctrl · Cursor on / off" })
	text(hint, { Position = UDim2.fromOffset(10, 109), Size = UDim2.new(1, -20, 0, 20), TextSize = 13, TextColor3 = MUTED, Text = "Tab · Leaderboard" })

	-- Phone buttons: one thumb cluster bottom right, [CAM][SKILL] above [AUTO][FIRE].
	-- HudLayout places them (D91).
	if isTouch then
		local skill: TextButton = new("TextButton", {
			Size = UDim2.fromOffset(68, 68),
			BackgroundColor3 = Color3.fromRGB(60, 120, 230),
			Font = Enum.Font.GothamBold,
			TextSize = 14,
			TextWrapped = true,
			TextColor3 = TEXT,
			Text = "SKILL",
		}, gui)
		corner(skill, 34)
		skill.Activated:Connect(function()
			ClientState.actions.useSkill()
		end)
		skillButton = skill
		local auto: TextButton = new("TextButton", {
			Size = UDim2.fromOffset(52, 52),
			BackgroundColor3 = PANEL,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextWrapped = true,
			TextColor3 = TEXT,
			Text = "AUTO\nOFF",
		}, gui)
		corner(auto, 26)
		auto.Activated:Connect(function()
			ClientState.actions.toggleAuto()
		end)
		autoButton = auto

		local cam: TextButton = new("TextButton", {
			Size = UDim2.fromOffset(52, 44),
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
			Size = UDim2.fromOffset(88, 88),
			BackgroundColor3 = Color3.fromRGB(220, 70, 60),
			Font = Enum.Font.GothamBlack,
			TextSize = 16,
			TextColor3 = TEXT,
			Text = "FIRE",
			Visible = false,
		}, gui)
		corner(fire, 44)
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

-- Layout (D91) ------------------------------------------------------------------

-- Places every widget from the HudLayout plan for the current screen. The plan is in
-- the device-safe area (the Board gui); widgets in the main gui sit below the top bar.
local function applyLayout()
	local full = boardGui.AbsoluteSize
	local topBar = gui.AbsolutePosition.Y - boardGui.AbsolutePosition.Y
	local left = gui.AbsolutePosition.X - boardGui.AbsolutePosition.X -- 0 unless a device insets them differently
	if full.X < 200 or full.Y < 150 then
		return -- not laid out yet
	end
	local plan = HudLayout.plan({ w = full.X, h = full.Y, topBar = topBar, touch = isTouch })
	local r = plan.rects
	local function place(inst: GuiObject?, rect: HudLayout.Rect?, inMain: boolean, keepSize: boolean?)
		if not inst or not rect then
			return
		end
		inst.AnchorPoint = Vector2.zero
		inst.Position = if inMain then UDim2.fromOffset(rect.x - left, rect.y - topBar) else UDim2.fromOffset(rect.x, rect.y)
		if not keepSize then
			inst.Size = UDim2.fromOffset(rect.w, rect.h)
		end
	end
	-- Auto-sized widgets keep their height (or width) and are centred in their rect.
	local function centreTop(inst: GuiObject, rect: HudLayout.Rect)
		inst.AnchorPoint = Vector2.new(0.5, 0)
		inst.Position = UDim2.fromOffset(rect.x + rect.w / 2 - left, rect.y - topBar)
	end
	place(leftColumn, r.bars, true, true)
	leftColumn.Size = UDim2.fromOffset(r.bars.w, 0)
	place(board, r.board, false, true)
	board.Size = UDim2.fromOffset(r.board.w, 0)
	centreTop(walletBar, r.wallet)
	place(bossFrame, r.bossBar, true)
	place(mapLabel, r.mapLine, true)
	place(banner, r.message, true)
	centreTop(viewTip, r.message)
	tipLimit.MaxSize = Vector2.new(r.message.w, r.message.h)
	place(tray, r.tray, true)
	place(collapsed, r.levelUp, true)
	place(hintFrame, r.hint, true)
	place(skillButton, r.skill, true)
	place(autoButton, r.auto, true)
	place(camButton, r.cam, true)
	place(fireButton, r.fire, true)
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
		armorRow.Visible = armor > 0 or maxArmor > 0
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
	if fireButton then
		fireButton.Visible = third
		if not third then
			ClientState.fireButtonHeld = false
		end
	end
	if camButton then
		camButton.Text = if third then "TOP" else "3RD"
	end
	camHint.Text = if third then "V · Top-down view" else "V · Third-person view"
	if ClientState.camMode ~= startMode then
		camSwitched = true
		viewTip.Visible = false
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
	-- Phones: the kill feed steps aside while the upgrade cards are open (they share the left).
	if isTouch then
		feed.Visible = not tray.Visible
		chipsFrame.Visible = not tray.Visible
	end

	-- Skill cooldown
	if s then
		local ready = math.max(s.skillReadyAt or 0, ClientState.localSkillReadyAt)
		local remaining = math.max(0, ready - t)
		local name = s.skillAlias or skillName(s.skill)
		local cd = if s.skill and remaining > 0 then string.format("  (%.1fs)", remaining) else ""
		-- The Bomber's shell shows its Pressure: the blast grows with it (D84).
		local pressure = character and not s.skillAlias and character:GetAttribute("Chassis") == "bomber" and character:GetAttribute("Pressure")
		local extra = if type(pressure) == "number" then string.format("  · Pressure %d%%", pressure) else ""
		skillLabel.Text = "SPACE · " .. name .. cd .. extra
		if skillButton then
			skillButton.Text = if s.skill then (if remaining > 0 then string.format("%.1f", remaining) else name) else "SKILL"
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
		xpText.Text = fmt(s.xp) .. " / " .. fmt(s.xpNeed) .. " XP"
	else
		xpFill.Size = UDim2.fromScale(1, 1)
		xpText.Text = "MAX"
	end
	-- Phones only have room for the level; PC adds when the next upgrade comes.
	local nextOffer = XpCurve.nextOfferLevel(s.level)
	levelText.Text = "Lv " .. s.level .. (if nextOffer and not isTouch then " · upgrade at Lv " .. nextOffer else "")
	comebackBadge.Visible = s.comeback ~= nil
	if s.comeback then
		comebackBadge.Text = string.format("COMEBACK XP x%.1f", s.comeback.mult)
	end
	if s.alive then
		deathPanel.Visible = false
		deathRespawnAt = nil
		-- The tip waits while an announcement holds the message slot (D91).
		if not tipShown and not camSwitched and os.clock() >= bannerUntil then
			tipShown = true
			local other = if ClientState.camMode == "third" then "top-down" else "third-person"
			viewTip.Text = if isTouch
				then `Tip: tap {if ClientState.camMode == "third" then "TOP" else "3RD"} to switch view`
				else `Tip: press V for the {other} view`
			viewTip.Visible = true
			task.delay(10, function()
				viewTip.Visible = false
			end)
		end
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
	-- Lay out now and whenever the screen changes (rotation, window resize, top bar).
	applyLayout()
	boardGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
	gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(applyLayout)
	boardGui:GetPropertyChangedSignal("AbsolutePosition"):Connect(applyLayout)

	ClientState.actions.pick = Hud.pick

	Remotes.State.OnClientEvent:Connect(onState)
	Remotes.Leaderboard.OnClientEvent:Connect(updateBoard)
	Remotes.KillFeed.OnClientEvent:Connect(addFeed)
	Remotes.Death.OnClientEvent:Connect(function(info)
		deathPanel.Visible = true
		tray.Visible = false
		collapsed.Visible = false
		deathTitle.Text = "DESTROYED"
		deathInfo.Text = if info.untilFightEnds
			then string.format("by %s\nYou keep Lv %d · you're out until the fight ends", info.killerName, info.level)
			elseif info.keepsLevel then string.format("by %s\nYou keep Lv %d · back in the fight in a moment", info.killerName, info.level)
			else string.format("by %s (Lv %d)\nYou reached Lv %d · Score %s", info.killerName, info.killerLevel, info.level, fmt(info.score))
		deathRespawnAt = info.respawnAt
		deathTimer.Text = if info.untilFightEnds then "Watching the fight…" else "" -- D85
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
