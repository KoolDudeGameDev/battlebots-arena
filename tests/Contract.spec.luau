-- The server-to-client contract (D93): reads the source and checks it against
-- src/shared/Contract.luau, so an attribute or part name can't drift silently.
local fs = require("@lune/fs")
local Contract = require("../src/shared/Contract")

local function luauFiles(dir: string, out: { [string]: string })
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			if name ~= "vendor" then
				luauFiles(path, out)
			end
		elseif string.sub(name, -5) == ".luau" then
			-- Comments don't count: a commented-out SetAttribute sets nothing.
			out[path] = string.gsub(fs.readFile(path), "%-%-[^\n]*", "")
		end
	end
	return out
end

local SOURCES = luauFiles("src", {})

-- Literal names passed to calls like SetAttribute("Name", ...).
local function namesIn(pattern: string, onlyUnder: string?): { [string]: string }
	local found = {}
	for path, src in SOURCES do
		if not onlyUnder or string.find(path, onlyUnder, 1, true) then
			for name in string.gmatch(src, pattern) do
				found[name] = path
			end
		end
	end
	return found
end

local SET = namesIn('SetAttribute%(%s*"([%w_]+)"')
local READ = namesIn('GetAttribute%(%s*"([%w_]+)"')
for name, path in namesIn('GetAttributeChangedSignal%(%s*"([%w_]+)"') do
	READ[name] = path
end
-- Attributes read through a list, e.g. for _, attr in { "MaxHP", ... } do ... GetAttributeChangedSignal(attr)
for _, src in SOURCES do
	for list in string.gmatch(src, "for _, attr in (%b{})") do
		for name in string.gmatch(list, '"([%w_]+)"') do
			READ[name] = "list"
		end
	end
end

-- Hammer smash counters are attribute names passed as arguments (the last quoted
-- argument of buildSmashHammer and of Combat's smash): they must be declared too.
local COUNTERS: { [string]: string } = {}
for path, src in SOURCES do
	for call in string.gmatch(src, "buildSmashHammer(%b())") do
		local last
		for name in string.gmatch(call, '"([%w_]+)"') do
			last = name
		end
		if last then
			COUNTERS[last] = path
		end
	end
	for call in string.gmatch(src, "[^%w_]smash(%b())") do
		local last
		for name in string.gmatch(call, '"([%w_]+)"') do
			last = name
		end
		if last then
			COUNTERS[last] = path
		end
	end
end

local function contains(path: string, literal: string): boolean
	return string.find(SOURCES[path], '"' .. literal .. '"', 1, true) ~= nil
end

local function clientContains(literal: string): boolean
	for path, src in SOURCES do
		if string.find(path, "src/client", 1, true) and string.find(src, '"' .. literal .. '"', 1, true) then
			return true
		end
	end
	return false
end

return function(test)
	test("contract: every attribute set is declared and read somewhere", function()
		for name, path in SET do
			assert(Contract.attributes[name], `{name} is set in {path} but missing from Contract.attributes`)
			assert(READ[name], `{name} is set in {path} but nothing reads it`)
		end
	end)

	test("contract: every attribute read is declared and set somewhere", function()
		for name, path in READ do
			assert(Contract.attributes[name], `{name} is read in {path} but missing from Contract.attributes`)
			assert(SET[name], `{name} is read in {path} but nothing sets it`)
		end
	end)

	test("contract: every declared attribute is still used", function()
		for name in Contract.attributes do
			assert(SET[name] and READ[name], `{name} is declared but no longer set and read`)
		end
	end)

	test("contract: every hammer smash counter is a declared attribute", function()
		assert(next(COUNTERS), "found no smash counters: the scan is broken")
		for name, path in COUNTERS do
			assert(Contract.attributes[name], `smash counter {name} in {path} is not declared in Contract.attributes`)
			assert(SET[name], `smash counter {name} is never set`)
		end
	end)

	test("contract: every robot part the client looks up is built by RobotBuilder", function()
		local builder = "src/server/RobotBuilder.luau"
		assert(SOURCES[builder], "RobotBuilder.luau not found")
		for name, part in Contract.parts do
			assert(contains(builder, name), `RobotBuilder never makes a part named {name}`)
			assert(clientContains(name) or (part.motor and clientContains(name .. "Motor")), `no client code looks up {name}`)
		end
	end)

	test("contract: every part Robots.luau looks up by name is declared", function()
		local robots = SOURCES["src/client/Robots.luau"]
		-- Not robot parts: Roblox's own, and parts the client makes itself.
		local NOT_RIG = { HumanoidRootPart = true, Head = true, Humanoid = true, Edge = true, DamageFx = true, BurnFx = true, Shared = true, PlayerGui = true, Remotes = true, Config = true }
		local function check(name: string)
			local base = string.gsub(name, "Motor$", "")
			assert(NOT_RIG[name] or Contract.parts[name] or (Contract.parts[base] and Contract.parts[base].motor), `Robots.luau looks up "{name}", which Contract.parts doesn't declare`)
		end
		for _, pattern in { 'FindFirstChild%("([%w_]+)"', 'WaitForChild%("([%w_]+)"', 'Name == "([%w_]+)"', 'Name ~= "([%w_]+)"' } do
			for name in string.gmatch(robots, pattern) do
				check(name)
			end
		end
		-- Part names kept in lists, e.g. local FLAME_PARTS = { "Flame", ... }
		for list in string.gmatch(robots, "local [%u_]+_[%u_]+ = (%b{})") do
			for name in string.gmatch(list, '"([%w_]+)"') do
				check(name)
			end
		end
	end)
end
