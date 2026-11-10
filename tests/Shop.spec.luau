-- Coins, buying and equipping robots (Phase 4a, D73). Money logic: every rule here
-- runs on the server against the saved profile.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Shop = require("../src/shared/Shop")

local function data(coins: number?)
	local d = Shop.template()
	d.coins = coins or 0
	return d
end

return function(test)
	test("a new profile owns and drives the free Rookie with 0 coins", function()
		local d = Shop.template()
		assert(d.coins == 0 and d.owned.rookie == true and d.equipped == "rookie")
		assert(Chassis.byId.rookie.price == 0)
		local e = Shop.template()
		e.owned.brawler = true
		assert(not Shop.template().owned.brawler, "each template is a fresh copy")
	end)

	test("prices: Brawler 300, Scorcher 300, Bombard 600, Bomber 750", function()
		local B = Chassis.byId
		assert(B.brawler.price == 300 and B.scorcher.price == 300 and B.bombard.price == 600 and B.bomber.price == 750)
	end)

	test("buying takes the price once and adds the robot", function()
		local d = data(400)
		local ok = Shop.buy(d, Chassis.byId.brawler)
		assert(ok and d.coins == 100 and d.owned.brawler)
		local again, why = Shop.buy(d, Chassis.byId.brawler)
		assert(not again and why == "owned" and d.coins == 100, "no double charge")
	end)

	test("can't buy without enough coins, coming-soon slots, or unknown robots", function()
		local d = data(299)
		local ok, why = Shop.buy(d, Chassis.byId.brawler)
		assert(not ok and why == "coins" and d.coins == 299 and not d.owned.brawler)
		local soon, why2 = Shop.buy(data(9999), Chassis.byId.class_b)
		assert(not soon and why2 == "soon")
		local none, why3 = Shop.buy(data(9999), nil)
		assert(not none and why3 == "unknown")
	end)

	test("equip only robots you own", function()
		local d = data(0)
		local ok, why = Shop.equip(d, Chassis.byId.bomber)
		assert(not ok and why == "locked" and d.equipped == "rookie")
		d.owned.bomber = true
		assert(Shop.equip(d, Chassis.byId.bomber) and d.equipped == "bomber")
	end)

	test("coins only go up by whole positive amounts", function()
		local d = data(10)
		Shop.addCoins(d, 5)
		Shop.addCoins(d, -50)
		Shop.addCoins(d, 0 / 0)
		Shop.addCoins(d, 2.7)
		assert(d.coins == 17, "got " .. d.coins)
	end)

	test("repair: a broken or tampered profile falls back to a valid state", function()
		local d = { coins = -5, owned = { brawler = true }, equipped = "class_a" }
		Shop.repair(d, Chassis.byId, Chassis.default)
		assert(d.coins == 0 and d.owned.rookie and d.equipped == "rookie")
		local e = { coins = 50, owned = { rookie = true }, equipped = "bomber" }
		Shop.repair(e, Chassis.byId, Chassis.default)
		assert(e.equipped == "rookie", "can't drive a robot you don't own")
	end)

	test("garage card stats for every robot", function()
		for _, c in Chassis.list do
			if not c.comingSoon then
				local card = Shop.card(Config, Stats, c)
				assert(card.hp > 0 and card.speed > 0 and card.range > 0, c.id)
				assert(type(card.attack) == "string" and #card.attack > 0, c.id)
			end
		end
		local b, r = Shop.card(Config, Stats, Chassis.byId.brawler), Shop.card(Config, Stats, Chassis.byId.rookie)
		assert(b.hp + b.armor > r.hp + r.armor and b.range < r.range, "the card shows the reach-for-toughness trade")
	end)

	test("coin sources: map coins worth 5, chests worth 15-35", function()
		local C = Config.Coins
		assert(C.value == 5 and C.mapMax == 3)
		assert(C.chest.pieces[1] * C.value == 15 and C.chest.pieces[2] * C.value == 35)
	end)
end
