local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local globalEnvironment = (getgenv and getgenv()) or _G
local previousCleanup = globalEnvironment.__BEANO_GUI_CLEANUP
if type(previousCleanup) == "function" then
	pcall(previousCleanup)
end
globalEnvironment.__BEANO_GUI_CLEANUP = nil
local existingGui = playerGui:FindFirstChild("SpeedController")
if existingGui then
	existingGui:Destroy()
end
local legacyGui = playerGui:FindFirstChild("StudioSpeedController")
if legacyGui then
	legacyGui:Destroy()
end
local existingTradeGui = playerGui:FindFirstChild("SupremeTradeCalculator")
if existingTradeGui then
	existingTradeGui:Destroy()
end
local targetSpeed = 16
local minimumSpeed = 0
local maximumSpeed = 200
local targetJumpHeight = 7.2
local minimumJumpHeight = 0
local maximumJumpHeight = 100
local connections = {}
local stopped = false
local tradeGui = nil
local mainWindow = nil
local roleHighlights = {}
local roleHighlightsEnabled = false
local roleChamsEnabled = true
local roleNamesEnabled = true
local roleLinesEnabled = false
local roleShownCount = 0
local droppedGunHighlight = nil
local autoPickupGunEnabled = false
local cachedDroppedGun = nil
local gunScanRequested = true
local rayfieldInterface = nil
local gameTradeSummary = nil
local trackedRoundActive = false
local trackedRoundStartedAt = 0
local trackedSheriff = nil
local trackedInnocents = {}
local trackedMurderers = {}
local trackedHeroes = {}
local lastRoleToolSeenAt = 0
local roleGracePeriod = 4
local movementLockEnabled = true
local movementApplyInterval = 0.1
local roleRefreshInterval = 0.75
local gunCheckInterval = 0.35
local gunChamEnabled = true
local roleFillTransparency = 0.45
local roleOutlineTransparency = 0
local roleLineWidth = 0.12
local gunFillTransparency = 0.2
local gunPickupCooldown = 0.75
local lastGunPickupAttempt = 0
local gunPickupInProgress = false
local tradeOverlayEnabled = true
local tradeOverlayPosition = "Top"
local lastTradeYourValue = 0
local lastTradeTheirValue = 0
local lastTradeAverageDemand = 0
local selectedPlayer = nil
local spectatingPlayer = nil
local flingInProgress = false
local interfaceReady = false
local killAuraEnabled = false
local killAuraRadius = 14
local killAuraInterval = 0.15
local coinAuraEnabled = false
local coinAuraRadius = 10
local coinAuraInterval = 0.2
local coinAuraMaxPerTick = 8
local coinCandidates = {}
local coinCacheBuilt = false
local silentState = {
	Enabled = false,
	TeamCheck = false,
	VisibleCheck = false,
	TargetPart = "HumanoidRootPart",
	Method = "Gun remote",
	FOVRadius = 130,
	FOVVisible = false,
	ShowTarget = false,
	Prediction = false,
	PredictionAmount = 0.165,
	HitChance = 100,
	ShootMurdererEnabled = false,
	ShootCooldown = 1,
	ShootBusy = false,
	LastShotAt = 0,
	ForcedTarget = nil,
}
local silentDrawings = {}
local legacySilentState = {Enabled = false}
local GUN_DROP_NAMES = {"GunDrop", "DroppedGun", "Gun"}
local function getHumanoid()
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end
local function applySpeed()
	local humanoid = getHumanoid()
	if humanoid and humanoid.WalkSpeed ~= targetSpeed then
		humanoid.WalkSpeed = targetSpeed
	end
end
local function applyJumpHeight()
	local humanoid = getHumanoid()
	if humanoid then
		if humanoid.UseJumpPower then
			humanoid.UseJumpPower = false
		end
		if humanoid.JumpHeight ~= targetJumpHeight then
			humanoid.JumpHeight = targetJumpHeight
		end
	end
end
local gui = Instance.new("ScreenGui")
gui.Name = "BeanoInternalState"
gui.Enabled = false
local frame = Instance.new("Frame")
local function stopScript()
	if stopped then
		return
	end
	stopped = true
	interfaceReady = false
	pcall(function()
		if rayfieldInterface then
			rayfieldInterface:Destroy()
		end
	end)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	table.clear(connections)
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local character = targetPlayer.Character
		if character then
			for _, child in ipairs(character:GetDescendants()) do
				if child.Name == "RoleHighlight" or child.Name == "RoleLabel"
					or child.Name == "StudioRoleHighlight" or child.Name == "StudioRoleLabel"
					or child.Name == "RoleLine" or child.Name == "RoleLineOrigin"
					or child.Name == "RoleLineTarget" then
					child:Destroy()
				end
			end
		end
	end
	for _, entry in pairs(roleHighlights) do
		for _, key in ipairs({"beam", "originAttachment", "targetAttachment", "highlight", "label"}) do
			local instance = entry[key]
			if instance and instance.Parent then
				instance:Destroy()
			end
		end
	end
	table.clear(roleHighlights)
	if droppedGunHighlight and droppedGunHighlight.Parent then
		droppedGunHighlight:Destroy()
	end
	droppedGunHighlight = nil
	cachedDroppedGun = nil
	gunScanRequested = false
	gunPickupInProgress = false
	if gameTradeSummary and gameTradeSummary.Parent then
		gameTradeSummary:Destroy()
	end
	gameTradeSummary = nil
	flingInProgress = false
	spectatingPlayer = nil
	killAuraEnabled = false
	coinAuraEnabled = false
	table.clear(coinCandidates)
	silentState.Enabled = false
	silentState.ShootMurdererEnabled = false
	silentState.ShootBusy = false
	silentState.ForcedTarget = nil
	if globalEnvironment.__BEANO_SAFE_SILENT_STATE == silentState then
		globalEnvironment.__BEANO_SAFE_SILENT_STATE = nil
	end
	if globalEnvironment.__BEANO_SILENT_STATE == legacySilentState then
		globalEnvironment.__BEANO_SILENT_STATE = nil
	end
	for _, drawing in pairs(silentDrawings) do
		pcall(function()
			drawing:Remove()
		end)
	end
	table.clear(silentDrawings)
	pcall(function()
		local camera = Workspace.CurrentCamera
		local humanoid = getHumanoid()
		if camera and humanoid then
			camera.CameraSubject = humanoid
		end
	end)
	if globalEnvironment.__BEANO_GUI_CLEANUP == stopScript then
		globalEnvironment.__BEANO_GUI_CLEANUP = nil
	end
	if gui then
		gui:Destroy()
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		if child.Name:sub(1, 13) == "BeanoMiniGame" then
			child:Destroy()
		end
	end
	tradeGui = nil
	pcall(function()
		if script and script.Destroy then
			script:Destroy()
		end
	end)
end
table.insert(connections, player.CharacterAdded:Connect(function(character)
	character:WaitForChild("Humanoid", 5)
	applySpeed()
	applyJumpHeight()
end))
local movementApplyElapsed = 0
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
	if not interfaceReady or not movementLockEnabled then
		return
	end
	movementApplyElapsed += deltaTime
	if movementApplyElapsed >= movementApplyInterval then
		movementApplyElapsed = 0
		applySpeed()
		applyJumpHeight()
	end
end))
applySpeed()
applyJumpHeight()
local tradeDatabase = {
	Updated = "Unavailable",
	Values = {},
	Demands = {},
	CategoryValues = {},
	CategoryDemands = {},
	Aliases = {},
}
do
	local databaseUrl = "https://raw.githubusercontent.com/BeANo20/beano-gui/main/mm2-trade-data.lua"
	local downloadSuccess, databaseSource = pcall(function()
		return game:HttpGet(databaseUrl .. "?v=" .. tostring(os.time()), true)
	end)
	if downloadSuccess and type(databaseSource) == "string" and #databaseSource > 20 and type(loadstring) == "function" then
		local databaseChunk, databaseCompileError = loadstring(databaseSource, "=Beano MM2 Trade Database")
		if type(databaseChunk) == "function" then
			local runSuccess, loadedDatabase = pcall(databaseChunk)
			if runSuccess and type(loadedDatabase) == "table" then
				tradeDatabase = loadedDatabase
			else
				warn("Beano MM2 trade database runtime error: " .. tostring(loadedDatabase))
			end
		else
			warn("Beano MM2 trade database compile error: " .. tostring(databaseCompileError))
		end
	else
		warn("Beano MM2 trade database download failed: " .. tostring(databaseSource))
	end
end
local normalizedValues = {}
local sortedValueNames = {}
local function normalizeItemName(rawName)
	local normalized = tostring(rawName):gsub("(%l)(%u)", "%1 %2")
	normalized = string.lower(normalized)
	normalized = normalized:gsub("c%.", "c")
	normalized = normalized:gsub("[^%w%s]", " ")
	normalized = normalized:gsub("%s+", " ")
	normalized = normalized:match("^%s*(.-)%s*$") or ""
	if normalized:sub(1, 2) == "c " then
		normalized = "chroma " .. normalized:sub(3)
	end
	return normalized
end
local function formatValue(value)
	local formatted = tostring(math.floor(value))
	while true do
		local updated, replacements = formatted:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
		formatted = updated
		if replacements == 0 then
			break
		end
	end
	return formatted
end
local function normalizeCategory(rawCategory)
	return string.lower(tostring(rawCategory or "")):gsub("[^%w]", "")
end
for itemName, value in pairs(tradeDatabase.Values) do
	local normalizedName = normalizeItemName(itemName)
	normalizedValues[normalizedName] = { name = itemName, value = value }
	table.insert(sortedValueNames, itemName)
end
table.sort(sortedValueNames, function(left, right)
	return #left > #right
end)
local function lookupValue(itemName, category)
	local normalizedName = normalizeItemName(itemName)
	if normalizedName:find("batwing", 1, true) then
		normalizedName = "batwing"
	end
	normalizedName = tradeDatabase.Aliases[normalizedName] or normalizedName
	local categoryEntries = tradeDatabase.CategoryValues[normalizedName]
	if categoryEntries then
		local normalizedCategory = normalizeCategory(category)
		if normalizedCategory ~= "" and categoryEntries[normalizedCategory] then
			return categoryEntries[normalizedCategory]
		end
		if normalizedName == "batwing" then
			return categoryEntries.ancient
		end
		local fallback = normalizedValues[normalizedName]
		if fallback and type(fallback.value) == "number" then
			return fallback
		end
		if normalizedCategory ~= "" then
			return nil
		end
		return { name = itemName, value = nil, ambiguous = true }
	end
	return normalizedValues[normalizedName]
end
local function lookupDemand(itemName, category)
	local normalizedName = normalizeItemName(itemName)
	if normalizedName:find("batwing", 1, true) then
		normalizedName = "batwing"
	end
	normalizedName = tradeDatabase.Aliases[normalizedName] or normalizedName
	local categoryEntries = tradeDatabase.CategoryDemands[normalizedName]
	if categoryEntries then
		local normalizedCategory = normalizeCategory(category)
		if normalizedCategory ~= "" and categoryEntries[normalizedCategory] then
			return categoryEntries[normalizedCategory]
		end
		if normalizedName == "batwing" then
			return categoryEntries.ancient
		end
		return tradeDatabase.Demands[normalizedName]
	end
	return tradeDatabase.Demands[normalizedName]
end
local function parseItemList(rawText)
	local total = 0
	local found = {}
	local unknown = {}
	local demandSum = 0
	local demandCount = 0
	for token in string.gmatch(rawText or "", "[^,\n]+") do
		local itemName = token:match("^%s*(.-)%s*$")
		local quantity = tonumber(itemName:match("^(%d+)%s*[xX]%s+")) or 1
		itemName = itemName:gsub("^%d+%s*[xX]%s+", "")
		local trailingQuantity = tonumber(itemName:match("%s+[xX]%s*(%d+)%s*$"))
		if trailingQuantity then
			quantity = trailingQuantity
			itemName = itemName:gsub("%s+[xX]%s*%d+%s*$", "")
		end
		local entry = lookupValue(itemName)
		if entry and type(entry.value) == "number" then
			total += entry.value * quantity
			table.insert(found, ("%dx %s = %s"):format(quantity, entry.name, formatValue(entry.value * quantity)))
			local demand = lookupDemand(itemName)
			if demand then
				demandSum += demand * quantity
				demandCount += quantity
			end
		elseif entry and entry.value == "Priceless" then
			table.insert(unknown, itemName .. " (Priceless)")
			local demand = lookupDemand(itemName)
			if demand then
				demandSum += demand * quantity
				demandCount += quantity
			end
		elseif entry and entry.ambiguous then
			table.insert(unknown, itemName .. " (choose a category)")
		elseif itemName ~= "" then
			table.insert(unknown, itemName)
		end
	end
	return total, found, unknown, demandSum, demandCount
end
local function findTradeSide(instance)
	local current = instance.Parent
	local hasTradeRoot = false
	local hasOfferRoot = false
	local isInventoryUi = false
	local side = "Other"
	local tradeRoot = nil
	for _ = 1, 8 do
		if not current then
			break
		end
		local name = normalizeItemName(current.Name)
		if current:IsA("GuiObject") and not current.Visible then
			return false, side
		end
		if name:find("trade", 1, true) then
			hasTradeRoot = true
			tradeRoot = current
		end
		if name:find("offer", 1, true) then
			hasOfferRoot = true
		end
		if name:find("inventory", 1, true) or name:find("backpack", 1, true) or name:find("collection", 1, true) then
			isInventoryUi = true
		end
		if name:find("your", 1, true) or name:find("my", 1, true) or name:find("left", 1, true) then
			side = "You"
		elseif name:find("their", 1, true) or name:find("other", 1, true) or name:find("opponent", 1, true) or name:find("right", 1, true) then
			side = "Them"
		end
		current = current.Parent
	end
	return hasTradeRoot and hasOfferRoot and not isInventoryUi, side, tradeRoot
end
local function scanVisibleTrade()
	local totals = { You = 0, Them = 0, Other = 0 }
	local names = { You = {}, Them = {}, Other = {} }
	local yourHeading = nil
	local theirHeading = nil
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Visible then
			local text = normalizeItemName(descendant.Text)
			if text == "your offer" then
				yourHeading = descendant
			elseif text == "their offer" then
				theirHeading = descendant
			end
		end
	end
	local function hasChromaMarker(label)
		local current = label.Parent
		for _ = 1, 3 do
			if not current then
				break
			end
			for _, sibling in ipairs(current:GetChildren()) do
				if sibling ~= label and sibling:IsA("TextLabel") then
					local siblingText = normalizeItemName(sibling.Text)
					if siblingText == "chroma" or siblingText:find("^chroma ") then
						return true
					end
				end
			end
			current = current.Parent
		end
		return false
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("TextLabel") and descendant.Visible then
			local isTradeUi, side = findTradeSide(descendant)
			if not isTradeUi and yourHeading and theirHeading then
				local position = descendant.AbsolutePosition
				local minimumOfferX = math.min(yourHeading.AbsolutePosition.X, theirHeading.AbsolutePosition.X) - 16
				if position.X >= minimumOfferX and position.Y > yourHeading.AbsolutePosition.Y then
					isTradeUi = true
					side = position.Y < theirHeading.AbsolutePosition.Y and "You" or "Them"
				end
			end
			if isTradeUi then
				local rawText = descendant.Text
				local normalizedText = normalizeItemName(descendant.Text)
				normalizedText = normalizedText:gsub("^%d+%s*x%s+", "")
				normalizedText = normalizedText:gsub("%s+x%s*%d+$", "")
				local entry = normalizedValues[normalizedText]
				local displayName = entry and entry.name or descendant.Text
				if entry and hasChromaMarker(descendant) and not normalizedText:find("^chroma ") then
					local chromaEntry = normalizedValues[normalizeItemName("Chroma " .. displayName)]
					if chromaEntry and type(chromaEntry.value) == "number" then
						entry = chromaEntry
						displayName = chromaEntry.name
					end
				end
				if entry and type(entry.value) == "number" then
					local quantity = tonumber(rawText:match("^(%d+)%s*[xX]"))
						or tonumber(rawText:match("[xX]%s*(%d+)%s*$"))
						or 1
					totals[side] += entry.value * quantity
					local prefix = quantity > 1 and (tostring(quantity) .. "x ") or ""
					table.insert(names[side], prefix .. displayName)
				end
			end
		end
	end
	return totals, names
end
tradeGui = gui
local function internalInstance(className, parent)
	local instance = Instance.new(className)
	instance.Parent = parent or gui
	return instance
end
mainWindow = internalInstance("Frame")
local tradeFrame = internalInstance("Frame", mainWindow)
local settingsPanel = internalInstance("Frame", mainWindow)
settingsPanel.Visible = false
local playerPanel = internalInstance("Frame", mainWindow)
playerPanel.Visible = false
local sidebar = internalInstance("Frame", mainWindow)
local contentArea = internalInstance("Frame", mainWindow)
local pageTitle = internalInstance("TextLabel", mainWindow)
pageTitle.Text = "Main"
frame.Parent = mainWindow
local function roundButton(button)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = button
end
local tradeUpdated = internalInstance("TextLabel", tradeFrame)
tradeUpdated.Text = "Supreme snapshot: " .. tradeDatabase.Updated
local tradeValueSummary = internalInstance("TextLabel", tradeFrame)
tradeValueSummary.Text = "Your value: 0 | Their value: 0 | Demand: 0/10"
local yourItemsInput = internalInstance("TextBox", tradeFrame)
local theirItemsInput = internalInstance("TextBox", tradeFrame)
local calculateTradeButton = internalInstance("TextButton", tradeFrame)
local scanTradeButton = internalInstance("TextButton", tradeFrame)
scanTradeButton.Visible = false
local tradeResult = internalInstance("TextLabel", tradeFrame)
tradeResult.Text = "Enter items separated by commas, or scan an open trade."
local playerInfo = internalInstance("TextLabel", playerPanel)
local roleHighlightButton = internalInstance("TextButton", playerPanel)
local roleHighlightStatus = internalInstance("TextLabel", playerPanel)
local roleChamsButton = internalInstance("TextButton", playerPanel)
local roleNamesButton = internalInstance("TextButton", playerPanel)
local roleLinesButton = internalInstance("TextButton", playerPanel)
local teleportSheriffButton = internalInstance("TextButton", playerPanel)
local teleportMurdererButton = internalInstance("TextButton", playerPanel)
local autoPickupGunButton = internalInstance("TextButton", playerPanel)
local function refreshPlayerInfo()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	playerInfo.Text = "Username: " .. player.Name
		.. "\nDisplay name: " .. player.DisplayName
		.. "\nCharacter: " .. (character and "loaded" or "not loaded")
		.. "\nWalkSpeed: " .. (humanoid and tostring(humanoid.WalkSpeed) or "n/a")
		.. "\nJumpHeight: " .. (humanoid and tostring(humanoid.JumpHeight) or "n/a")
end
refreshPlayerInfo()
local function playerHasTool(targetPlayer, toolName)
	local character = targetPlayer.Character
	local backpack = targetPlayer:FindFirstChild("Backpack")
	return (character and character:FindFirstChild(toolName) ~= nil)
		or (backpack and backpack:FindFirstChild(toolName) ~= nil)
end
local function readRole(targetPlayer)
	if playerHasTool(targetPlayer, "Knife") then
		return "Murderer"
	end
	if trackedRoundActive and trackedHeroes[targetPlayer] then
		return "Hero"
	end
	local role = targetPlayer:GetAttribute("Role")
		or targetPlayer:GetAttribute("TeamRole")
		or targetPlayer:GetAttribute("PlayerRole")
	if type(role) == "string" and role ~= "" then
		return role
	end
	local roleValue = targetPlayer:FindFirstChild("Role") or targetPlayer:FindFirstChild("TeamRole")
	if roleValue and roleValue:IsA("StringValue") and roleValue.Value ~= "" then
		return roleValue.Value
	end
	local character = targetPlayer.Character
	if character then
		local characterRole = character:GetAttribute("Role") or character:GetAttribute("TeamRole")
		if type(characterRole) == "string" and characterRole ~= "" then
			return characterRole
		end
		local characterRoleValue = character:FindFirstChild("Role") or character:FindFirstChild("TeamRole")
		if characterRoleValue and characterRoleValue:IsA("StringValue") and characterRoleValue.Value ~= "" then
			return characterRoleValue.Value
		end
	end
	local hasGun = playerHasTool(targetPlayer, "Gun")
	if hasGun then
		if trackedSheriff == targetPlayer then
			return "Sheriff"
		end
		if trackedRoundActive
			and trackedSheriff ~= nil
			and os.clock() - trackedRoundStartedAt > roleGracePeriod
			and trackedInnocents[targetPlayer] then
			return "Hero"
		end
		return "Gun Holder"
	end
	return "Innocent"
end
local function updateRoundRoleTracking()
	local now = os.clock()
	local sawRoleTool = false
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if playerHasTool(targetPlayer, "Knife") or playerHasTool(targetPlayer, "Gun") then
			sawRoleTool = true
			break
		end
	end
	if not sawRoleTool then
		if trackedRoundActive and now - lastRoleToolSeenAt >= 2 then
			trackedRoundActive = false
			trackedSheriff = nil
			table.clear(trackedInnocents)
			table.clear(trackedMurderers)
			table.clear(trackedHeroes)
		end
		return
	end
	lastRoleToolSeenAt = now
	if not trackedRoundActive then
		trackedRoundActive = true
		trackedRoundStartedAt = now
		trackedSheriff = nil
		table.clear(trackedInnocents)
		table.clear(trackedMurderers)
		table.clear(trackedHeroes)
	end
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local hasKnife = playerHasTool(targetPlayer, "Knife")
		local hasGun = playerHasTool(targetPlayer, "Gun")
		if hasKnife then
			trackedMurderers[targetPlayer] = true
		elseif hasGun
			and trackedSheriff
			and targetPlayer ~= trackedSheriff
			and trackedInnocents[targetPlayer]
			and now - trackedRoundStartedAt > roleGracePeriod then
			trackedHeroes[targetPlayer] = true
		elseif not hasGun and not trackedMurderers[targetPlayer] then
			trackedInnocents[targetPlayer] = true
		elseif hasGun and not trackedSheriff and now - trackedRoundStartedAt <= roleGracePeriod then
			trackedSheriff = targetPlayer
		end
	end
end
local function executorTouchFunction()
	local environment = (getgenv and getgenv()) or _G
	return type(environment.firetouchinterest) == "function" and environment.firetouchinterest or nil
end
local function runKillAura()
	if not killAuraEnabled or not interfaceReady or flingInProgress then
		return
	end
	local character = player.Character
	local localRoot = character and character:FindFirstChild("HumanoidRootPart")
	local knife = character and character:FindFirstChild("Knife")
	local knifeHandle = knife and (knife:FindFirstChild("Handle") or knife:FindFirstChildWhichIsA("BasePart"))
	local touchFunction = executorTouchFunction()
	if not localRoot or not knifeHandle or not touchFunction or readRole(player) ~= "Murderer" then
		return
	end
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then
			local targetCharacter = targetPlayer.Character
			local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
			local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
			if targetHumanoid and targetHumanoid.Health > 0 and targetRoot
				and (targetRoot.Position - localRoot.Position).Magnitude <= killAuraRadius then
				pcall(touchFunction, knifeHandle, targetRoot, 0)
				pcall(touchFunction, knifeHandle, targetRoot, 1)
			end
		end
	end
end
local function isCoinPart(instance)
	if not instance:IsA("BasePart") then
		return false
	end
	local normalizedName = string.lower(instance.Name):gsub("[%s_%-]", "")
	local parentName = instance.Parent and string.lower(instance.Parent.Name):gsub("[%s_%-]", "") or ""
	return normalizedName == "coin"
		or normalizedName == "coinserver"
		or normalizedName == "coinpart"
		or parentName == "coincontainer"
		or instance:GetAttribute("CoinID") ~= nil
end
local function addCoinCandidate(instance)
	if isCoinPart(instance) then
		coinCandidates[instance] = true
	end
end
local function rebuildCoinCache()
	if coinCacheBuilt then
		return
	end
	coinCacheBuilt = true
	table.clear(coinCandidates)
	local descendants = Workspace:GetDescendants()
	for index, instance in ipairs(descendants) do
		addCoinCandidate(instance)
		if index % 250 == 0 then
			task.wait()
		end
	end
end
local function runCoinAura()
	if not coinAuraEnabled or not interfaceReady or flingInProgress then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local touchFunction = executorTouchFunction()
	if not root or not touchFunction then
		return
	end
	local collected = 0
	for coinPart in pairs(coinCandidates) do
		if not coinPart.Parent then
			coinCandidates[coinPart] = nil
		elseif (coinPart.Position - root.Position).Magnitude <= coinAuraRadius then
			pcall(touchFunction, root, coinPart, 0)
			pcall(touchFunction, root, coinPart, 1)
			collected += 1
			if collected >= coinAuraMaxPerTick then
				break
			end
		end
	end
end
table.insert(connections, Workspace.DescendantAdded:Connect(function(instance)
	if coinAuraEnabled then
		addCoinCandidate(instance)
	end
end))
table.insert(connections, Workspace.DescendantRemoving:Connect(function(instance)
	coinCandidates[instance] = nil
end))
local killAuraElapsed = 0
local coinAuraElapsed = 0
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
	if stopped then
		return
	end
	if killAuraEnabled then
		killAuraElapsed += deltaTime
		if killAuraElapsed >= killAuraInterval then
			killAuraElapsed = 0
			runKillAura()
		end
	else
		killAuraElapsed = 0
	end
	if coinAuraEnabled then
		coinAuraElapsed += deltaTime
		if coinAuraElapsed >= coinAuraInterval then
			coinAuraElapsed = 0
			runCoinAura()
		end
	else
		coinAuraElapsed = 0
	end
end))
local function silentEquippedGunRemote()
	local character = player.Character
	local gun = character and character:FindFirstChild("Gun")
	if not gun or not gun:IsA("Tool") then
		return nil
	end
	local knifeLocal = gun:FindFirstChild("KnifeLocal", true)
	local createBeam = knifeLocal and knifeLocal:FindFirstChild("CreateBeam", true)
	local knownRemote = createBeam and createBeam:FindFirstChild("RemoteFunction", true)
	if knownRemote and (knownRemote:IsA("RemoteFunction") or knownRemote:IsA("RemoteEvent")) then
		return knownRemote
	end
	for _, descendant in ipairs(gun:GetDescendants()) do
		if descendant:IsA("RemoteFunction") or descendant:IsA("RemoteEvent") then
			return descendant
		end
	end
	return nil
end
local function silentTargetPosition(targetPart, state)
	local position = targetPart.Position
	if state.Prediction then
		position += targetPart.AssemblyLinearVelocity * state.PredictionAmount
	end
	return position
end
local function silentIsVisible(targetPart)
	local camera = Workspace.CurrentCamera
	local localCharacter = player.Character
	local targetCharacter = targetPart and targetPart:FindFirstAncestorOfClass("Model")
	if not camera or not localCharacter or not targetCharacter then
		return false
	end
	local obscuring = camera:GetPartsObscuringTarget({targetPart.Position}, {localCharacter, targetCharacter})
	return #obscuring == 0
end
local function silentClosestTarget()
	local state = silentState
	local camera = Workspace.CurrentCamera
	if not state or not state.Enabled or not camera then
		return nil
	end
	local forcedTarget = state.ForcedTarget
	if forcedTarget and forcedTarget.Parent then
		local forcedCharacter = forcedTarget:FindFirstAncestorOfClass("Model")
		local forcedHumanoid = forcedCharacter and forcedCharacter:FindFirstChildOfClass("Humanoid")
		if forcedHumanoid and forcedHumanoid.Health > 0
			and (not state.VisibleCheck or silentIsVisible(forcedTarget)) then
			return forcedTarget
		end
	end
	state.ForcedTarget = nil
	local mousePosition = UserInputService:GetMouseLocation()
	local closestPart = nil
	local closestDistance = state.FOVRadius
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player and (not state.TeamCheck or targetPlayer.Team ~= player.Team) then
			local character = targetPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				local targetName = state.TargetPart
				if targetName == "Random" then
					targetName = math.random(1, 2) == 1 and "Head" or "HumanoidRootPart"
				end
				local targetPart = character:FindFirstChild(targetName) or character:FindFirstChild("HumanoidRootPart")
				if targetPart and (not state.VisibleCheck or silentIsVisible(targetPart)) then
					local viewport, onScreen = camera:WorldToViewportPoint(silentTargetPosition(targetPart, state))
					if onScreen then
						local distance = (mousePosition - Vector2.new(viewport.X, viewport.Y)).Magnitude
						if distance <= closestDistance then
							closestDistance = distance
							closestPart = targetPart
						end
					end
				end
			end
		end
	end
	return closestPart
end
local function ensureSilentDrawings()
	if silentDrawings.FOV and silentDrawings.Target then
		return true
	end
	local drawingApi = globalEnvironment.Drawing or Drawing
	if type(drawingApi) ~= "table" or type(drawingApi.new) ~= "function" then
		return false
	end
	local success = pcall(function()
		local fov = drawingApi.new("Circle")
		fov.Visible = false
		fov.Thickness = 1.5
		fov.NumSides = 80
		fov.Radius = silentState.FOVRadius
		fov.Filled = false
		fov.ZIndex = 999
		fov.Transparency = 1
		fov.Color = Color3.fromRGB(115, 105, 255)
		local target = drawingApi.new("Square")
		target.Visible = false
		target.ZIndex = 1000
		target.Color = Color3.fromRGB(255, 90, 110)
		target.Thickness = 2
		target.Size = Vector2.new(20, 20)
		target.Filled = false
		silentDrawings.FOV = fov
		silentDrawings.Target = target
	end)
	return success
end
local function hideSilentDrawings()
	for _, drawing in pairs(silentDrawings) do
		pcall(function()
			drawing.Visible = false
		end)
	end
end
local function updateSilentVisuals()
	if not silentState.Enabled then
		hideSilentDrawings()
		return
	end
	if not ensureSilentDrawings() then
		return
	end
	local mousePosition = UserInputService:GetMouseLocation()
	local fov = silentDrawings.FOV
	fov.Position = mousePosition
	fov.Radius = silentState.FOVRadius
	fov.Visible = silentState.FOVVisible
	local marker = silentDrawings.Target
	if not silentState.ShowTarget then
		marker.Visible = false
		return
	end
	local targetPart = silentClosestTarget()
	local camera = Workspace.CurrentCamera
	if targetPart and camera then
		local viewport, onScreen = camera:WorldToViewportPoint(silentTargetPosition(targetPart, silentState))
		marker.Visible = onScreen
		marker.Position = Vector2.new(viewport.X - 10, viewport.Y - 10)
	else
		marker.Visible = false
	end
end
	silentState.GetTarget = silentClosestTarget
	silentState.GetTargetPosition = silentTargetPosition
-- Older Beano runs may have camera-wide hooks installed. Keep their shared state
-- disabled and use a separate state object for the gun-remote-only implementation.
globalEnvironment.__BEANO_SILENT_STATE = legacySilentState
globalEnvironment.__BEANO_SAFE_SILENT_STATE = silentState
local silentHookMetamethod = globalEnvironment.hookmetamethod
local silentNewClosure = globalEnvironment.newcclosure or function(callback)
	return callback
end
local silentCheckCaller = globalEnvironment.checkcaller
local silentGetNamecallMethod = globalEnvironment.getnamecallmethod
if type(silentHookMetamethod) == "function"
	and type(silentCheckCaller) == "function"
	and type(silentGetNamecallMethod) == "function"
	and not globalEnvironment.__BEANO_SAFE_SILENT_REMOTE_HOOKED then
	local hookSuccess = pcall(function()
		local oldNamecall
		oldNamecall = silentHookMetamethod(game, "__namecall", silentNewClosure(function(self, ...)
			local state = globalEnvironment.__BEANO_SAFE_SILENT_STATE
			local method = silentGetNamecallMethod()
			local gunRemote = silentEquippedGunRemote()
			if state and state.Enabled and gunRemote and self == gunRemote and not silentCheckCaller()
				and (method == "InvokeServer" or method == "FireServer")
				and math.random(1, 100) <= math.clamp(state.HitChance, 0, 100) then
				local targetPart = state.GetTarget and state.GetTarget()
				if targetPart then
					local args = {...}
					local targetPosition = state.GetTargetPosition(targetPart, state)
					for index, argument in ipairs(args) do
						if typeof(argument) == "Vector3" then
							args[index] = targetPosition
							return oldNamecall(self, table.unpack(args))
						end
					end
				end
			end
			return oldNamecall(self, ...)
		end))
	end)
	if hookSuccess then
		globalEnvironment.__BEANO_SAFE_SILENT_REMOTE_HOOKED = true
	end
end
silentState.HookSupported = globalEnvironment.__BEANO_SAFE_SILENT_REMOTE_HOOKED == true
table.insert(connections, RunService.RenderStepped:Connect(updateSilentVisuals))
local function isDroppedGunName(name)
	local normalizedName = string.lower(name):gsub("[%s_%-]", "")
	return normalizedName == "gun" or normalizedName == "gundrop" or normalizedName == "droppedgun"
end
local function isHeldByPlayer(instance)
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local character = targetPlayer.Character
		local backpack = targetPlayer:FindFirstChild("Backpack")
		if (character and instance:IsDescendantOf(character))
			or (backpack and instance:IsDescendantOf(backpack)) then
			return true
		end
	end
	return false
end
local function getGunPart(droppedGun)
	if droppedGun:IsA("BasePart") then
		return droppedGun
	end
	return droppedGun:FindFirstChild("Handle") or droppedGun:FindFirstChildWhichIsA("BasePart", true)
end
local function findDroppedGun()
	if cachedDroppedGun and cachedDroppedGun.Parent and not isHeldByPlayer(cachedDroppedGun) then
		return cachedDroppedGun
	end
	if cachedDroppedGun then
		gunScanRequested = true
	end
	cachedDroppedGun = nil
	if not gunScanRequested then
		return nil
	end
	gunScanRequested = false
	for _, dropName in ipairs(GUN_DROP_NAMES) do
		local instance = Workspace:FindFirstChild(dropName, true)
		local canBeGunDrop = instance and (instance:IsA("Tool") or instance:IsA("Model") or instance:IsA("BasePart"))
		if canBeGunDrop and isDroppedGunName(instance.Name) and not isHeldByPlayer(instance) then
			cachedDroppedGun = instance
			return instance
		end
	end
	return nil
end
local function updateDroppedGunCham(droppedGun)
	if not gunChamEnabled then
		if droppedGunHighlight and droppedGunHighlight.Parent then
			droppedGunHighlight:Destroy()
		end
		droppedGunHighlight = nil
		return
	end
	if not droppedGun then
		if droppedGunHighlight and droppedGunHighlight.Parent then
			droppedGunHighlight:Destroy()
		end
		droppedGunHighlight = nil
		return
	end
	local gunAdornee = getGunPart(droppedGun)
	if not gunAdornee then
		if droppedGunHighlight and droppedGunHighlight.Parent then
			droppedGunHighlight:Destroy()
		end
		droppedGunHighlight = nil
		return
	end
	if not droppedGunHighlight or droppedGunHighlight.Parent ~= droppedGun then
		if droppedGunHighlight and droppedGunHighlight.Parent then
			droppedGunHighlight:Destroy()
	end
		droppedGunHighlight = Instance.new("Highlight")
		droppedGunHighlight.Name = "DroppedGunHighlight"
		droppedGunHighlight.Adornee = gunAdornee
		droppedGunHighlight.FillColor = Color3.fromRGB(255, 220, 75)
		droppedGunHighlight.OutlineColor = Color3.fromRGB(255, 245, 180)
		droppedGunHighlight.FillTransparency = gunFillTransparency
		droppedGunHighlight.OutlineTransparency = 0
		droppedGunHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		droppedGunHighlight.Parent = droppedGun
	end
	droppedGunHighlight.Enabled = true
	droppedGunHighlight.Adornee = gunAdornee
	droppedGunHighlight.FillTransparency = gunFillTransparency
end
local function moveDroppedGunToPlayer(droppedGun)
	if not autoPickupGunEnabled or gunPickupInProgress or flingInProgress then
		return
	end
	local now = os.clock()
	if now - lastGunPickupAttempt < gunPickupCooldown then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not droppedGun then
		return
	end
	local gunPart = getGunPart(droppedGun)
	if not gunPart then
		return
	end
	lastGunPickupAttempt = now
	gunPickupInProgress = true
	task.spawn(function()
		local originalCFrame = root.CFrame
		local originalLinearVelocity = root.AssemblyLinearVelocity
		local originalAngularVelocity = root.AssemblyAngularVelocity
		local prompt = droppedGun:FindFirstChildWhichIsA("ProximityPrompt", true)
		local environment = (getgenv and getgenv()) or _G
		local promptFunction = environment.fireproximityprompt
		local touchFunction = environment.firetouchinterest
		pcall(function()
			for _ = 1, 10 do
				if stopped or not autoPickupGunEnabled or not root.Parent or playerHasTool(player, "Gun") then
					break
				end
				gunPart = getGunPart(droppedGun)
				if not gunPart or not gunPart.Parent then
					break
				end
				root.CFrame = gunPart.CFrame * CFrame.new(0, 0.15, 0)
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				if prompt and type(promptFunction) == "function" then
					pcall(promptFunction, prompt)
				end
				if type(touchFunction) == "function" then
					pcall(touchFunction, root, gunPart, 0)
					pcall(touchFunction, root, gunPart, 1)
				end
				task.wait(0.1)
			end
		end)
		if root.Parent then
			root.CFrame = originalCFrame
			root.AssemblyLinearVelocity = originalLinearVelocity
			root.AssemblyAngularVelocity = originalAngularVelocity
			task.wait()
			if root.Parent then
				root.CFrame = originalCFrame
			end
		end
		gunPickupInProgress = false
		gunScanRequested = true
	end)
end
local function roleColor(role)
	local normalizedRole = string.lower(role or "")
	if normalizedRole:find("murder", 1, true) or normalizedRole:find("killer", 1, true) then
		return Color3.fromRGB(255, 75, 75)
	elseif normalizedRole:find("sheriff", 1, true) or normalizedRole:find("detective", 1, true) then
		return Color3.fromRGB(75, 145, 255)
	elseif normalizedRole:find("hero", 1, true) then
		return Color3.fromRGB(255, 220, 75)
	elseif normalizedRole:find("dead", 1, true) or normalizedRole:find("spectat", 1, true) then
		return Color3.fromRGB(150, 155, 170)
	end
	return Color3.fromRGB(100, 235, 135)
end
local function removeRoleLine(entry)
	if entry.beam and entry.beam.Parent then
		entry.beam:Destroy()
	end
	if entry.originAttachment and entry.originAttachment.Parent then
		entry.originAttachment:Destroy()
	end
	if entry.targetAttachment and entry.targetAttachment.Parent then
		entry.targetAttachment:Destroy()
	end
	entry.beam = nil
	entry.originAttachment = nil
	entry.targetAttachment = nil
end
local function removeRoleHighlight(targetPlayer)
	local entry = roleHighlights[targetPlayer]
	if entry then
		removeRoleLine(entry)
		if entry.highlight and entry.highlight.Parent then
			entry.highlight:Destroy()
		end
		if entry.label and entry.label.Parent then
			entry.label:Destroy()
		end
		roleHighlights[targetPlayer] = nil
	end
end
local function clearRoleHighlights()
	for targetPlayer in pairs(roleHighlights) do
		removeRoleHighlight(targetPlayer)
	end
end
local function updateRoleLine(entry, character, color)
	if not roleLinesEnabled then
		removeRoleLine(entry)
		return
	end
	local originCharacter = player.Character
	local originRoot = originCharacter and (originCharacter:FindFirstChild("HumanoidRootPart") or originCharacter:FindFirstChild("Head"))
	local targetRoot = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Head")
	if not originRoot or not targetRoot then
		removeRoleLine(entry)
		return
	end
	if entry.originAttachment and entry.originAttachment.Parent ~= originRoot then
		removeRoleLine(entry)
	elseif entry.targetAttachment and entry.targetAttachment.Parent ~= targetRoot then
		removeRoleLine(entry)
	end
	if not entry.beam then
		local originAttachment = Instance.new("Attachment")
		originAttachment.Name = "RoleLineOrigin"
		originAttachment.Parent = originRoot
		local targetAttachment = Instance.new("Attachment")
		targetAttachment.Name = "RoleLineTarget"
		targetAttachment.Parent = targetRoot
		local beam = Instance.new("Beam")
		beam.Name = "RoleLine"
		beam.Attachment0 = originAttachment
		beam.Attachment1 = targetAttachment
		beam.FaceCamera = true
		beam.Width0 = roleLineWidth
		beam.Width1 = roleLineWidth
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Transparency = NumberSequence.new(0)
		beam.Parent = originRoot
		entry.originAttachment = originAttachment
		entry.targetAttachment = targetAttachment
		entry.beam = beam
	end
	entry.beam.Color = ColorSequence.new(color)
	entry.beam.Width0 = roleLineWidth
	entry.beam.Width1 = roleLineWidth
end
local function refreshRoleHighlights()
	if not roleHighlightsEnabled then
		clearRoleHighlights()
		roleShownCount = 0
		if roleHighlightStatus then
			roleHighlightStatus.Text = "Role scanner is off"
		end
		return
	end
	local shown = 0
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then
			local character = targetPlayer.Character
			local role = readRole(targetPlayer)
			if character and role then
				local entry = roleHighlights[targetPlayer]
				if entry and entry.character ~= character then
					removeRoleHighlight(targetPlayer)
					entry = nil
				end
				if not entry then
					local color = roleColor(role)
					local highlight = Instance.new("Highlight")
					highlight.Name = "RoleHighlight"
					highlight.Adornee = character
					highlight.FillColor = color
					highlight.OutlineColor = color
					highlight.FillTransparency = roleFillTransparency
					highlight.OutlineTransparency = roleOutlineTransparency
					highlight.Enabled = roleChamsEnabled
					highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					highlight.Parent = character
					local head = character:FindFirstChild("Head")
					local label = Instance.new("BillboardGui")
					label.Name = "RoleLabel"
					label.Adornee = head
					label.Size = UDim2.fromOffset(150, 28)
					label.StudsOffset = Vector3.new(0, 3, 0)
					label.AlwaysOnTop = true
					label.Enabled = roleNamesEnabled
					label.Parent = character
					local labelText = Instance.new("TextLabel")
					labelText.BackgroundTransparency = 1
					labelText.Size = UDim2.fromScale(1, 1)
					labelText.Text = targetPlayer.DisplayName .. " â€¢ " .. role
					labelText.TextColor3 = color
					labelText.Text = targetPlayer.DisplayName .. " - " .. role
					labelText.TextStrokeTransparency = 0.35
					labelText.TextSize = 14
					labelText.Font = Enum.Font.GothamBold
					labelText.Parent = label
					entry = { character = character, highlight = highlight, label = label, labelText = labelText }
					roleHighlights[targetPlayer] = entry
					updateRoleLine(entry, character, color)
				else
					local color = roleColor(role)
					entry.highlight.Enabled = roleChamsEnabled
					entry.label.Enabled = roleNamesEnabled
					entry.highlight.FillColor = color
					entry.highlight.OutlineColor = color
					entry.highlight.FillTransparency = roleFillTransparency
					entry.highlight.OutlineTransparency = roleOutlineTransparency
					entry.label.Adornee = character:FindFirstChild("Head")
					entry.labelText.Text = targetPlayer.DisplayName .. " â€¢ " .. role
					entry.labelText.TextColor3 = color
					entry.labelText.Text = targetPlayer.DisplayName .. " - " .. role
					updateRoleLine(entry, character, color)
				end
				shown += 1
			else
				removeRoleHighlight(targetPlayer)
			end
		end
	end
	roleShownCount = shown
	if roleHighlightStatus then
		roleHighlightStatus.Text = ("Role highlights on â€¢ %d players with exposed roles"):format(shown)
	end
end
local navButtons = {}
local pagePanels = {
	Main = frame,
	Trade = tradeFrame,
	Settings = settingsPanel,
	Player = playerPanel,
}
local function createNavButton(name, y)
	local button = Instance.new("TextButton")
	button.Name = name .. "Nav"
	button.Position = UDim2.fromOffset(8, y)
	button.Size = UDim2.fromOffset(136, 34)
	button.BackgroundColor3 = Color3.fromRGB(17, 18, 22)
	button.BorderSizePixel = 0
	button.Text = "  " .. name
	button.TextColor3 = Color3.fromRGB(180, 184, 196)
	button.TextSize = 14
	button.Font = Enum.Font.GothamMedium
	button.TextXAlignment = Enum.TextXAlignment.Left
	button.Parent = sidebar
	roundButton(button)
	navButtons[name] = button
	return button
end
createNavButton("Main", 82)
createNavButton("Trade", 124)
createNavButton("Player", 166)
createNavButton("Settings", 208)
local function selectPage(pageName)
	for name, panel in pairs(pagePanels) do
		panel.Visible = name == pageName
		local button = navButtons[name]
		if button then
			button.BackgroundColor3 = name == pageName and Color3.fromRGB(35, 37, 45) or Color3.fromRGB(17, 18, 22)
			button.TextColor3 = name == pageName and Color3.fromRGB(235, 238, 248) or Color3.fromRGB(180, 184, 196)
		end
	end
	pageTitle.Text = pageName
	if pageName == "Player" then
		refreshPlayerInfo()
	end
end
local function updateRoleToggleButtons()
	roleHighlightButton.Text = roleHighlightsEnabled and "Role Scanner: On" or "Role Scanner: Off"
	roleHighlightButton.BackgroundColor3 = roleHighlightsEnabled
		and Color3.fromRGB(75, 165, 110)
		or Color3.fromRGB(70, 135, 255)
	roleChamsButton.Text = roleChamsEnabled and "Chams: On" or "Chams: Off"
	roleChamsButton.BackgroundColor3 = roleChamsEnabled
		and Color3.fromRGB(75, 165, 110)
		or Color3.fromRGB(70, 135, 255)
	roleNamesButton.Text = roleNamesEnabled and "Names: On" or "Names: Off"
	roleNamesButton.BackgroundColor3 = roleNamesEnabled
		and Color3.fromRGB(75, 165, 110)
		or Color3.fromRGB(70, 135, 255)
	roleLinesButton.Text = roleLinesEnabled and "Lines: On" or "Lines: Off"
	roleLinesButton.BackgroundColor3 = roleLinesEnabled
		and Color3.fromRGB(75, 165, 110)
		or Color3.fromRGB(70, 135, 255)
end
table.insert(connections, roleHighlightButton.Activated:Connect(function()
	roleHighlightsEnabled = not roleHighlightsEnabled
	updateRoleToggleButtons()
	refreshRoleHighlights()
end))
table.insert(connections, roleChamsButton.Activated:Connect(function()
	roleChamsEnabled = not roleChamsEnabled
	updateRoleToggleButtons()
	refreshRoleHighlights()
end))
table.insert(connections, roleNamesButton.Activated:Connect(function()
	roleNamesEnabled = not roleNamesEnabled
	updateRoleToggleButtons()
	refreshRoleHighlights()
end))
table.insert(connections, roleLinesButton.Activated:Connect(function()
	roleLinesEnabled = not roleLinesEnabled
	updateRoleToggleButtons()
	refreshRoleHighlights()
end))
local function playerMatchesRole(targetPlayer, roleName)
	local detectedRole = string.lower(readRole(targetPlayer) or "")
	return roleName == "Sheriff / Hero"
		and (detectedRole:find("sheriff", 1, true) ~= nil
			or detectedRole:find("detective", 1, true) ~= nil
			or detectedRole:find("hero", 1, true) ~= nil)
		or roleName == "Murderer"
		and (detectedRole:find("murder", 1, true) ~= nil or detectedRole:find("killer", 1, true) ~= nil)
end
local function findPlayerByRole(roleName)
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player and playerMatchesRole(targetPlayer, roleName) then
			return targetPlayer
		end
	end
	return nil
end
silentState.FindGun = function()
	local character = player.Character
	local backpack = player:FindFirstChild("Backpack")
	local equippedGun = character and character:FindFirstChild("Gun")
	if equippedGun and equippedGun:IsA("Tool") then
		return equippedGun, true
	end
	local storedGun = backpack and backpack:FindFirstChild("Gun")
	if storedGun and storedGun:IsA("Tool") then
		return storedGun, false
	end
	return nil, false
end
silentState.FindGunRemote = function(gun)
	local knifeLocal = gun and gun:FindFirstChild("KnifeLocal", true)
	local createBeam = knifeLocal and knifeLocal:FindFirstChild("CreateBeam", true)
	local knownRemote = createBeam and createBeam:FindFirstChild("RemoteFunction", true)
	if knownRemote and knownRemote:IsA("RemoteFunction") then
		return knownRemote
	end
	if not gun then
		return nil
	end
	for _, descendant in ipairs(gun:GetDescendants()) do
		if descendant:IsA("RemoteFunction") then
			local beamAncestor = descendant:FindFirstAncestor("CreateBeam")
			if beamAncestor or descendant.Name == "RemoteFunction" then
				return descendant
			end
		end
	end
	return nil
end
silentState.GetMurdererTarget = function()
	updateRoundRoleTracking()
	local murderer = findPlayerByRole("Murderer")
	local character = murderer and murderer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	local targetName = silentState.TargetPart
	if targetName == "Random" then
		targetName = math.random(1, 2) == 1 and "Head" or "HumanoidRootPart"
	end
	local targetPart = character:FindFirstChild(targetName) or character:FindFirstChild("HumanoidRootPart")
	return murderer, targetPart
end
silentState.ShootMurderer = function()
	if stopped or not silentState.ShootMurdererEnabled then
		return false, "The Silent shoot hotkey is disabled."
	end
	local now = os.clock()
	if silentState.ShootBusy or now - silentState.LastShotAt < silentState.ShootCooldown then
		return false, nil
	end
	local gun, alreadyEquipped = silentState.FindGun()
	if not gun then
		return false, "You do not currently have the gun."
	end
	local murderer, targetPart = silentState.GetMurdererTarget()
	if not murderer or not targetPart then
		return false, "No living murderer was detected."
	end
	if silentState.VisibleCheck and not silentIsVisible(targetPart) then
		return false, "The murderer is blocked by a wall."
	end
	silentState.ShootBusy = true
	silentState.LastShotAt = now
	task.delay(silentState.ShootCooldown, function()
		silentState.ShootBusy = false
	end)
	task.spawn(function()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not alreadyEquipped and humanoid and gun.Parent then
			pcall(function()
				humanoid:EquipTool(gun)
			end)
			task.wait(0.08)
		end
		if stopped or not gun.Parent then
			return
		end
		local _, currentTargetPart = silentState.GetMurdererTarget()
		if not currentTargetPart then
			return
		end
		local targetPosition = silentTargetPosition(currentTargetPart, silentState)
		local gunRemote = silentState.FindGunRemote(gun)
		if gunRemote then
			local success, invokeError = pcall(function()
				gunRemote:InvokeServer(1, targetPosition, "AH2")
			end)
			if not success then
				warn("Beano GUI Silent gun shot failed: " .. tostring(invokeError))
			end
			return
		end

		-- Fallback for gun versions that fire through Tool.Activated instead of the known MM2 remote.
		local previousEnabled = silentState.Enabled
		silentState.Enabled = true
		silentState.ForcedTarget = currentTargetPart
		silentState.ShotWindowUntil = os.clock() + 0.5
		pcall(function()
			gun:Activate()
		end)
		task.delay(0.25, function()
			if silentState.ForcedTarget == currentTargetPart then
				silentState.ForcedTarget = nil
			end
			silentState.Enabled = previousEnabled
		end)
	end)
	return true, ("Shot sent toward %s."):format(murderer.DisplayName)
end
local function teleportToRole(roleName)
	local localCharacter = player.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
	if not localRoot then
		roleHighlightStatus.Text = "Your character is not ready to teleport."
		return
	end
	local targetPlayer = findPlayerByRole(roleName)
	local targetCharacter = targetPlayer and targetPlayer.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if targetRoot then
		localRoot.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
		roleHighlightStatus.Text = "Teleported to " .. targetPlayer.DisplayName .. " (" .. roleName .. ")"
		return
	end
	roleHighlightStatus.Text = "No active " .. roleName .. " was found."
end
table.insert(connections, teleportSheriffButton.Activated:Connect(function()
	teleportToRole("Sheriff / Hero")
end))
table.insert(connections, teleportMurdererButton.Activated:Connect(function()
	teleportToRole("Murderer")
end))
local function updateAutoPickupGunButton()
	autoPickupGunButton.Text = autoPickupGunEnabled
		and "Auto Pickup Dropped Gun: On"
		or "Auto Pickup Dropped Gun: Off"
	autoPickupGunButton.BackgroundColor3 = autoPickupGunEnabled
		and Color3.fromRGB(75, 165, 110)
		or Color3.fromRGB(70, 135, 255)
end
table.insert(connections, autoPickupGunButton.Activated:Connect(function()
	autoPickupGunEnabled = not autoPickupGunEnabled
	updateAutoPickupGunButton()
	roleHighlightStatus.Text = autoPickupGunEnabled
		and "Auto pickup is on. Waiting for the dropped gun."
		or "Auto pickup is off."
end))
updateRoleToggleButtons()
updateAutoPickupGunButton()
table.insert(connections, Players.PlayerRemoving:Connect(function(targetPlayer)
	removeRoleHighlight(targetPlayer)
	trackedInnocents[targetPlayer] = nil
	trackedMurderers[targetPlayer] = nil
	trackedHeroes[targetPlayer] = nil
	if selectedPlayer == targetPlayer then
		selectedPlayer = nil
	end
	if spectatingPlayer == targetPlayer then
		spectatingPlayer = nil
		local camera = Workspace.CurrentCamera
		local humanoid = getHumanoid()
		if camera and humanoid then
			camera.CameraSubject = humanoid
		end
	end
	if trackedSheriff == targetPlayer then
		trackedSheriff = nil
	end
end))
local function requestGunScan(instance)
	local canBeGunDrop = instance:IsA("Tool") or instance:IsA("Model") or instance:IsA("BasePart")
	if canBeGunDrop and isDroppedGunName(instance.Name) then
		if cachedDroppedGun == instance then
			cachedDroppedGun = nil
		end
		gunScanRequested = true
	end
end
table.insert(connections, Workspace.DescendantAdded:Connect(requestGunScan))
table.insert(connections, Workspace.DescendantRemoving:Connect(requestGunScan))
local gunChamElapsed = 0
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
	if not interfaceReady or (not gunChamEnabled and not autoPickupGunEnabled) then
		return
	end
	gunChamElapsed += deltaTime
	if gunChamElapsed >= gunCheckInterval then
		gunChamElapsed = 0
		local droppedGun = findDroppedGun()
		updateDroppedGunCham(droppedGun)
		moveDroppedGunToPlayer(droppedGun)
	end
end))
local roleRefreshElapsed = 0
table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
	if not interfaceReady or not roleHighlightsEnabled then
		return
	end
	roleRefreshElapsed += deltaTime
	if roleRefreshElapsed >= roleRefreshInterval then
		roleRefreshElapsed = 0
		updateRoundRoleTracking()
		refreshRoleHighlights()
		if roleHighlightsEnabled and roleHighlightStatus then
			roleHighlightStatus.Text = ("Detected: %d | Chams: %s | Names: %s | Lines: %s"):format(
				roleShownCount,
				roleChamsEnabled and "On" or "Off",
				roleNamesEnabled and "On" or "Off",
				roleLinesEnabled and "On" or "Off"
			)
		end
	end
end))
local function findBuiltInTradeRoot()
	local function containsOfferHeading(container, targetText)
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("TextLabel") and normalizeItemName(descendant.Text) == targetText then
				return true
			end
		end
		return false
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("TextLabel") and normalizeItemName(descendant.Text) == "your offer" then
			local current = descendant.Parent
			for _ = 1, 8 do
				if not current then
					break
				end
				if current:IsA("GuiObject") and containsOfferHeading(current, "their offer") then
					return current
				end
				current = current.Parent
			end
		end
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			local isTradeUi, _, tradeRoot = findTradeSide(descendant)
			if isTradeUi and tradeRoot and tradeRoot:IsA("GuiObject") then
				return tradeRoot
			end
		end
	end
	local bestRoot = nil
	local bestArea = 0
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("GuiObject") and descendant.Visible then
			local normalizedName = normalizeItemName(descendant.Name)
			if normalizedName:find("trade", 1, true) then
				local size = descendant.AbsoluteSize
				local area = size.X * size.Y
				if area > bestArea then
					bestArea = area
					bestRoot = descendant
				end
			end
		end
	end
	return bestRoot
end
local function updateBuiltInTradeSummary()
	if not tradeOverlayEnabled then
		if gameTradeSummary and gameTradeSummary.Parent then
			gameTradeSummary:Destroy()
		end
		gameTradeSummary = nil
		return
	end
	local tradeRoot = findBuiltInTradeRoot()
	if not tradeRoot then
		if gameTradeSummary and gameTradeSummary.Parent then
			gameTradeSummary.Visible = false
		end
		return
	end
	if not gameTradeSummary or gameTradeSummary.Parent ~= tradeRoot then
		if gameTradeSummary and gameTradeSummary.Parent then
			gameTradeSummary:Destroy()
		end
		gameTradeSummary = Instance.new("TextLabel")
		gameTradeSummary.Name = "BeanoTradeValueSummary"
		gameTradeSummary.Size = UDim2.new(0, 330, 0, 38)
		gameTradeSummary.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
		gameTradeSummary.BackgroundTransparency = 0.18
		gameTradeSummary.BorderSizePixel = 0
		gameTradeSummary.TextColor3 = Color3.fromRGB(255, 255, 255)
		gameTradeSummary.TextSize = 13
		gameTradeSummary.Font = Enum.Font.GothamBold
		gameTradeSummary.TextWrapped = true
		gameTradeSummary.ZIndex = 100
		gameTradeSummary.Parent = tradeRoot
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = gameTradeSummary
	end
	if tradeOverlayPosition == "Bottom" then
		gameTradeSummary.AnchorPoint = Vector2.new(0.5, 1)
		gameTradeSummary.Position = UDim2.new(0.5, 0, 1, -4)
	else
		gameTradeSummary.AnchorPoint = Vector2.new(0.5, 0)
		gameTradeSummary.Position = UDim2.new(0.5, 0, 0, 4)
	end
	local difference = lastTradeTheirValue - lastTradeYourValue
	local differenceText = difference == 0 and "Even"
		or difference > 0 and ("+%s for you"):format(formatValue(difference))
		or ("-%s for you"):format(formatValue(math.abs(difference)))
	gameTradeSummary.Text = ("Your value: %s   |   Their value: %s\n%s   |   Demand: %d/10")
		:format(
			formatValue(lastTradeYourValue),
			formatValue(lastTradeTheirValue),
			differenceText,
			lastTradeAverageDemand
		)
	gameTradeSummary.Visible = true
end
local function updateTradeValueSummary(yourTotal, theirTotal, demandSum, demandCount)
	local averageDemand = 0
	if demandCount and demandCount > 0 then
		averageDemand = math.floor((demandSum / demandCount) + 0.5)
	end
	lastTradeYourValue = yourTotal or 0
	lastTradeTheirValue = theirTotal or 0
	lastTradeAverageDemand = averageDemand
	tradeValueSummary.Text = ("Your value: %s | Their value: %s | Demand: %d/10")
		:format(formatValue(lastTradeYourValue), formatValue(lastTradeTheirValue), averageDemand)
	updateBuiltInTradeSummary()
end
local function showTradeTotals(yourTotal, theirTotal, unknown, demandSum, demandCount)
	yourTotal = yourTotal or 0
	theirTotal = theirTotal or 0
	updateTradeValueSummary(yourTotal, theirTotal, demandSum or 0, demandCount or 0)
	local difference = theirTotal - yourTotal
	local verdict = "Equal"
	if difference > 0 then
		verdict = "You gain value"
	elseif difference < 0 then
		verdict = "You give value"
	end
	local lines = {
		("You: %s"):format(formatValue(yourTotal)),
		("Them: %s"):format(formatValue(theirTotal)),
		("Difference: %s (%s)"):format(formatValue(math.abs(difference)), verdict),
	}
	if #unknown > 0 then
		table.insert(lines, "Unknown: " .. table.concat(unknown, ", "))
	end
	tradeResult.Text = table.concat(lines, "\n")
	task.delay(0.5, function()
		if not stopped then
			updateBuiltInTradeSummary()
		end
	end)
end
local tradeUiScanScheduled = false
local function scheduleVisibleTradeRefresh()
	if tradeUiScanScheduled or stopped or not tradeOverlayEnabled then
		return
	end
	tradeUiScanScheduled = true
	task.delay(0.35, function()
		tradeUiScanScheduled = false
		if stopped or not tradeOverlayEnabled then
			return
		end
		local totals, names = scanVisibleTrade()
		if #names.You > 0 or #names.Them > 0 then
			showTradeTotals(totals.You, totals.Them, {})
		elseif findBuiltInTradeRoot() then
			showTradeTotals(0, 0, {})
		end
	end)
end
local function isTradeUiChange(instance)
	if not interfaceReady then
		return false
	end
	if not (instance:IsA("TextLabel") or instance:IsA("ImageLabel") or instance:IsA("ViewportFrame")) then
		return false
	end
	if instance:IsA("TextLabel") then
		local text = normalizeItemName(instance.Text)
		if text == "your offer" or text == "their offer" then
			return true
		end
	end
	local current = instance
	for _ = 1, 10 do
		if not current then
			break
		end
		local name = normalizeItemName(current.Name)
		if name:find("trade", 1, true) or name:find("offer", 1, true) then
			return true
		end
		current = current.Parent
	end
	return false
end
table.insert(connections, playerGui.DescendantAdded:Connect(function(instance)
	if isTradeUiChange(instance) then
		scheduleVisibleTradeRefresh()
	end
end))
table.insert(connections, playerGui.DescendantRemoving:Connect(function(instance)
	if isTradeUiChange(instance) then
		scheduleVisibleTradeRefresh()
	end
end))
globalEnvironment.__BEANO_GUI_CLEANUP = stopScript
local function calculateCurrentTrade()
	local yourTotal, _, yourUnknown, yourDemandSum, yourDemandCount = parseItemList(yourItemsInput.Text)
	local theirTotal, _, theirUnknown, theirDemandSum, theirDemandCount = parseItemList(theirItemsInput.Text)
	local unknown = {}
	for _, itemName in ipairs(yourUnknown) do table.insert(unknown, "You: " .. itemName) end
	for _, itemName in ipairs(theirUnknown) do table.insert(unknown, "Them: " .. itemName) end
	showTradeTotals(yourTotal, theirTotal, unknown, yourDemandSum + theirDemandSum, yourDemandCount + theirDemandCount)
end
table.insert(connections, calculateTradeButton.Activated:Connect(calculateCurrentTrade))
table.insert(connections, scanTradeButton.Activated:Connect(function()
	local totals, names = scanVisibleTrade()
	if #names.You == 0 and #names.Them == 0 and #names.Other == 0 then
		tradeResult.Text = "No visible trade offer items found. Open the trade window and try again."
		return
	end
	yourItemsInput.Text = table.concat(names.You, ", ")
	theirItemsInput.Text = table.concat(names.Them, ", ")
	local unknown = {}
	if #names.Other > 0 then
		table.insert(unknown, "Unassigned: " .. table.concat(names.Other, ", "))
	end
	showTradeTotals(totals.You, totals.Them, unknown)
end))
local function summarizeOffer(offer, physicalNames)
	local total = 0
	local names = {}
	local details = {}
	local unknown = {}
	local demandSum = 0
	local demandCount = 0
	for index, item in ipairs(offer or {}) do
		if type(item) == "table" then
			local itemName = tostring(item.ItemName or item.itemName or item.Name or item[1] or "")
			local quantity = tonumber(item.Quantity or item.quantity or item[2]) or 1
			local category = item.Category or item.category or item[3]
			local rawEntry = lookupValue(itemName, category)
			local physicalName = physicalNames and physicalNames[index]
			local rawNormalizedName = normalizeItemName(itemName)
			local physicalNormalizedName = physicalName and normalizeItemName(physicalName) or ""
			local physicalIsChroma = physicalNormalizedName:find("^chroma ") ~= nil
			local rawIsChroma = rawNormalizedName:find("^chroma ") ~= nil
			if physicalName and physicalName ~= "" and (not rawEntry or type(rawEntry.value) ~= "number" or (physicalIsChroma and not rawIsChroma)) then
				itemName = physicalName
			end
			local entry = lookupValue(itemName, category)
			if entry and type(entry.value) == "number" then
				total += entry.value * quantity
				local demand = lookupDemand(itemName, category)
				if demand then
					demandSum += demand * quantity
					demandCount += quantity
				end
				local prefix = quantity == 1 and "" or (tostring(quantity) .. "x ")
				table.insert(names, prefix .. entry.name)
				table.insert(details, ("%s%s = %s"):format(prefix, entry.name, formatValue(entry.value * quantity)))
			elseif entry and entry.value == "Priceless" then
				table.insert(unknown, itemName .. " (Priceless)")
				local demand = lookupDemand(itemName, category)
				if demand then
					demandSum += demand * quantity
					demandCount += quantity
				end
			elseif entry and entry.ambiguous then
				table.insert(unknown, itemName .. " (choose a category)")
			else
				table.insert(unknown, itemName)
			end
		end
	end
	return total, names, details, unknown, demandSum, demandCount
end
local function handleTradePayload(payload)
	if type(payload) ~= "table" then
		return
	end
	local player1 = payload.Player1
	local player2 = payload.Player2
	if type(player1) ~= "table" or type(player2) ~= "table" then
		return
	end
	local mine
	local theirs
	if player1.Player == player then
		mine = player1
		theirs = player2
	elseif player2.Player == player then
		mine = player2
		theirs = player1
	else
		return
	end
	local _, visibleNames = scanVisibleTrade()
	local yourPhysicalNames = visibleNames.You
	local theirPhysicalNames = visibleNames.Them
	if type(mine.Offer) ~= "table" or #yourPhysicalNames ~= #mine.Offer then
		yourPhysicalNames = nil
	end
	if type(theirs.Offer) ~= "table" or #theirPhysicalNames ~= #theirs.Offer then
		theirPhysicalNames = nil
	end
	local yourTotal, yourNames, yourDetails, yourUnknown, yourDemandSum, yourDemandCount = summarizeOffer(mine.Offer, yourPhysicalNames)
	local theirTotal, theirNames, theirDetails, theirUnknown, theirDemandSum, theirDemandCount = summarizeOffer(theirs.Offer, theirPhysicalNames)
	yourItemsInput.Text = table.concat(yourNames, ", ")
	theirItemsInput.Text = table.concat(theirNames, ", ")
	local unknown = {}
	for _, itemName in ipairs(yourUnknown) do table.insert(unknown, "You: " .. itemName) end
	for _, itemName in ipairs(theirUnknown) do table.insert(unknown, "Them: " .. itemName) end
	showTradeTotals(yourTotal, theirTotal, unknown, yourDemandSum + theirDemandSum, yourDemandCount + theirDemandCount)
	local detailLines = {"You: " .. ( #yourDetails == 0 and "(empty)" or table.concat(yourDetails, ", ") )}
	table.insert(detailLines, "Them: " .. ( #theirDetails == 0 and "(empty)" or table.concat(theirDetails, ", ") ))
	table.insert(detailLines, tradeResult.Text)
	tradeResult.Text = table.concat(detailLines, "\n")
	tradeUpdated.Text = "Trade event received - Locked: " .. tostring(payload.Locked == true)
end
local function resetTradeDisplay(message)
	yourItemsInput.Text = ""
	theirItemsInput.Text = ""
	lastTradeYourValue = 0
	lastTradeTheirValue = 0
	lastTradeAverageDemand = 0
	tradeValueSummary.Text = "Your value: 0 | Their value: 0 | Demand: 0/10"
	tradeResult.Text = "Trade declined. Values reset."
	tradeUpdated.Text = message or "Trade declined - values reset"
	updateBuiltInTradeSummary()
end
local function tradePayloadWasDeclined(value)
	if value == false then
		return true
	end
	if type(value) == "string" then
		local status = string.lower(value)
		return status:find("declin", 1, true) ~= nil
			or status:find("cancel", 1, true) ~= nil
			or status:find("reject", 1, true) ~= nil
			or status == "false"
	end
	if type(value) == "table" then
		local status = value.Status or value.status or value.Result or value.result or value[1]
		if type(status) == "string" and tradePayloadWasDeclined(status) then
			return true
		end
		return value.Accepted == false
			or value.accepted == false
			or value.Declined == true
			or value.declined == true
			or value.Cancelled == true
			or value.cancelled == true
	end
	return false
end
local tradeFolder = ReplicatedStorage:FindFirstChild("Trade", true)
if tradeFolder then
	local startTradeEvent = tradeFolder:FindFirstChild("StartTrade")
	local updateTradeEvent = tradeFolder:FindFirstChild("UpdateTrade")
	local acceptTradeEvent = tradeFolder:FindFirstChild("AcceptTrade")
	if startTradeEvent and startTradeEvent:IsA("RemoteEvent") then
		table.insert(connections, startTradeEvent.OnClientEvent:Connect(handleTradePayload))
	end
	if updateTradeEvent and updateTradeEvent:IsA("RemoteEvent") then
		table.insert(connections, updateTradeEvent.OnClientEvent:Connect(handleTradePayload))
	end
	if acceptTradeEvent and acceptTradeEvent:IsA("RemoteEvent") then
		table.insert(connections, acceptTradeEvent.OnClientEvent:Connect(function(value)
			if tradePayloadWasDeclined(value) then
				resetTradeDisplay("Trade declined - values reset")
			else
				tradeUpdated.Text = "Trade acceptance changed - Payload: " .. tostring(value)
			end
		end))
	end
	for _, eventName in ipairs({"DeclineTrade", "DeclinedTrade", "CancelTrade"}) do
		local declineEvent = tradeFolder:FindFirstChild(eventName)
		if declineEvent and declineEvent:IsA("RemoteEvent") then
			table.insert(connections, declineEvent.OnClientEvent:Connect(function()
				resetTradeDisplay("Trade declined - values reset")
			end))
		end
	end
end
local function loadRayfieldLibrary()
	if type(loadstring) ~= "function" then
		return false, nil, "loadstring is unavailable in this environment"
	end
	local lastError = "unknown download error"
	for _, url in ipairs({
		"https://sirius.menu/rayfield",
		"https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
	}) do
		local success, result = pcall(function()
			local source = game:HttpGet(url)
			local loader, compileError = loadstring(source)
			if not loader then
				error(compileError or "Rayfield source could not compile")
			end
			return loader()
		end)
		if success and type(result) == "table" then
			return true, result, nil
		end
		lastError = tostring(result)
	end
	return false, nil, lastError
end
local rayfieldLoaded, Rayfield, rayfieldLoadError = loadRayfieldLibrary()
if rayfieldLoaded and Rayfield then
	local uiBuildSuccess, uiBuildError = xpcall(function()
		rayfieldInterface = Rayfield
		mainWindow.Visible = false
	local Window = Rayfield:CreateWindow({
		Name = "Beano GUI",
		Icon = "sparkles",
		LoadingTitle = "Beano GUI",
		LoadingSubtitle = "Rayfield interface",
		ShowText = "Beano",
		Theme = "Amethyst",
		ToggleUIKeybind = "F8",
		DisableRayfieldPrompts = true,
		DisableBuildWarnings = true,
		ConfigurationSaving = {
			Enabled = true,
			FolderName = "BeanoGUI",
			FileName = "settings",
		},
		Discord = {
			Enabled = false,
			Invite = "",
			RememberJoins = false,
		},
		KeySystem = false,
	})
	local MovementTab = Window:CreateTab("Movement", "person-standing")
	MovementTab:CreateSection("Character movement")
	local walkSpeedSlider = MovementTab:CreateSlider({
		Name = "Walk speed",
		Range = {minimumSpeed, maximumSpeed},
		Increment = 1,
		Suffix = " speed",
		CurrentValue = targetSpeed,
		Flag = "beano_walk_speed",
		Callback = function(value)
			targetSpeed = value
			applySpeed()
		end,
	})
	local jumpHeightSlider = MovementTab:CreateSlider({
		Name = "Jump height",
		Range = {minimumJumpHeight, maximumJumpHeight},
		Increment = 0.1,
		Suffix = " studs",
		CurrentValue = targetJumpHeight,
		Flag = "beano_jump_height",
		Callback = function(value)
			targetJumpHeight = value
			applyJumpHeight()
		end,
	})
	local movementLockToggle = MovementTab:CreateToggle({
		Name = "Continuously enforce movement",
		CurrentValue = movementLockEnabled,
		Flag = "beano_movement_lock",
		Callback = function(value)
			movementLockEnabled = value
			if value then
				applySpeed()
				applyJumpHeight()
			end
		end,
	})
	MovementTab:CreateButton({
		Name = "Restore normal movement",
		Callback = function()
			walkSpeedSlider:Set(16)
			jumpHeightSlider:Set(7.2)
		end,
	})
	MovementTab:CreateButton({
		Name = "Stop script",
		Callback = function()
			stopScript()
		end,
	})
	local RolesTab = Window:CreateTab("Roles", "scan-eye")
	RolesTab:CreateSection("Role ESP")
	RolesTab:CreateToggle({
		Name = "Role highlights",
		CurrentValue = roleHighlightsEnabled,
		Flag = "beano_role_highlights",
		Callback = function(value)
			roleHighlightsEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	RolesTab:CreateToggle({
		Name = "Character chams",
		CurrentValue = roleChamsEnabled,
		Flag = "beano_role_chams",
		Callback = function(value)
			roleChamsEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	RolesTab:CreateToggle({
		Name = "Role names",
		CurrentValue = roleNamesEnabled,
		Flag = "beano_role_names",
		Callback = function(value)
			roleNamesEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	local roleLinesToggle = RolesTab:CreateToggle({
		Name = "Role lines",
		CurrentValue = roleLinesEnabled,
		Flag = "beano_role_lines",
		Callback = function(value)
			roleLinesEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	RolesTab:CreateSection("Role teleport")
	RolesTab:CreateButton({
		Name = "Teleport to Sheriff / Hero",
		Callback = function()
			teleportToRole("Sheriff / Hero")
		end,
	})
	RolesTab:CreateButton({
		Name = "Teleport to Murderer",
		Callback = function()
			teleportToRole("Murderer")
		end,
	})
	local PlayersTab = Window:CreateTab("Players", "users")
	PlayersTab:CreateSection("Selected player")
	local playerOptionMap = {}
	local lastPlayerListSignature = ""
	local function buildPlayerOptions()
		local options = {}
		local newMap = {}
		for _, targetPlayer in ipairs(Players:GetPlayers()) do
			if targetPlayer ~= player then
				local option = targetPlayer.DisplayName .. " (@" .. targetPlayer.Name .. ")"
				table.insert(options, option)
				newMap[option] = targetPlayer
			end
		end
		table.sort(options)
		if #options == 0 then
			table.insert(options, "No other players")
		end
		return options, newMap
	end
	local initialPlayerOptions
	initialPlayerOptions, playerOptionMap = buildPlayerOptions()
	lastPlayerListSignature = table.concat(initialPlayerOptions, "\n")
	local selectedPlayerDropdown = PlayersTab:CreateDropdown({
		Name = "Select player",
		Options = initialPlayerOptions,
		CurrentOption = {initialPlayerOptions[1]},
		MultipleOptions = false,
		Callback = function(options)
			local option = type(options) == "table" and options[1] or options
			selectedPlayer = playerOptionMap[option]
		end,
	})
	selectedPlayer = playerOptionMap[initialPlayerOptions[1]]
	local function notifyPlayerAction(title, content)
		Rayfield:Notify({
			Title = title,
			Content = content,
			Duration = 5,
			Image = "users",
		})
	end
	local function validSelectedPlayer()
		if selectedPlayer and selectedPlayer.Parent == Players and selectedPlayer ~= player then
			return selectedPlayer
		end
		notifyPlayerAction("No player selected", "Choose a current player from the dropdown first.")
		return nil
	end
	PlayersTab:CreateButton({
		Name = "Teleport to selected player",
		Callback = function()
			local targetPlayer = validSelectedPlayer()
			local localRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local targetRoot = targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not localRoot or not targetRoot then
				notifyPlayerAction("Teleport unavailable", "One of the characters is not currently loaded.")
				return
			end
			localRoot.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
		end,
	})
	PlayersTab:CreateButton({
		Name = "Spectate selected player",
		Callback = function()
			local targetPlayer = validSelectedPlayer()
			local targetHumanoid = targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChildOfClass("Humanoid")
			local camera = Workspace.CurrentCamera
			if not camera or not targetHumanoid then
				notifyPlayerAction("Spectate unavailable", "The selected character is not currently loaded.")
				return
			end
			spectatingPlayer = targetPlayer
			camera.CameraSubject = targetHumanoid
		end,
	})
	PlayersTab:CreateButton({
		Name = "Stop spectating",
		Callback = function()
			spectatingPlayer = nil
			local camera = Workspace.CurrentCamera
			local humanoid = getHumanoid()
			if camera and humanoid then
				camera.CameraSubject = humanoid
			end
		end,
	})
	local function flingTargetPlayer(targetPlayer)
			if not targetPlayer or flingInProgress then
				if flingInProgress then
					notifyPlayerAction("Fling already running", "Wait for the current action to restore your position.")
				end
				return
			end
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local targetRoot = targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not character or not humanoid or not root or not targetRoot then
				notifyPlayerAction("Fling unavailable", "One of the characters is not currently loaded.")
				return
			end
			flingInProgress = true
			task.spawn(function()
				local originalCFrame = root.CFrame
				local originalAutoRotate = humanoid.AutoRotate
				local originalPlatformStand = humanoid.PlatformStand
				local targetStartPosition = targetRoot.Position
				local collisionStates = {}
				for _, descendant in ipairs(character:GetDescendants()) do
					if descendant:IsA("BasePart") then
						collisionStates[descendant] = {
							CanCollide = descendant.CanCollide,
							CanTouch = descendant.CanTouch,
						}
						descendant.CanCollide = descendant == root
						descendant.CanTouch = descendant == root
					end
				end
				local angularVelocity = Instance.new("BodyAngularVelocity")
				angularVelocity.Name = "BeanoFlingVelocity"
				angularVelocity.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
				angularVelocity.P = 1000000
				angularVelocity.AngularVelocity = Vector3.new(0, 9999, 0)
				angularVelocity.Parent = root
				local stabilizer = Instance.new("BodyPosition")
				stabilizer.Name = "BeanoFlingStabilizer"
				stabilizer.MaxForce = Vector3.new(1000000000, 1000000000, 1000000000)
				stabilizer.P = 100000
				stabilizer.D = 2500
				stabilizer.Position = targetRoot.Position
				stabilizer.Parent = root
				humanoid.AutoRotate = false
				humanoid.PlatformStand = true
				local succeeded = false
				local deadline = os.clock() + 5
				local step = 0
				pcall(function()
					while os.clock() < deadline do
						if stopped or not flingInProgress or not root.Parent or not targetRoot.Parent then
							break
						end
						local targetSpeed = targetRoot.AssemblyLinearVelocity.Magnitude
						local targetDistance = (targetRoot.Position - targetStartPosition).Magnitude
						if targetSpeed >= 120 or targetDistance >= 75 then
							succeeded = true
							break
						end
						step += 1
						local phase = step % 4
						local offset = phase == 0 and CFrame.new(0, 0.25, 0)
							or phase == 1 and CFrame.new(0.8, 0, 0)
							or phase == 2 and CFrame.new(-0.8, 0, 0)
							or CFrame.new(0, -0.25, 0.8)
						local contactCFrame = targetRoot.CFrame * offset
						stabilizer.Position = contactCFrame.Position
						root.CFrame = contactCFrame
						root.AssemblyLinearVelocity = Vector3.zero
						RunService.Heartbeat:Wait()
					end
				end)
				if stabilizer.Parent then
					stabilizer:Destroy()
				end
				if angularVelocity.Parent then
					angularVelocity:Destroy()
				end
				for part, state in pairs(collisionStates) do
					if part.Parent then
						part.CanCollide = state.CanCollide
						part.CanTouch = state.CanTouch
					end
				end
				if humanoid.Parent then
					humanoid.AutoRotate = originalAutoRotate
					humanoid.PlatformStand = originalPlatformStand
				end
				if root.Parent then
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					root.CFrame = originalCFrame
					task.wait()
					if root.Parent then
						root.CFrame = originalCFrame
					end
				end
				flingInProgress = false
				if not stopped then
					notifyPlayerAction(
						succeeded and "Fling completed" or "Fling stopped",
						succeeded and "The target was launched and your original position was restored."
							or "The five-second attempt ended and your original position was restored."
					)
				end
			end)
	end
	PlayersTab:CreateButton({
		Name = "Fling selected player",
		Callback = function()
			flingTargetPlayer(validSelectedPlayer())
		end,
	})
	RolesTab:CreateSection("Role fling")
	RolesTab:CreateButton({
		Name = "Fling Sheriff / Hero",
		Callback = function()
			local targetPlayer = findPlayerByRole("Sheriff / Hero")
			if not targetPlayer then
				notifyPlayerAction("Role not found", "No active Sheriff or Hero was detected.")
				return
			end
			flingTargetPlayer(targetPlayer)
		end,
	})
	RolesTab:CreateButton({
		Name = "Fling Murderer",
		Callback = function()
			local targetPlayer = findPlayerByRole("Murderer")
			if not targetPlayer then
				notifyPlayerAction("Role not found", "No active Murderer was detected.")
				return
			end
			flingTargetPlayer(targetPlayer)
		end,
	})
	local function refreshPlayerDropdown()
		local options, newMap = buildPlayerOptions()
		local signature = table.concat(options, "\n")
		if signature == lastPlayerListSignature then
			return
		end
		lastPlayerListSignature = signature
		playerOptionMap = newMap
		selectedPlayerDropdown:Refresh(options)
		if not selectedPlayer or selectedPlayer.Parent ~= Players then
			selectedPlayerDropdown:Set({options[1]})
		else
			local selectedOption = selectedPlayer.DisplayName .. " (@" .. selectedPlayer.Name .. ")"
			selectedPlayerDropdown:Set({selectedOption})
		end
	end
	task.spawn(function()
		while not stopped and rayfieldInterface == Rayfield do
			task.wait(5)
			if not stopped then
				pcall(refreshPlayerDropdown)
			end
		end
	end)
	RolesTab:CreateSection("Dropped gun")
	RolesTab:CreateToggle({
		Name = "Auto pickup dropped gun",
		CurrentValue = autoPickupGunEnabled,
		Flag = "beano_auto_pickup_gun",
		Callback = function(value)
			autoPickupGunEnabled = value
			updateAutoPickupGunButton()
		end,
	})
	RolesTab:CreateToggle({
		Name = "Dropped gun ESP",
		CurrentValue = gunChamEnabled,
		Flag = "beano_gun_esp",
		Callback = function(value)
			gunChamEnabled = value
			gunScanRequested = true
			updateDroppedGunCham(findDroppedGun())
		end,
	})
	RolesTab:CreateSection("ESP appearance")
	RolesTab:CreateSlider({
		Name = "Role cham opacity",
		Range = {0, 100},
		Increment = 5,
		Suffix = "%",
		CurrentValue = math.floor((1 - roleFillTransparency) * 100 + 0.5),
		Flag = "beano_role_cham_opacity",
		Callback = function(value)
			roleFillTransparency = 1 - (value / 100)
			refreshRoleHighlights()
		end,
	})
	RolesTab:CreateSlider({
		Name = "Role line width",
		Range = {0.03, 0.3},
		Increment = 0.01,
		Suffix = " studs",
		CurrentValue = roleLineWidth,
		Flag = "beano_role_line_width",
		Callback = function(value)
			roleLineWidth = value
			refreshRoleHighlights()
		end,
	})
	RolesTab:CreateSlider({
		Name = "Gun ESP opacity",
		Range = {0, 100},
		Increment = 5,
		Suffix = "%",
		CurrentValue = math.floor((1 - gunFillTransparency) * 100 + 0.5),
		Flag = "beano_gun_esp_opacity",
		Callback = function(value)
			gunFillTransparency = 1 - (value / 100)
			if droppedGunHighlight then
				droppedGunHighlight.FillTransparency = gunFillTransparency
			end
		end,
	})
	local CombatTab = Window:CreateTab("Combat", "swords")
	CombatTab:CreateSection("Murderer tools")
	CombatTab:CreateToggle({
		Name = "Knife kill aura",
		CurrentValue = killAuraEnabled,
		Flag = "beano_kill_aura",
		Callback = function(value)
			killAuraEnabled = value
			if value and not executorTouchFunction() then
				Rayfield:Notify({
					Title = "Kill Aura unsupported",
					Content = "This executor does not expose firetouchinterest.",
					Duration = 6,
					Image = "triangle-alert",
				})
			end
		end,
	})
	CombatTab:CreateSlider({
		Name = "Kill aura radius",
		Range = {5, 30},
		Increment = 1,
		Suffix = " studs",
		CurrentValue = killAuraRadius,
		Flag = "beano_kill_aura_radius",
		Callback = function(value)
			killAuraRadius = value
		end,
	})
	CombatTab:CreateSlider({
		Name = "Kill aura interval",
		Range = {0.1, 0.5},
		Increment = 0.05,
		Suffix = " sec",
		CurrentValue = killAuraInterval,
		Flag = "beano_kill_aura_interval",
		Callback = function(value)
			killAuraInterval = value
		end,
	})
	CombatTab:CreateSection("Silent")
	CombatTab:CreateLabel("Gun-remote-only redirection. It does not touch camera raycasts or screen position.", "crosshair")
	local silentToggle = CombatTab:CreateToggle({
		Name = "Silent",
		CurrentValue = silentState.Enabled,
		Flag = "beano_silent_enabled",
		Callback = function(value)
			silentState.Enabled = value
			silentState.Method = "Gun remote"
			if not value then
				hideSilentDrawings()
			elseif not silentState.HookSupported then
				Rayfield:Notify({
					Title = "Silent unsupported",
					Content = "This executor is missing one or more required metamethod hook functions.",
					Duration = 7,
					Image = "triangle-alert",
				})
			end
		end,
	})
	CombatTab:CreateKeybind({
		Name = "Silent toggle key",
		CurrentKeybind = "RightAlt",
		HoldToInteract = false,
		Flag = "beano_silent_keybind",
		Callback = function()
			 silentToggle:Set(not silentState.Enabled)
		end,
	})
	CombatTab:CreateToggle({
		Name = "Shoot murderer hotkey",
		CurrentValue = silentState.ShootMurdererEnabled,
		Flag = "beano_silent_shoot_murderer_enabled",
		Callback = function(value)
			silentState.ShootMurdererEnabled = value
		end,
	})
	CombatTab:CreateKeybind({
		Name = "Shoot murderer key",
		CurrentKeybind = "E",
		HoldToInteract = false,
		Flag = "beano_silent_shoot_murderer_key",
		Callback = function()
			if not silentState.ShootMurdererEnabled then
				return
			end
			local success, message = silentState.ShootMurderer()
			if not success and message then
				Rayfield:Notify({
					Title = "Silent could not shoot",
					Content = message,
					Duration = 4,
					Image = "triangle-alert",
				})
			end
		end,
	})
	CombatTab:CreateToggle({
		Name = "Silent team check",
		CurrentValue = silentState.TeamCheck,
		Flag = "beano_silent_team_check",
		Callback = function(value)
			silentState.TeamCheck = value
		end,
	})
	CombatTab:CreateToggle({
		Name = "Silent visibility check",
		CurrentValue = silentState.VisibleCheck,
		Flag = "beano_silent_visible_check",
		Callback = function(value)
			silentState.VisibleCheck = value
		end,
	})
	CombatTab:CreateDropdown({
		Name = "Silent target part",
		Options = {"HumanoidRootPart", "Head", "Random"},
		CurrentOption = {silentState.TargetPart},
		MultipleOptions = false,
		Flag = "beano_silent_target_part",
		Callback = function(options)
			silentState.TargetPart = options[1] or "HumanoidRootPart"
		end,
	})
	CombatTab:CreateDropdown({
		Name = "Silent aim method",
		Options = {"Gun remote"},
		CurrentOption = {silentState.Method},
		MultipleOptions = false,
		Flag = "beano_silent_method",
		Callback = function()
			silentState.Method = "Gun remote"
		end,
	})
	CombatTab:CreateSlider({
		Name = "Silent hit chance",
		Range = {0, 100},
		Increment = 1,
		Suffix = "%",
		CurrentValue = silentState.HitChance,
		Flag = "beano_silent_hit_chance",
		Callback = function(value)
			silentState.HitChance = value
		end,
	})
	CombatTab:CreateSlider({
		Name = "Silent FOV radius",
		Range = {20, 360},
		Increment = 5,
		Suffix = " px",
		CurrentValue = silentState.FOVRadius,
		Flag = "beano_silent_fov_radius",
		Callback = function(value)
			silentState.FOVRadius = value
		end,
	})
	CombatTab:CreateToggle({
		Name = "Show Silent FOV circle",
		CurrentValue = silentState.FOVVisible,
		Flag = "beano_silent_fov_visible",
		Callback = function(value)
			silentState.FOVVisible = value
		end,
	})
	CombatTab:CreateToggle({
		Name = "Show Silent target marker",
		CurrentValue = silentState.ShowTarget,
		Flag = "beano_silent_show_target",
		Callback = function(value)
			silentState.ShowTarget = value
		end,
	})
	CombatTab:CreateToggle({
		Name = "Silent movement prediction",
		CurrentValue = silentState.Prediction,
		Flag = "beano_silent_prediction",
		Callback = function(value)
			silentState.Prediction = value
		end,
	})
	CombatTab:CreateSlider({
		Name = "Silent prediction amount",
		Range = {0, 1},
		Increment = 0.005,
		CurrentValue = silentState.PredictionAmount,
		Flag = "beano_silent_prediction_amount",
		Callback = function(value)
			silentState.PredictionAmount = value
		end,
	})
	local AutomationTab = Window:CreateTab("Automation", "orbit")
	AutomationTab:CreateSection("Coin collection")
	AutomationTab:CreateLabel("Fixed 10-stud range with balanced scan timing.", "circle-dollar-sign")
	AutomationTab:CreateToggle({
		Name = "Coin collection aura",
		CurrentValue = coinAuraEnabled,
		Flag = "beano_coin_aura",
		Callback = function(value)
			coinAuraEnabled = value
			if value then
				task.spawn(rebuildCoinCache)
				if not executorTouchFunction() then
					Rayfield:Notify({
						Title = "Coin Aura unsupported",
						Content = "This executor does not expose firetouchinterest.",
						Duration = 6,
						Image = "triangle-alert",
					})
				end
			end
		end,
	})
	local TradeTab = Window:CreateTab("Trade", "scale")
	TradeTab:CreateSection("Supreme value calculator")
	TradeTab:CreateToggle({
		Name = "Show value in game trade window",
		CurrentValue = tradeOverlayEnabled,
		Flag = "beano_trade_overlay",
		Callback = function(value)
			tradeOverlayEnabled = value
			updateBuiltInTradeSummary()
		end,
	})
	TradeTab:CreateDropdown({
		Name = "Trade overlay position",
		Options = {"Top", "Bottom"},
		CurrentOption = {tradeOverlayPosition},
		MultipleOptions = false,
		Flag = "beano_trade_overlay_position",
		Callback = function(options)
			tradeOverlayPosition = options[1] or "Top"
			updateBuiltInTradeSummary()
		end,
	})
	local yourTradeInput = TradeTab:CreateInput({
		Name = "Your items",
		CurrentValue = "",
		PlaceholderText = "Harvester, 2x Luger",
		RemoveTextAfterFocusLost = false,
		Flag = "beano_your_trade_items",
		Callback = function(text)
			yourItemsInput.Text = text
			calculateCurrentTrade()
		end,
	})
	local theirTradeInput = TradeTab:CreateInput({
		Name = "Their items",
		CurrentValue = "",
		PlaceholderText = "Chroma Luger",
		RemoveTextAfterFocusLost = false,
		Flag = "beano_their_trade_items",
		Callback = function(text)
			theirItemsInput.Text = text
			calculateCurrentTrade()
		end,
	})
	local function updateRayfieldTradeResult()
		updateBuiltInTradeSummary()
	end
	TradeTab:CreateButton({
		Name = "Calculate trade",
		Callback = function()
			calculateCurrentTrade()
			updateRayfieldTradeResult()
		end,
	})
	TradeTab:CreateButton({
		Name = "Scan visible trade",
		Callback = function()
			local totals, names = scanVisibleTrade()
			if #names.You == 0 and #names.Them == 0 and #names.Other == 0 then
				tradeResult.Text = "No visible trade offer items found. Open the trade window and try again."
				updateRayfieldTradeResult()
				return
			end
			yourItemsInput.Text = table.concat(names.You, ", ")
			theirItemsInput.Text = table.concat(names.Them, ", ")
			yourTradeInput:Set(yourItemsInput.Text)
			theirTradeInput:Set(theirItemsInput.Text)
			local unknown = {}
			if #names.Other > 0 then
				table.insert(unknown, "Unassigned: " .. table.concat(names.Other, ", "))
			end
			showTradeTotals(totals.You, totals.Them, unknown)
			updateRayfieldTradeResult()
		end,
	})
	local function createMiniGameShell(title)
		local existing = playerGui:FindFirstChild("BeanoMiniGame")
		if existing then
			existing:Destroy()
		end
		local miniGui = Instance.new("ScreenGui")
		miniGui.Name = "BeanoMiniGame"
		miniGui.ResetOnSpawn = false
		miniGui.IgnoreGuiInset = false
		miniGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		miniGui.DisplayOrder = 1000
		miniGui.Parent = playerGui
		local window = Instance.new("Frame")
		window.Name = "Window"
		window.AnchorPoint = Vector2.new(0.5, 0.5)
		window.Position = UDim2.fromScale(0.5, 0.5)
		window.Size = UDim2.fromOffset(410, 520)
		window.BackgroundColor3 = Color3.fromRGB(29, 20, 38)
		window.BorderSizePixel = 0
		window.Parent = miniGui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = window
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(164, 112, 190)
		stroke.Transparency = 0.3
		stroke.Thickness = 1.5
		stroke.Parent = window
		local header = Instance.new("Frame")
		header.BackgroundColor3 = Color3.fromRGB(43, 28, 55)
		header.BorderSizePixel = 0
		header.Size = UDim2.new(1, 0, 0, 50)
		header.Parent = window
		local headerCorner = Instance.new("UICorner")
		headerCorner.CornerRadius = UDim.new(0, 12)
		headerCorner.Parent = header
		local headerCover = Instance.new("Frame")
		headerCover.BackgroundColor3 = header.BackgroundColor3
		headerCover.BorderSizePixel = 0
		headerCover.Position = UDim2.new(0, 0, 1, -12)
		headerCover.Size = UDim2.new(1, 0, 0, 12)
		headerCover.Parent = header
		local titleLabel = Instance.new("TextLabel")
		titleLabel.BackgroundTransparency = 1
		titleLabel.Position = UDim2.fromOffset(18, 0)
		titleLabel.Size = UDim2.new(1, -70, 1, 0)
		titleLabel.Font = Enum.Font.GothamBold
		titleLabel.Text = title
		titleLabel.TextColor3 = Color3.fromRGB(245, 240, 250)
		titleLabel.TextSize = 18
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.Parent = header
		local closeButton = Instance.new("TextButton")
		closeButton.AnchorPoint = Vector2.new(1, 0.5)
		closeButton.Position = UDim2.new(1, -12, 0.5, 0)
		closeButton.Size = UDim2.fromOffset(34, 34)
		closeButton.BackgroundColor3 = Color3.fromRGB(72, 43, 85)
		closeButton.BorderSizePixel = 0
		closeButton.Font = Enum.Font.GothamBold
		closeButton.Text = "X"
		closeButton.TextColor3 = Color3.fromRGB(255, 225, 235)
		closeButton.TextSize = 15
		closeButton.Parent = header
		local closeCorner = Instance.new("UICorner")
		closeCorner.CornerRadius = UDim.new(0, 8)
		closeCorner.Parent = closeButton
		closeButton.Activated:Connect(function()
			miniGui:Destroy()
		end)
		local body = Instance.new("Frame")
		body.BackgroundTransparency = 1
		body.Position = UDim2.fromOffset(18, 66)
		body.Size = UDim2.new(1, -36, 1, -84)
		body.Parent = window
		return miniGui, body
	end
	local function makeGameLabel(parent, text, position, size, textSize)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = position
		label.Size = size
		label.Font = Enum.Font.GothamMedium
		label.Text = text
		label.TextColor3 = Color3.fromRGB(230, 220, 238)
		label.TextSize = textSize or 16
		label.TextWrapped = true
		label.Parent = parent
		return label
	end
	local function makeGameButton(parent, text, position, size)
		local button = Instance.new("TextButton")
		button.BackgroundColor3 = Color3.fromRGB(75, 49, 91)
		button.BorderSizePixel = 0
		button.Position = position
		button.Size = size
		button.Font = Enum.Font.GothamBold
		button.Text = text
		button.TextColor3 = Color3.fromRGB(250, 245, 255)
		button.TextSize = 17
		button.AutoButtonColor = true
		button.Parent = parent
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 9)
		corner.Parent = button
		return button
	end
	local function launchTicTacToe()
		local miniGui, body = createMiniGameShell("Tic-Tac-Toe")
		local statusLabel = makeGameLabel(body, "You are X - make the first move", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 38), 16)
		local gridFrame = Instance.new("Frame")
		gridFrame.BackgroundTransparency = 1
		gridFrame.AnchorPoint = Vector2.new(0.5, 0)
		gridFrame.Position = UDim2.new(0.5, 0, 0, 52)
		gridFrame.Size = UDim2.fromOffset(315, 315)
		gridFrame.Parent = body
		local layout = Instance.new("UIGridLayout")
		layout.CellPadding = UDim2.fromOffset(7, 7)
		layout.CellSize = UDim2.fromOffset(100, 100)
		layout.Parent = gridFrame
		local board = table.create(9, "")
		local buttons = {}
		local active = true
		local combinations = {
			{1, 2, 3}, {4, 5, 6}, {7, 8, 9},
			{1, 4, 7}, {2, 5, 8}, {3, 6, 9},
			{1, 5, 9}, {3, 5, 7},
		}
		local function getResult()
			for _, combination in ipairs(combinations) do
				local a, b, c = combination[1], combination[2], combination[3]
				if board[a] ~= "" and board[a] == board[b] and board[b] == board[c] then
					return board[a]
				end
			end
			for index = 1, 9 do
				if board[index] == "" then
					return nil
				end
			end
			return "Draw"
		end
		local function finishIfNeeded()
			local result = getResult()
			if not result then
				return false
			end
			active = false
			statusLabel.Text = result == "Draw" and "Draw! Press Play Again for a new board."
				or result == "X" and "You won!"
				or "Computer won!"
			return true
		end
		local function computerMove()
			if not active or not miniGui.Parent then
				return
			end
			local choices = {}
			for index = 1, 9 do
				if board[index] == "" then
					table.insert(choices, index)
				end
			end
			if #choices > 0 then
				local index = choices[math.random(1, #choices)]
				board[index] = "O"
				buttons[index].Text = "O"
				buttons[index].TextColor3 = Color3.fromRGB(255, 185, 130)
			end
			if not finishIfNeeded() then
				statusLabel.Text = "Your turn"
			end
		end
		for index = 1, 9 do
			local button = makeGameButton(gridFrame, "", UDim2.new(), UDim2.new())
			button.TextSize = 38
			buttons[index] = button
			button.Activated:Connect(function()
				if not active or board[index] ~= "" then
					return
				end
				board[index] = "X"
				button.Text = "X"
				button.TextColor3 = Color3.fromRGB(185, 135, 255)
				if not finishIfNeeded() then
					statusLabel.Text = "Computer is thinking..."
					task.delay(0.3, computerMove)
				end
			end)
		end
		local replayButton = makeGameButton(body, "PLAY AGAIN", UDim2.new(0.5, -110, 0, 382), UDim2.fromOffset(220, 42))
		replayButton.Activated:Connect(function()
			miniGui:Destroy()
			launchTicTacToe()
		end)
	end
	local function launchMemoryMatch()
		local miniGui, body = createMiniGameShell("Memory Match")
		local statusLabel = makeGameLabel(body, "Find all eight matching pairs", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 36), 16)
		local gridFrame = Instance.new("Frame")
		gridFrame.BackgroundTransparency = 1
		gridFrame.AnchorPoint = Vector2.new(0.5, 0)
		gridFrame.Position = UDim2.new(0.5, 0, 0, 48)
		gridFrame.Size = UDim2.fromOffset(328, 328)
		gridFrame.Parent = body
		local layout = Instance.new("UIGridLayout")
		layout.CellPadding = UDim2.fromOffset(6, 6)
		layout.CellSize = UDim2.fromOffset(77, 77)
		layout.Parent = gridFrame
		local cards = {"A", "A", "B", "B", "C", "C", "D", "D", "E", "E", "F", "F", "G", "G", "H", "H"}
		for index = #cards, 2, -1 do
			local other = math.random(1, index)
			cards[index], cards[other] = cards[other], cards[index]
		end
		local buttons = {}
		local matched = {}
		local firstIndex = nil
		local locked = false
		local pairsFound = 0
		for index = 1, 16 do
			local button = makeGameButton(gridFrame, "?", UDim2.new(), UDim2.new())
			button.TextSize = 25
			buttons[index] = button
			button.Activated:Connect(function()
				if locked or matched[index] or firstIndex == index then
					return
				end
				button.Text = cards[index]
				button.BackgroundColor3 = Color3.fromRGB(118, 75, 143)
				if not firstIndex then
					firstIndex = index
					return
				end
				local previousIndex = firstIndex
				firstIndex = nil
				if cards[previousIndex] == cards[index] then
					matched[previousIndex] = true
					matched[index] = true
					pairsFound += 1
					statusLabel.Text = ("Pairs found: %d / 8"):format(pairsFound)
					if pairsFound == 8 then
						statusLabel.Text = "You matched every pair!"
					end
				else
					locked = true
					task.delay(0.7, function()
						if miniGui.Parent then
							buttons[previousIndex].Text = "?"
							buttons[index].Text = "?"
							buttons[previousIndex].BackgroundColor3 = Color3.fromRGB(75, 49, 91)
							buttons[index].BackgroundColor3 = Color3.fromRGB(75, 49, 91)
						end
						locked = false
					end)
				end
			end)
		end
		local replayButton = makeGameButton(body, "PLAY AGAIN", UDim2.new(0.5, -110, 0, 382), UDim2.fromOffset(220, 42))
		replayButton.Activated:Connect(function()
			miniGui:Destroy()
			launchMemoryMatch()
		end)
	end
	local function launchReactionTest()
		local miniGui, body = createMiniGameShell("Reaction Test")
		local statusLabel = makeGameLabel(body, "Press Start, then wait for green", UDim2.fromOffset(0, 20), UDim2.new(1, 0, 0, 55), 18)
		local reactionButton = makeGameButton(body, "START", UDim2.new(0.5, -145, 0, 110), UDim2.fromOffset(290, 190))
		reactionButton.TextSize = 28
		local waiting = false
		local ready = false
		local startedAt = 0
		local roundToken = 0
		reactionButton.Activated:Connect(function()
			if ready then
				local reactionMilliseconds = math.floor((os.clock() - startedAt) * 1000 + 0.5)
				ready = false
				waiting = false
				reactionButton.Text = "PLAY AGAIN"
				reactionButton.BackgroundColor3 = Color3.fromRGB(75, 49, 91)
				statusLabel.Text = ("Reaction time: %d ms"):format(reactionMilliseconds)
				return
			end
			if waiting then
				roundToken += 1
				waiting = false
				reactionButton.Text = "TRY AGAIN"
				reactionButton.BackgroundColor3 = Color3.fromRGB(135, 50, 65)
				statusLabel.Text = "Too soon! Wait for the button to turn green."
				return
			end
			waiting = true
			roundToken += 1
			local currentToken = roundToken
			reactionButton.Text = "WAIT..."
			reactionButton.BackgroundColor3 = Color3.fromRGB(135, 50, 65)
			statusLabel.Text = "Get ready..."
			task.delay(math.random(15, 40) / 10, function()
				if miniGui.Parent and waiting and currentToken == roundToken then
					ready = true
					startedAt = os.clock()
					reactionButton.Text = "CLICK!"
					reactionButton.BackgroundColor3 = Color3.fromRGB(45, 160, 90)
					statusLabel.Text = "Now!"
				end
			end)
		end)
		local replayButton = makeGameButton(body, "RESET GAME", UDim2.new(0.5, -110, 0, 330), UDim2.fromOffset(220, 48))
		replayButton.Activated:Connect(function()
			roundToken += 1
			miniGui:Destroy()
			launchReactionTest()
		end)
	end
	local function launchHigherLower()
		local miniGui, body = createMiniGameShell("Higher or Lower")
		local score = 0
		local currentValue = math.random(1, 99)
		local title = makeGameLabel(body, "Will the next number be higher or lower?", UDim2.fromOffset(0, 12), UDim2.new(1, 0, 0, 52), 17)
		local numberLabel = makeGameLabel(body, tostring(currentValue), UDim2.fromOffset(0, 78), UDim2.new(1, 0, 0, 110), 58)
		numberLabel.Font = Enum.Font.GothamBold
		numberLabel.TextColor3 = Color3.fromRGB(205, 155, 255)
		local scoreLabel = makeGameLabel(body, "Score: 0", UDim2.fromOffset(0, 196), UDim2.new(1, 0, 0, 34), 16)
		local higherButton = makeGameButton(body, "HIGHER", UDim2.new(0, 0, 0, 250), UDim2.new(0.48, 0, 0, 72))
		local lowerButton = makeGameButton(body, "LOWER", UDim2.new(0.52, 0, 0, 250), UDim2.new(0.48, 0, 0, 72))
		local function makeGuess(guessHigher)
			local nextValue
			repeat
				nextValue = math.random(1, 99)
			until nextValue ~= currentValue
			local correct = guessHigher and nextValue > currentValue or not guessHigher and nextValue < currentValue
			if correct then
				score += 1
				title.Text = "Correct! Keep going."
				title.TextColor3 = Color3.fromRGB(150, 255, 180)
			else
				score = 0
				title.Text = "Wrong! Your score was reset."
				title.TextColor3 = Color3.fromRGB(255, 160, 170)
			end
			currentValue = nextValue
			numberLabel.Text = tostring(currentValue)
			scoreLabel.Text = ("Score: %d"):format(score)
		end
		higherButton.Activated:Connect(function()
			makeGuess(true)
		end)
		lowerButton.Activated:Connect(function()
			makeGuess(false)
		end)
		local replayButton = makeGameButton(body, "PLAY AGAIN", UDim2.new(0.5, -110, 0, 350), UDim2.fromOffset(220, 48))
		replayButton.Activated:Connect(function()
			miniGui:Destroy()
			launchHigherLower()
		end)
	end
	local ArcadeTab = Window:CreateTab("Arcade", "gamepad-2")
	ArcadeTab:CreateSection("Mini games")
	ArcadeTab:CreateButton({
		Name = "Launch Minesweeper",
		Callback = function()
			local success, launchError = pcall(function()
				local source = game:HttpGet("https://script.roscripts.io/jgKlZMO")
				local loader, compileError = loadstring(source)
				if not loader then
					error(compileError or "Minesweeper source could not compile")
				end
				loader()
			end)
			Rayfield:Notify({
				Title = success and "Minesweeper launched" or "Minesweeper failed",
				Content = success and "The Minesweeper script was loaded."
					or tostring(launchError):sub(1, 180),
				Duration = 6,
				Image = success and "gamepad-2" or "triangle-alert",
			})
		end,
	})
	ArcadeTab:CreateButton({
		Name = "Play Tic-Tac-Toe",
		Callback = launchTicTacToe,
	})
	ArcadeTab:CreateButton({
		Name = "Play Memory Match",
		Callback = launchMemoryMatch,
	})
	ArcadeTab:CreateButton({
		Name = "Play Reaction Test",
		Callback = launchReactionTest,
	})
	ArcadeTab:CreateButton({
		Name = "Play Higher or Lower",
		Callback = launchHigherLower,
	})
	local SettingsTab = Window:CreateTab("Settings", "settings")
	SettingsTab:CreateSection("Interface")
	SettingsTab:CreateLabel("Use the keybind below to show or hide the interface.", "keyboard")
	SettingsTab:CreateKeybind({
		Name = "Show / hide GUI",
		CurrentKeybind = "LeftControl",
		HoldToInteract = false,
		Flag = "beano_ui_toggle_keybind",
		Callback = function()
			Rayfield:SetVisibility(not Rayfield:IsVisible())
		end,
	})
	SettingsTab:CreateDropdown({
		Name = "Theme",
		Options = {"Amethyst", "Default", "AmberGlow", "Bloom", "DarkBlue", "Green"},
		CurrentOption = {"Amethyst"},
		MultipleOptions = false,
		Flag = "beano_theme",
		Callback = function(options)
			Window.ModifyTheme(options[1] or "Amethyst")
		end,
	})
	SettingsTab:CreateSection("Performance")
	SettingsTab:CreateLabel("Higher intervals reduce script work; lower intervals react faster.", "gauge")
	local movementIntervalSlider = SettingsTab:CreateSlider({
		Name = "Movement check interval",
		Range = {0.05, 0.5},
		Increment = 0.05,
		Suffix = " sec",
		CurrentValue = movementApplyInterval,
		Flag = "beano_movement_interval",
		Callback = function(value)
			movementApplyInterval = value
		end,
	})
	local roleIntervalSlider = SettingsTab:CreateSlider({
		Name = "Role refresh interval",
		Range = {0.25, 2},
		Increment = 0.25,
		Suffix = " sec",
		CurrentValue = roleRefreshInterval,
		Flag = "beano_role_interval",
		Callback = function(value)
			roleRefreshInterval = value
		end,
	})
	local gunIntervalSlider = SettingsTab:CreateSlider({
		Name = "Dropped gun check interval",
		Range = {0.1, 2},
		Increment = 0.1,
		Suffix = " sec",
		CurrentValue = gunCheckInterval,
		Flag = "beano_gun_interval",
		Callback = function(value)
			gunCheckInterval = value
		end,
	})
	local pickupCooldownSlider = SettingsTab:CreateSlider({
		Name = "Gun pickup retry delay",
		Range = {0.25, 3},
		Increment = 0.25,
		Suffix = " sec",
		CurrentValue = gunPickupCooldown,
		Flag = "beano_gun_pickup_cooldown",
		Callback = function(value)
			gunPickupCooldown = value
		end,
	})
	local heroGraceSlider = SettingsTab:CreateSlider({
		Name = "Sheriff detection grace",
		Range = {1, 10},
		Increment = 1,
		Suffix = " sec",
		CurrentValue = roleGracePeriod,
		Flag = "beano_hero_grace_period",
		Callback = function(value)
			roleGracePeriod = value
		end,
	})
	SettingsTab:CreateButton({
		Name = "Apply balanced preset",
		Callback = function()
			movementIntervalSlider:Set(0.1)
			roleIntervalSlider:Set(0.75)
			gunIntervalSlider:Set(0.35)
			pickupCooldownSlider:Set(0.75)
			heroGraceSlider:Set(4)
		end,
	})
	SettingsTab:CreateButton({
		Name = "Apply low-lag preset",
		Callback = function()
			movementLockToggle:Set(false)
			roleLinesToggle:Set(false)
			movementIntervalSlider:Set(0.35)
			roleIntervalSlider:Set(2)
			gunIntervalSlider:Set(1.5)
			pickupCooldownSlider:Set(2)
			heroGraceSlider:Set(4)
			Rayfield:Notify({
				Title = "Low-lag preset applied",
				Content = "Movement enforcement and role lines are off. Scans now run at conservative intervals.",
				Duration = 5,
				Image = "gauge",
			})
		end,
	})
	SettingsTab:CreateSection("Diagnostics")
	SettingsTab:CreateButton({
		Name = "Refresh and show runtime status",
		Callback = function()
			gunScanRequested = true
			updateRoundRoleTracking()
			refreshRoleHighlights()
			local droppedGun = findDroppedGun()
			updateDroppedGunCham(droppedGun)
			updateBuiltInTradeSummary()
			local trackedCount = 0
			for _ in pairs(roleHighlights) do
				trackedCount += 1
			end
			Rayfield:Notify({
				Title = "Beano GUI status",
				Content = ("Connections: %d | Role displays: %d | Dropped gun: %s | Trade overlay: %s")
					:format(#connections, trackedCount, droppedGun and "found" or "not found", tradeOverlayEnabled and "on" or "off"),
				Duration = 6,
				Image = "activity",
			})
		end,
	})
	SettingsTab:CreateSection("Configurations")
	SettingsTab:CreateLabel("Profiles save every supported Rayfield control. The default settings profile also saves automatically.", "save")
	local selectedConfigName = "default"
	SettingsTab:CreateInput({
		Name = "Config profile name",
		CurrentValue = selectedConfigName,
		PlaceholderText = "default",
		RemoveTextAfterFocusLost = false,
		Callback = function(text)
			local cleaned = tostring(text or "")
				:gsub("[^%w_%- ]", "")
				:gsub("^%s+", "")
				:gsub("%s+$", "")
				:sub(1, 32)
			selectedConfigName = cleaned ~= "" and cleaned or "default"
		end,
	})
	local function configPath()
		return "BeanoGUI/Profiles/" .. selectedConfigName .. ".json"
	end
	local function ensureConfigFolder()
		if type(isfolder) ~= "function" or type(makefolder) ~= "function" then
			return false, "This executor does not provide filesystem folder functions."
		end
		if not isfolder("BeanoGUI") then
			makefolder("BeanoGUI")
		end
		if not isfolder("BeanoGUI/Profiles") then
			makefolder("BeanoGUI/Profiles")
		end
		return true
	end
	local function saveNamedConfiguration()
		if type(writefile) ~= "function" then
			return false, "This executor does not support writefile."
		end
		local folderReady, folderError = ensureConfigFolder()
		if not folderReady then
			return false, folderError
		end
		local data = {}
		for flagName, flag in pairs(Rayfield.Flags) do
			if flag.Type == "ColorPicker" and flag.Color then
				data[flagName] = {
					R = math.floor(flag.Color.R * 255 + 0.5),
					G = math.floor(flag.Color.G * 255 + 0.5),
					B = math.floor(flag.Color.B * 255 + 0.5),
				}
			elseif typeof(flag.CurrentValue) == "boolean" then
				data[flagName] = flag.CurrentValue
			else
				data[flagName] = flag.CurrentValue or flag.CurrentKeybind or flag.CurrentOption
			end
		end
		local encoded = HttpService:JSONEncode(data)
		writefile(configPath(), encoded)
		return true, ("Saved profile '%s'."):format(selectedConfigName)
	end
	local function loadNamedConfiguration()
		if type(isfile) ~= "function" or type(readfile) ~= "function" then
			return false, "This executor does not support config file reading."
		end
		local path = configPath()
		if not isfile(path) then
			return false, ("Profile '%s' does not exist."):format(selectedConfigName)
		end
		local decoded = HttpService:JSONDecode(readfile(path))
		local applied = 0
		for flagName, value in pairs(decoded) do
			local flag = Rayfield.Flags[flagName]
			if flag and type(flag.Set) == "function" then
				if flag.Type == "ColorPicker" and type(value) == "table" then
					flag:Set(Color3.fromRGB(value.R or 0, value.G or 0, value.B or 0))
				else
					flag:Set(value)
				end
				applied += 1
			end
		end
		return true, ("Loaded '%s' (%d settings)."):format(selectedConfigName, applied)
	end
	local function notifyConfigResult(success, message)
		Rayfield:Notify({
			Title = success and "Configuration ready" or "Configuration error",
			Content = tostring(message),
			Duration = 6,
			Image = success and "save" or "triangle-alert",
		})
	end
	SettingsTab:CreateButton({
		Name = "Save selected config",
		Callback = function()
			local success, result, detail = pcall(saveNamedConfiguration)
			if success then
				notifyConfigResult(result, detail)
			else
				notifyConfigResult(false, result)
			end
		end,
	})
	SettingsTab:CreateButton({
		Name = "Load selected config",
		Callback = function()
			local success, result, detail = pcall(loadNamedConfiguration)
			if success then
				notifyConfigResult(result, detail)
			else
				notifyConfigResult(false, result)
			end
		end,
	})
	SettingsTab:CreateButton({
		Name = "Delete selected config",
		Callback = function()
			local callSuccess, deleteSuccess, deleteMessage = pcall(function()
				if type(isfile) ~= "function" or type(delfile) ~= "function" then
					return false, "This executor does not support deleting config files."
				end
				local path = configPath()
				if not isfile(path) then
					return false, ("Profile '%s' does not exist."):format(selectedConfigName)
				end
				delfile(path)
				return true, ("Deleted profile '%s'."):format(selectedConfigName)
			end)
			if callSuccess then
				notifyConfigResult(deleteSuccess, deleteMessage)
			else
				notifyConfigResult(false, deleteSuccess)
			end
		end,
	})
	SettingsTab:CreateButton({
		Name = "Reload automatic settings config",
		Callback = function()
			local success, loadError = pcall(function()
				Rayfield:LoadConfiguration()
			end)
			notifyConfigResult(success, success and "Reloaded BeanoGUI/settings.rfld." or loadError)
		end,
	})
	SettingsTab:CreateSection("Server utilities")
	local autoReexecuteEnabled = false
	local loaderUrl = "https://raw.githubusercontent.com/BeANo20/beano-gui/main/beano-gui.lua"
	local queuedLoader = 'loadstring(game:HttpGet("' .. loaderUrl .. '?teleport=" .. tostring(os.time())))()'
	local function getTeleportQueue()
		local environment = (getgenv and getgenv()) or _G
		if type(environment.queue_on_teleport) == "function" then
			return environment.queue_on_teleport
		end
		if type(environment.syn) == "table" and type(environment.syn.queue_on_teleport) == "function" then
			return environment.syn.queue_on_teleport
		end
		if type(environment.fluxus) == "table" and type(environment.fluxus.queue_on_teleport) == "function" then
			return environment.fluxus.queue_on_teleport
		end
		return nil
	end
	local function queueReexecute()
		if not autoReexecuteEnabled then
			return true
		end
		local queueFunction = getTeleportQueue()
		if not queueFunction then
			return false, "Your executor does not support queue_on_teleport."
		end
		local success, queueError = pcall(queueFunction, queuedLoader)
		return success, queueError
	end
	SettingsTab:CreateToggle({
		Name = "Auto re-execute after teleport",
		CurrentValue = false,
		Flag = "beano_auto_reexecute",
		Callback = function(value)
			autoReexecuteEnabled = value
			if value then
				local success, queueError = queueReexecute()
				Rayfield:Notify({
					Title = success and "Auto re-execute ready" or "Auto re-execute unsupported",
					Content = success and "Beano GUI is queued for the next teleport."
						or tostring(queueError),
					Duration = 6,
					Image = success and "repeat-2" or "triangle-alert",
				})
			end
		end,
	})
	SettingsTab:CreateButton({
		Name = "Rejoin current server",
		Callback = function()
			local queued, queueError = queueReexecute()
			if not queued then
				Rayfield:Notify({Title = "Re-execute warning", Content = tostring(queueError), Duration = 5, Image = "triangle-alert"})
			end
			local success, teleportError = pcall(function()
				if game.JobId ~= "" then
					TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
				else
					TeleportService:Teleport(game.PlaceId, player)
				end
			end)
			if not success then
				Rayfield:Notify({Title = "Rejoin failed", Content = tostring(teleportError), Duration = 6, Image = "triangle-alert"})
			end
		end,
	})
	SettingsTab:CreateButton({
		Name = "Server hop",
		Callback = function()
			Rayfield:Notify({Title = "Finding server", Content = "Searching for an available public server...", Duration = 4, Image = "server"})
			task.spawn(function()
				local success, hopError = pcall(function()
					local cursor = nil
					local destination = nil
					for _ = 1, 3 do
						local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
						if cursor then
							url ..= "&cursor=" .. HttpService:UrlEncode(cursor)
						end
						local response = HttpService:JSONDecode(game:HttpGet(url))
						for _, server in ipairs(response.data or {}) do
							if server.id ~= game.JobId and server.playing < server.maxPlayers then
								destination = server.id
								break
							end
						end
						if destination then
							break
						end
						cursor = response.nextPageCursor
						if not cursor then
							break
						end
					end
					if not destination then
						error("No open public server was found.")
					end
					local queued, queueError = queueReexecute()
					if not queued then
						warn("Beano GUI auto re-execute: " .. tostring(queueError))
					end
					TeleportService:TeleportToPlaceInstance(game.PlaceId, destination, player)
				end)
				if not success then
					Rayfield:Notify({Title = "Server hop failed", Content = tostring(hopError):sub(1, 180), Duration = 7, Image = "triangle-alert"})
				end
			end)
		end,
	})
	SettingsTab:CreateButton({
		Name = "Copy current loader",
		Callback = function()
			local environment = (getgenv and getgenv()) or _G
			local clipboardFunction = environment.setclipboard or environment.toclipboard
			if type(clipboardFunction) ~= "function" then
				Rayfield:Notify({Title = "Clipboard unsupported", Content = "Your executor does not expose a clipboard function.", Duration = 5, Image = "triangle-alert"})
				return
			end
			clipboardFunction('loadstring(game:HttpGet("' .. loaderUrl .. '"))()')
			Rayfield:Notify({Title = "Loader copied", Content = "The latest Beano GUI loader is on your clipboard.", Duration = 5, Image = "clipboard-check"})
		end,
	})
	SettingsTab:CreateSection("Stop script")
	SettingsTab:CreateLabel("Kill disconnects every managed event and removes all script-created visuals.", "circle-stop")
	SettingsTab:CreateButton({
		Name = "Kill script completely",
		Callback = function()
			stopScript()
		end,
	})
	interfaceReady = true
	scheduleVisibleTradeRefresh()
	end, function(message)
		return tostring(message)
	end)
	if not uiBuildSuccess then
		warn("Beano GUI startup error: " .. tostring(uiBuildError))
		pcall(function()
			Rayfield:Destroy()
		end)
		pcall(function()
			StarterGui:SetCore("SendNotification", {
				Title = "Beano GUI failed to start",
				Text = tostring(uiBuildError):sub(1, 180),
				Duration = 12,
			})
		end)
	end
else
	warn("Rayfield could not load: " .. tostring(rayfieldLoadError))
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Beano GUI could not load Rayfield",
			Text = tostring(rayfieldLoadError):sub(1, 180),
			Duration = 12,
		})
	end)
end
