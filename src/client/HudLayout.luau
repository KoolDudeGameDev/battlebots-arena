--!strict
-- Where every HUD widget goes on a given screen (D91). Pure, so Lune checks that no
-- two widgets that can be on screen together overlap, on phones, tablets and PCs.
--
-- Rects are in pixels of the device-safe area (a ScreenGui with DeviceSafeInsets:
-- it includes Roblox's top bar, but not a phone's notch). Hud places each widget
-- from them, subtracting topBar for widgets in the main HUD ScreenGui.

export type Rect = { x: number, y: number, w: number, h: number }
export type Screen = { w: number, h: number, topBar: number, touch: boolean }
export type Plan = {
	rects: { [string]: Rect },
	exclusive: { { string } }, -- pairs that are never on screen together
	buttons: { string }, -- touch targets (at least 44 px each way)
	sizes: Sizes,
}
export type Sizes = {
	panelW: number, -- the bars, chips and feed column
	chipW: number, -- each boost chip
	cardW: number, -- each upgrade card
	boardRows: number, -- leaderboard rows (plus you when lower)
	feedRows: number, -- kill feed entries
	bannerText: number, -- largest announcement text size (it shrinks to fit its slot)
}

local HudLayout = {}

local M = 12 -- screen-edge margin
local GAP = 8

-- True when a and b come closer than `gap` px (0: when they overlap at all).
function HudLayout.overlaps(a: Rect, b: Rect, gap: number?): boolean
	local g = gap or 0
	return a.x < b.x + b.w + g and b.x < a.x + a.w + g and a.y < b.y + b.h + g and b.y < a.y + a.h + g
end

-- Sizes that depend only on the device kind, not the screen.
function HudLayout.sizes(touch: boolean): Sizes
	return {
		panelW = if touch then 180 else 280,
		chipW = 150,
		cardW = if touch then 124 else 150,
		boardRows = if touch then 3 else 5,
		feedRows = if touch then 2 else 4,
		bannerText = if touch then 16 else 22,
	}
end

local function centred(screenW: number, y: number, w: number, h: number): Rect
	return { x = math.floor((screenW - w) / 2), y = y, w = w, h = h }
end

function HudLayout.plan(s: Screen): Plan
	local touch = s.touch
	local W, H, top = s.w, s.h, s.topBar
	local rects: { [string]: Rect } = {}
	local exclusive: { { string } } = { { "tray", "levelUp" } }

	local sizes = HudLayout.sizes(touch)
	local panelW, cardW, boardRows, feedRows = sizes.panelW, sizes.cardW, sizes.boardRows, sizes.feedRows

	-- Roblox's own buttons (menu, chat, voice) in the top bar's left end.
	rects.robloxMenu = { x = 0, y = 0, w = if touch then 220 else 270, h = top }

	-- Left column under the top bar: HP, armor and XP bars, then boost chips, then the
	-- kill feed. Reserved at full size (all chips up, the feed full).
	local barsH = 20 + 5 + 12 + 5 + 16
	rects.bars = { x = M, y = top + M, w = panelW, h = barsH }
	local chipsH = 4 * 22 + 3 * 4
	rects.chips = { x = M, y = rects.bars.y + barsH + 6, w = sizes.chipW, h = chipsH }
	rects.feed = { x = M, y = rects.chips.y + chipsH + 6, w = panelW, h = feedRows * 22 + (feedRows - 1) * 4 }

	-- Leaderboard: top right, inside the top bar like Roblox's player list.
	local rows = boardRows + 1
	local boardW = if touch then 196 else 220
	rects.board = { x = W - M - boardW, y = 16, w = boardW, h = 16 + 18 + 2 + rows * 18 + (rows - 1) * 2 }

	-- Top centre, under the top bar: coins and Garage, the boss bar, the map line and
	-- the message slot (the view tip and announcements take turns in it). The lines are
	-- as wide as the space between the left column and the right edge allows.
	-- Phones show the coin count without the word "coins" (the coin icon says it), as
	-- "12.3k" from 10,000, with a 96 px GARAGE button: at most about 206 px.
	rects.wallet = centred(W, top + 8, if touch then 210 else 278, 36)
	-- Phones: narrow enough to pass under the leaderboard's corner on a 640 px screen,
	-- and the stack is tighter so the message slot clears the cards on a 354 px one.
	local step = if touch then { boss = 48, map = 92, msg = 118, msgH = 34 } else { boss = 50, map = 94, msg = 122, msgH = 40 }
	rects.bossBar = centred(W, top + step.boss, if touch then 210 else 380, 40)
	local lineW = math.min(math.floor(W * 0.6), W - 2 * (M + panelW + GAP))
	rects.mapLine = centred(W, top + step.map, lineW, 22)
	rects.message = centred(W, top + step.msg, lineW, step.msgH)

	-- Bottom: the upgrade cards (or the collapsed LEVEL UP button in their place).
	local trayW = cardW * 3 + 20
	if touch then
		-- Right-aligned just left of the thumb buttons (which take the last 168 px).
		local right = W - 180
		rects.tray = { x = right - trayW, y = H - M - 128, w = trayW, h = 128 }
		rects.levelUp = { x = right - 190, y = H - M - 44, w = 190, h = 44 }
		-- On a phone the cards share the lower left with the chips and the feed, which
		-- step aside while the cards are open.
		table.insert(exclusive, { "tray", "chips" })
		table.insert(exclusive, { "tray", "feed" })
	else
		rects.tray = centred(W, H - 16 - 128, trayW, 128)
		rects.levelUp = centred(W, H - 16 - 44, 190, 44)
	end

	local buttons: { string } = {}
	if touch then
		-- One thumb cluster bottom right: CAM and SKILL above AUTO and FIRE.
		rects.fire = { x = W - 16 - 88, y = H - 16 - 88, w = 88, h = 88 }
		rects.skill = { x = W - 26 - 68, y = H - 116 - 68, w = 68, h = 68 }
		rects.auto = { x = W - 116 - 52, y = H - 20 - 52, w = 52, h = 52 }
		rects.cam = { x = W - 116 - 52, y = H - 80 - 44, w = 52, h = 44 }
		buttons = { "fire", "skill", "auto", "cam", "levelUp" }
	else
		rects.hint = { x = W - M - 200, y = H - 14 - 133, w = 200, h = 133 }
	end

	return {
		rects = rects,
		exclusive = exclusive,
		buttons = buttons,
		sizes = sizes,
	}
end

return HudLayout
