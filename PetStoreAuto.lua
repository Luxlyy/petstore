--// Pet Store Tycoon automations (Rayfield Gen2 UI)
--// Auto restock (owned boxes / buy new), auto care (all enclosures), auto clean floor,
--// auto pamphlets, auto open / close

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
local token = {}
env.PSTAutoToken = token -- re-running the script stops the older loop
local function alive() return env.PSTAutoToken == token end

--// ===== Config =====
local CFG = {
	loopDelay = 1.5,           -- seconds between automation passes
	restockBelow = 3,          -- reorder when a slot's Qty is at/below this
	maxOrdersPerGood = 1,      -- boxes ordered per good per pass (also counts boxes already waiting)
	minCashReserve = 20,       -- never spend below this cash when ordering
	extraGoods = {             -- always keep these ordered even if no slot holds them, {category, name}
		-- {"Equipment", "AquariumFilter"},
	},
	minigameWait = 2.5,        -- wait for "playable" care before completing
	careRetryDelay = 20,       -- seconds to wait before retrying a care action that failed
	pamphletBatch = 5,         -- grab this many pamphlets before handing out
	boxRetryDelay = 15,        -- seconds before retrying a box that couldn't be placed
}

--// ===== Game refs =====
local Remotes = RS:WaitForChild("Remotes")
local Mods = RS:WaitForChild("Modules")
local PlotR, GoodsR, EncR = Remotes.Plot, Remotes.Goods, Remotes.Enclosures
local PamphletsR = Remotes.Pamphlets
local EM = require(Mods.EnclosureMaintenance)
local PDC = require(Mods.PlayerDataClient)
local ShelfRules = require(Mods.ShelfRules)
local ShelfGuideRules = require(Mods.ShelfGuideRules)
local GoodsCatalogue = require(Mods.GoodsCatalogue)
local StoreDayConfig = require(Mods.StoreDayConfig)
local MessConfig = require(Mods.MessConfig)
local MessR = Remotes.Mess

local function log(...) print("[PSTAuto]", ...) end

--// ===== Helpers =====
local function myPlot()
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, p in ipairs(plots:GetChildren()) do
		if p:GetAttribute("OwnerUserId") == LP.UserId then return p end
	end
end

local function hrp()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- Moves next to a position, runs fn, then returns the character to where it was.
local function withNear(pos, fn, reach)
	local r = hrp()
	if not r then return false end
	reach = reach or 10
	local needMove = (r.Position - pos).Magnitude > reach
	local old = r.CFrame
	if needMove then
		r.CFrame = CFrame.new(pos + Vector3.new(0, 3, 4))
		task.wait(0.2)
	end
	local ok, res = pcall(fn)
	if needMove then
		task.wait(0.1)
		r = hrp()
		if r then r.CFrame = old end
	end
	if not ok then log("error:", res) return false end
	return res
end

--// ===== Care: feed / clean / filter / water / play / heat / mist ... (all enclosures) =====
local careCooldown = {}

local function doCare(model, feature, petKey)
	local key = model:GetAttribute("ItemId")
	if typeof(key) ~= "string" then return false end
	local ok, res = pcall(function()
		return EncR.BeginCare:InvokeServer({ itemKey = key, feature = feature, petKey = petKey })
	end)
	if not ok or type(res) ~= "table" or not res.ok then
		if ok and type(res) == "table" then log(feature, "begin refused:", res.reason) end
		return false
	end
	if res.playable then task.wait(CFG.minigameWait) end
	local ok2, res2 = pcall(function()
		return EncR.CompleteCare:InvokeServer({
			quiet = true, itemKey = key, feature = feature, petKey = petKey, token = res.token,
		})
	end)
	if ok2 and type(res2) == "table" and res2.ok then
		log("done:", feature, "on", model.Name)
		return true
	end
	pcall(function() EncR.CancelCare:FireServer(res.token) end)
	log(feature, "complete failed:", ok2 and type(res2) == "table" and res2.reason or res2)
	return false
end

-- "Play" is per animal, so it needs a pet key
local function petKeysFor(model)
	local keys = {}
	for _, k in ipairs(EM.playNeedyKeysOf(model)) do keys[#keys + 1] = k end
	if #keys == 0 then
		local pets = model:FindFirstChild("Pets")
		if pets then
			for _, pet in ipairs(pets:GetChildren()) do
				keys[#keys + 1] = pet:GetAttribute("PetKey") or pet.Name
			end
		end
	end
	return keys
end

local function tryCare(model, feature, petKey)
	local id = tostring(model:GetAttribute("ItemId")) .. "|" .. feature .. "|" .. tostring(petKey)
	if os.clock() < (careCooldown[id] or 0) then return end
	local ok = withNear(model:GetPivot().Position, function()
		return doCare(model, feature, petKey)
	end, 12)
	if not ok then careCooldown[id] = os.clock() + CFG.careRetryDelay end
	task.wait(0.4)
end

local function careAllTask()
	local plot = myPlot()
	local items = plot and plot:FindFirstChild("Items")
	if not items then return end
	for _, model in ipairs(items:GetChildren()) do
		if not alive() then return end
		if typeof(model:GetAttribute("MaintenanceFeatures")) == "string" then
			for _, feature in ipairs(EM.featuresOf(model)) do
				if not alive() then return end
				if EM.isDue(model, feature) then
					if feature == "Play" then
						for _, petKey in ipairs(petKeysFor(model)) do
							tryCare(model, feature, petKey)
						end
					else
						tryCare(model, feature, nil)
					end
				end
			end
		end
	end
end

--// ===== Restock =====
local function splitKey(k)
	local c, n = tostring(k):match("^(.-)/(.+)$")
	return c, n
end

local function goodsBoxes(plot)
	local out = {}
	local folder = plot:FindFirstChild("Boxes")
	if not folder then return out end
	for _, b in ipairs(folder:GetChildren()) do
		if b:IsA("Model") and typeof(b:GetAttribute("BoxKey")) == "string"
			and b:GetAttribute("Kind") == "Goods" then
			table.insert(out, b)
		end
	end
	return out
end

-- Finds the emptiest shelf slot that accepts this box's good, using the game's own rules.
local function findSlot(plot, category, name)
	local item = GoodsCatalogue.find(category, name)
	if not item then return nil end
	local goodKey = GoodsCatalogue.keyOf(category, name)
	local boxQty = ShelfRules.boxQuantityOf(item)
	local shelves = (PDC.getGoods() or {}).Shelves or {}
	local items = plot:FindFirstChild("Items")
	if not items then return nil end
	local best, bestQty
	for _, shelf in ipairs(items:GetChildren()) do
		local shelfKey = shelf:GetAttribute("ItemId")
		local okA, accepts = pcall(ShelfRules.acceptsGood, shelf, item)
		if okA and accepts and typeof(shelfKey) == "string" then
			local data = shelves[shelfKey]
			for _, slot in ipairs(ShelfRules.slotModels(shelf)) do
				local idx = slot:GetAttribute(ShelfRules.SLOT_INDEX_ATTR)
				if typeof(idx) == "number" then
					local s = type(data) == "table" and data[tostring(idx)] or nil
					local view = {
						good = type(s) == "table" and s.Good or nil,
						qty = type(s) == "table" and type(s.Qty) == "number" and s.Qty or 0,
					}
					if ShelfGuideRules.targetable(view, goodKey, boxQty) and (not bestQty or view.qty < bestQty) then
						best, bestQty = { shelfKey, idx, shelf }, view.qty
					end
				end
			end
		end
	end
	if best then return best[1], best[2], best[3] end
end

local function placeBox(plot, box)
	local category, name = box:GetAttribute("Category"), box:GetAttribute("GoodName")
	if typeof(category) ~= "string" or typeof(name) ~= "string" then return false end
	local shelfKey, idx, shelf = findSlot(plot, category, name)
	if not shelfKey then return false end
	local boxKey = box:GetAttribute("BoxKey")

	local picked = withNear(box:GetPivot().Position, function()
		GoodsR.PickUpBox:FireServer(boxKey)
		local t = os.clock()
		while os.clock() - t < 3 do
			if box:GetAttribute("Carrier") == LP.UserId then return true end
			task.wait(0.1)
		end
		return false
	end, 10)
	if not picked then
		pcall(function() GoodsR.DropBox:FireServer() end)
		return false
	end

	local ok = withNear(shelf:GetPivot().Position, function()
		local okc, res = pcall(function()
			return GoodsR.PlaceGoods:InvokeServer(boxKey, shelfKey, idx)
		end)
		return okc and res ~= false and res ~= nil
	end, 10)
	if not ok then pcall(function() GoodsR.DropBox:FireServer() end) end
	log(ok and "stocked" or "place failed:", category .. "/" .. name)
	return ok
end

local boxCooldown = {}

-- Places boxes you already own (loose in the store or stowed on racks) onto shelves. Spends no money.
local function placeOwnedBoxes(plot)
	for _, box in ipairs(goodsBoxes(plot)) do
		if not alive() then return end
		local key = box:GetAttribute("BoxKey")
		if box:GetAttribute("Carrier") == nil and os.clock() >= (boxCooldown[key] or 0) then
			if not placeBox(plot, box) then boxCooldown[key] = os.clock() + CFG.boxRetryDelay end
			task.wait(0.3)
		end
	end
end

local function ownedRestockTask()
	local plot = myPlot()
	if plot then placeOwnedBoxes(plot) end
end

local function restockTask()
	local plot = myPlot()
	if not plot then return end

	-- 1) place any boxes you already own
	placeOwnedBoxes(plot)

	-- 2) order more for low slots
	local wanted = {}
	local shelves = (PDC.getGoods() or {}).Shelves or {}
	for _, slots in pairs(shelves) do
		for _, s in pairs(slots) do
			if type(s) == "table" and s.Good and (s.Qty or 0) <= CFG.restockBelow then
				wanted[s.Good] = true
			end
		end
	end
	for _, g in ipairs(CFG.extraGoods) do wanted[g[1] .. "/" .. g[2]] = true end

	local pending = {}
	for _, b in ipairs(goodsBoxes(plot)) do
		local k = tostring(b:GetAttribute("Category")) .. "/" .. tostring(b:GetAttribute("GoodName"))
		pending[k] = (pending[k] or 0) + 1
	end

	for good in pairs(wanted) do
		local category, name = splitKey(good)
		if category and (pending[good] or 0) < CFG.maxOrdersPerGood then
			if (PDC.getCash() or 0) > CFG.minCashReserve then
				local ok, res, reason = pcall(function()
					return GoodsR.PurchaseGood:InvokeServer(category, name)
				end)
				if ok and res == true then log("ordered", good)
				else log("order failed:", good, reason) end
				task.wait(0.4)
			end
		end
	end
end

--// ===== Open / close =====
local lastToggle = 0
local function openTask()
	local plot = myPlot()
	if not plot or plot:GetAttribute("StoreOpen") == true then return end
	if os.clock() - lastToggle < 6 then return end
	lastToggle = os.clock()
	local sign = plot:FindFirstChild("OpenSign")
	if not sign then return end
	withNear(sign:GetPivot().Position, function() PlotR.OpenStore:FireServer() return true end, 8)
	log("open requested")
end

local function closeTask()
	local plot = myPlot()
	if not plot then return end
	if plot:GetAttribute("StoreOpen") ~= true or plot:GetAttribute("DoorsLocked") == true then return end
	local okH, hour = pcall(StoreDayConfig.hourOfPlot, plot)
	if not (okH and type(hour) == "number" and hour >= StoreDayConfig.CUSTOMER_CUTOFF_HOUR) then return end
	if os.clock() - lastToggle < 6 then return end
	lastToggle = os.clock()
	local sign = plot:FindFirstChild("OpenSign")
	if not sign then return end
	withNear(sign:GetPivot().Position, function() PlotR.ToggleDoors:FireServer() return true end, 8)
	log("close requested")
end

--// ===== Clean floor (spills, litter, toppled toys) =====
local messCooldown = {}

local function cleanFloorTask()
	local plot = myPlot()
	local folder = plot and plot:FindFirstChild(MessConfig.FOLDER_NAME)
	if not folder then return end
	for _, mess in ipairs(folder:GetChildren()) do
		if not alive() then return end
		local id = mess:GetAttribute(MessConfig.ATTR_ID)
		if mess:IsA("Model") and typeof(id) == "string" and mess:GetAttribute("MessCleaned") ~= true
			and os.clock() >= (messCooldown[id] or 0) then
			messCooldown[id] = os.clock() + 8 -- don't spam if the server ignores it
			local kind = MessConfig.get(mess:GetAttribute(MessConfig.ATTR_KIND))
			local hold = (kind and kind.holdSeconds) or 3
			withNear(mess:GetPivot().Position, function()
				task.wait(hold + 0.3) -- same hold time the game uses for sweeping / mopping
				MessR.Clean:FireServer({ messId = id })
				task.wait(0.4)
				return true
			end, 8)
			log("cleaned", mess.Name)
		end
	end
end

--// ===== Pamphlets =====
local givenAt = {}

-- Pedestrians are tracked privately by the game, so sweep rays with its own helper to find them.
local function findWalkers(center, y)
	local PC = require(Mods.PedestrianController)
	local found = {}
	local origin = Vector3.new(center.X, y, center.Z)
	for deg = 0, 352, 8 do
		local rad = math.rad(deg)
		local dir = Vector3.new(math.cos(rad), 0, math.sin(rad))
		local ok, id, pos = pcall(PC.walkerNearRay, origin, dir, center, 40, 2.5)
		if ok and id and pos and not found[id] then found[id] = pos end
	end
	return found
end

local function pamphletTask()
	local plot = myPlot()
	if not plot then return end

	-- out of pamphlets: grab a full batch from the stand first
	if (LP:GetAttribute("Pamphlets") or 0) <= 0 then
		if (plot:GetAttribute("PamphletsRemaining") or 0) <= 0 then return end
		local items = plot:FindFirstChild("Items")
		local stand = plot:FindFirstChild("PamphletStand") or (items and items:FindFirstChild("PamphletStand"))
		if not stand then return end
		withNear(stand:GetPivot().Position, function()
			local stalled = 0
			for _ = 1, 12 do
				local before = LP:GetAttribute("Pamphlets") or 0
				if before >= CFG.pamphletBatch or not alive() then break end
				PamphletsR.Grab:FireServer()
				task.wait(0.4)
				if (LP:GetAttribute("Pamphlets") or 0) <= before then
					stalled += 1
					if stalled >= 3 then break end
				else
					stalled = 0
				end
			end
			log("holding", LP:GetAttribute("Pamphlets") or 0, "pamphlets")
			return true
		end, 8)
		return
	end

	-- hand them out to passers-by near the store
	local r = hrp()
	if not r then return end
	local sign = plot:FindFirstChild("OpenSign")
	local center = sign and sign:GetPivot().Position or r.Position
	local walkers = findWalkers(center, r.Position.Y)
	local now, gave = os.clock(), 0
	for id, pos in pairs(walkers) do
		if gave >= 3 or not alive() or (LP:GetAttribute("Pamphlets") or 0) <= 0 then break end
		if not givenAt[id] or now - givenAt[id] > 30 then
			givenAt[id] = now
			withNear(pos, function()
				PamphletsR.Give:FireServer(id)
				task.wait(0.4)
				return true
			end, 6)
			gave += 1
			task.wait(0.5)
		end
	end
	if gave > 0 then log("handed out", gave, "pamphlet(s)") end
end

--// ===== Next day (after the summary appears) =====
local nextDayConn
local function setAutoNextDay(on)
	if nextDayConn then nextDayConn:Disconnect() nextDayConn = nil end
	if on then
		nextDayConn = Remotes.UI.DaySummary.OnClientEvent:Connect(function()
			task.delay(3, function()
				if alive() then PlotR.StartNextDay:FireServer() end
			end)
		end)
	end
end

--// ===== Scheduler =====
local flags = {}
local tasks = {
	{ "close",   closeTask },
	{ "open",    openTask },
	{ "clean",   cleanFloorTask },
	{ "care",    careAllTask },
	{ "owned",   function() if not flags.restock then ownedRestockTask() end end },
	{ "restock", restockTask },
	{ "pamphlet", pamphletTask },
}

task.spawn(function()
	while alive() do
		for _, t in ipairs(tasks) do
			if not alive() then break end
			if flags[t[1]] then
				local ok, err = pcall(t[2])
				if not ok then log(t[1], "error:", err) end
			end
		end
		task.wait(CFG.loopDelay)
	end
end)

--// ===== UI =====
-- remove a window left over from a previous run of this script
pcall(function()
	local root = (gethui and gethui()) or game:GetService("CoreGui")
	for _, holder in ipairs({ root, game:GetService("CoreGui"):FindFirstChild("RobloxGui") }) do
		if holder then
			for _, g in ipairs(holder:GetChildren()) do
				for _, d in ipairs(g:GetDescendants()) do
					if d:IsA("TextLabel") and d.Text:find("^Auto Restock") then g:Destroy() break end
				end
			end
		end
	end
end)

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local window = Rayfield:CreateWindow({
	name = "Pet Store Tycoon",
	subtitle = "Automations",
	sidebarLayout = true,
})

local tab = window:CreateTab({ name = "Home", icon = 93364949241311 })

local function toggle(name, flag)
	tab:CreateToggle({ name = name, callback = function(v) flags[flag] = v end })
end

toggle("Auto Restock (Owned Items Only)", "owned")
toggle("Auto Restock (Buy New)",         "restock")
toggle("Auto Care (All Enclosures)", "care")
toggle("Auto Clean Floor",       "clean")
toggle("Auto Pamphlets",         "pamphlet")
toggle("Auto Open Store",       "open")
toggle("Auto Close Store",      "close")
tab:CreateToggle({ name = "Auto Next Day", callback = setAutoNextDay })

log("loaded")
