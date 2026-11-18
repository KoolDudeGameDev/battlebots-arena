-- The HUD layout plan (D91): every widget's place on a given screen. Overlaps came
-- back three play-test rounds running (D86, D87); this catches them before Studio.
local HudLayout = require("../src/client/HudLayout")

-- Screen sizes in the device-safe area (what a ScreenGui with DeviceSafeInsets sees),
-- with Roblox's top bar height.
local SCREENS = {
	{ name = "iPhone landscape 750x381", w = 750, h = 381, topBar = 58, touch = true },
	{ name = "smallest supported phone 640x354", w = 640, h = 354, topBar = 58, touch = true },
	{ name = "iPhone mini landscape 712x354", w = 712, h = 354, topBar = 58, touch = true },
	{ name = "large phone 844x390", w = 844, h = 390, topBar = 58, touch = true },
	{ name = "tablet 1024x768", w = 1024, h = 768, topBar = 58, touch = true },
	{ name = "laptop 1366x768", w = 1366, h = 768, topBar = 58, touch = false },
	{ name = "desktop 1920x1080", w = 1920, h = 1080, topBar = 58, touch = false },
}

local function exclusive(plan, a: string, b: string): boolean
	for _, pair in plan.exclusive do
		if (pair[1] == a and pair[2] == b) or (pair[1] == b and pair[2] == a) then
			return true
		end
	end
	return false
end

return function(test)
	for _, screen in SCREENS do
		test(`hud layout: widgets keep 4 px apart on {screen.name}`, function()
			local plan = HudLayout.plan(screen)
			local names = {}
			for name in plan.rects do
				table.insert(names, name)
			end
			table.sort(names)
			for i = 1, #names do
				for j = i + 1, #names do
					local a, b = names[i], names[j]
					if not exclusive(plan, a, b) then
						assert(not HudLayout.overlaps(plan.rects[a], plan.rects[b], 4), `{a} is within 4 px of {b}`)
					end
				end
			end
		end)

		test(`hud layout: everything is on screen on {screen.name}`, function()
			local plan = HudLayout.plan(screen)
			for name, r in plan.rects do
				assert(r.w > 0 and r.h > 0, name .. " has no size")
				assert(r.x >= 0 and r.y >= 0 and r.x + r.w <= screen.w and r.y + r.h <= screen.h, `{name} leaves the screen: {r.x},{r.y} {r.w}x{r.h}`)
			end
		end)
	end

	test("hud layout: phone buttons are big enough to tap", function()
		local plan = HudLayout.plan(SCREENS[2])
		for _, name in plan.buttons do
			local r = plan.rects[name]
			assert(r, name .. " missing")
			assert(math.min(r.w, r.h) >= 44, `{name} is {r.w}x{r.h}, under 44`)
		end
	end)

	test("hud layout: phones get the thumb buttons, PC gets the key hints", function()
		local phone = HudLayout.plan(SCREENS[1])
		assert(phone.rects.fire and phone.rects.skill and phone.rects.auto and phone.rects.cam and not phone.rects.hint)
		local pc = HudLayout.plan(SCREENS[6]) -- the laptop
		assert(pc.rects.hint and not pc.rects.fire and not pc.rects.skill)
	end)

	test("hud layout: the plan follows the screen size", function()
		local a = HudLayout.plan(SCREENS[6]) -- laptop
		local b = HudLayout.plan(SCREENS[7]) -- desktop
		assert(b.rects.board.x > a.rects.board.x, "the leaderboard stays in the right corner")
		assert(b.rects.tray.y > a.rects.tray.y, "the cards stay at the bottom")
	end)
end
