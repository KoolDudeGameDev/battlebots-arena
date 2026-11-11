-- Bomber (D70, redesigned in D84, 11-bomber-redesign.md): a huge shell that nets and
-- marks robots and builds Pressure from the hits it soaks; Space detonates (stronger
-- with more Pressure) and leaves the shell as a husk; the small core fights with a
-- Scrap Cannon and Boost until it reclaims the husk or heals.
local Chassis = require("../src/shared/Chassis")
local Config = require("../src/shared/Config")
local Stats = require("../src/shared/Stats")
local Upgrades = require("../src/shared/Upgrades")
local OfferGenerator = require("../src/shared/OfferGenerator")
local Combat2D = require("../src/shared/Combat2D")

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

local function stats(id: string, small: boolean?, stacks: { [string]: number }?)
	return Stats.compute(Config, { stacks = stacks or {}, chassis = Chassis.byId[id], small = small }, 0)
end

local function offered(chassisId: string, skill: string?): { [string]: boolean }
	local c = Chassis.byId[chassisId]
	local b = { stacks = {}, mounts = {}, skill = skill, skillRank = 1, tags = c.tags }
	local out = {}
	for _, card in OfferGenerator.eligible(Upgrades, b, Config.MaxLevel) do
		out[card.id] = true
	end
	return out
end

return function(test)
	test("big form is the toughest robot and its gun never deals damage", function()
		local big = stats("bomber")
		for _, c in Chassis.list do
			if not c.comingSoon and c.id ~= "bomber" then
				local s = stats(c.id)
				assert(big.maxHp + big.maxArmor > s.maxHp + s.maxArmor, "bomber should out-tank " .. c.id)
			end
		end
		local p = Chassis.byId.bomber.primary :: Chassis.Primary
		assert(p.kind == "net" and Config.Weapons[p.weapon].damage == 0)
	end)

	test("nets (D84): a short slow, then immunity, so the slow is up less than half the time", function()
		local N = Config.Weapons.netgun
		assert(N.netSlow == 0.55 and N.netDuration == 1.6 and N.immunity == 2)
		assert(N.markDuration == 6 and N.bossSlow == 0.8)
		local uptime = N.netDuration / (N.netDuration + N.immunity)
		assert(uptime < 0.5, "slowed " .. uptime)
	end)

	test("small form: same max HP, much faster, smaller, no armor, and a Scrap Cannon", function()
		local big, small = stats("bomber"), stats("bomber", true)
		assert(small.maxHp == big.maxHp, "HP percentage carries over")
		assert(small.speed >= big.speed * 1.4, "small form is fast")
		assert(small.hitRadius < big.hitRadius and small.maxArmor == 0)
		local form = Stats.form({ chassis = Chassis.byId.bomber, small = true })
		assert(form.primary.kind == "projectile" and form.primary.weapon == "scrapgun", "the core shoots")
		assert(Stats.form({ chassis = Chassis.byId.bomber }).primary.kind == "net", "the shell nets")
		local W = Config.Weapons.scrapgun
		assert(W.range == 16 and W.pellets == 3 and W.damage == 7 and W.fireRate == 1.6)
	end)

	test("Scrap Cannon: below the Rookie's damage unless the target is marked", function()
		local W = Config.Weapons.scrapgun
		local dps = W.pellets * W.damage * W.fireRate
		local rookie = Config.Weapons.blaster.damage * Config.Weapons.blaster.fireRate
		assert(dps < rookie, "plain " .. dps)
		assert(dps * (1 + W.markedBonus) > rookie, "marked " .. dps * (1 + W.markedBonus))
		assert(Stats.pellets(Config, { stacks = {} }) == 3)
		assert(Stats.pellets(Config, { stacks = { bmb_shrapnel = 2 } }) == 5, "Shrapnel adds pellets")
	end)

	test("blast damage grows with Pressure: 150 empty, 400 full, ranks add 25%", function()
		assert(near(Stats.bombDamage(Config, 0, 1, 1), 150))
		assert(near(Stats.bombDamage(Config, 100, 1, 1), 400))
		assert(near(Stats.bombDamage(Config, 50, 1, 1), 275))
		assert(near(Stats.bombDamage(Config, 250, 1, 1), 400), "Pressure caps at 100")
		assert(near(Stats.bombDamage(Config, 100, 2, 1), 500), "rank 2")
		assert(near(Stats.bombDamage(Config, 100, 1, 1.5), 600), "damage stacks")
	end)

	test("the blast is exactly the drawn ring, and Shaped Charge widens both", function()
		local S = Config.Skills.skl_bomb
		local ring = Stats.attackRange(Config, Chassis.byId.bomber.primary, stats("bomber"), { stacks = {} })
		assert(near(ring, Config.Weapons.netgun.range + 1.2 + Config.Robot.BarrelLength), "ring " .. ring)
		local wide = Stats.attackRange(Config, Chassis.byId.bomber.primary, stats("bomber"), { stacks = { bmb_shaped = 2 } })
		assert(near(wide, ring * 1.24), "Shaped Charge x2: " .. wide)
		assert(S.edge == 0.5 and near(Combat2D.splashFactor(ring, ring, S.edge), 0.5), "half damage at the ring")
	end)

	test("the bomb is the Bomber's own skill: never replaced, only ranked up", function()
		local b = offered("bomber", "skl_bomb")
		assert(b.skl_bomb, "rank-up offered")
		assert(not b.skl_dash and not b.skl_shield and not b.skl_nullfield and not b.skl_earthwall, "no other skills")
		assert(not offered("rookie", nil).skl_bomb, "only the Bomber gets bombs")
		assert(Chassis.byId.bomber.skill == "skl_bomb")
	end)

	test("six Bomber-only cards (D84), offered to nobody else", function()
		local b, r = offered("bomber", "skl_bomb"), offered("rookie", nil)
		for _, id in { "bmb_mesh", "bmb_valve", "bmb_shaped", "bmb_hotfuse", "bmb_shrapnel", "bmb_marked" } do
			assert(Upgrades.byId[id], id .. " exists")
			assert(b[id], id .. " offered to the Bomber")
			assert(not r[id], id .. " offered to the Rookie")
		end
	end)

	test("Bomber uses the special attachment pool", function()
		local b = offered("bomber", "skl_bomb")
		assert(b.wpn_traps and b.wpn_shieldgen and not b.wpn_gatling)
	end)

	test("detonating leaves 35% HP; reclaiming the husk or healing to 60% makes it big again", function()
		local B = Config.Bomber
		assert(B.hpAfter == 0.35 and B.rebuildAt == 0.6)
		assert(B.reclaim.hold == 1.5 and B.husk.life == 25 and B.husk.hpFraction == 0.25)
		local secs = (B.rebuildAt - B.hpAfter) / B.smallRegenPerSecond
		assert(secs >= 24 and secs <= 26, "passive rebuild takes " .. secs .. " s")
	end)
end
