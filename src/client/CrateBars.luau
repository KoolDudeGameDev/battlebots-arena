-- HP bars over scrap heaps, wrecks and the coin chest (D83): hidden while full, shown
-- once damaged so you can see how close it is to breaking open.

local CollectionService = game:GetService("CollectionService")

local CrateBars = {}

local function add(model: Instance)
	if not model:IsA("Model") or model:FindFirstChild("HpBar") then
		return
	end
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not anchor then -- its parts haven't arrived yet
		model.ChildAdded:Once(function()
			add(model)
		end)
		return
	end
	local box, size = model:GetBoundingBox()
	local gui = Instance.new("BillboardGui")
	gui.Name = "HpBar"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(70, 9)
	gui.StudsOffsetWorldSpace = box.Position - anchor.Position + Vector3.new(0, size.Y / 2 + 2.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 120
	gui.Enabled = false
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(240, 160, 60)
	fill.BorderSizePixel = 0
	fill.Parent = back
	gui.Parent = model
	local function update()
		local hp = model:GetAttribute("HP") or 0
		local max = model:GetAttribute("MaxHP") or 1
		gui.Enabled = hp < max and hp > 0
		fill.Size = UDim2.fromScale(math.clamp(hp / max, 0, 1), 1)
	end
	model:GetAttributeChangedSignal("HP"):Connect(update)
	update()
end

function CrateBars.init()
	for _, m in CollectionService:GetTagged("Crate") do
		add(m)
	end
	CollectionService:GetInstanceAddedSignal("Crate"):Connect(add)
end

return CrateBars
