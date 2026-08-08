if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local environment = (getgenv and getgenv()) or _G
local Rayfield = nil
local statusLabel = nil
local masterToggle = nil
local updatingMasterToggle = false
local controls = {}

local RAYFIELD_URLS = {
	"https://sirius.menu/rayfield",
	"https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
}

local FLAG_NAMES = {
	"RedTeam",
	"Yellow Flag",
	"Purple Flag",
	"BlueTeam",
	"Green Emerald",
	"Pink Flag",
}

local TEAM_FOLDER_NAMES = {
	purple = "Purple",
	red = "Red",
	yellow = "Yellow",
	blue = "Blue",
	green = "Green",
	pink = "Pink",
}

local TELEPORT_OFFSET = Vector3.new(0, 2, 0)
local state = {
	Running = false,
	Stopped = false,
	RunId = 0,
	ScanId = 0,
	ScanningForTycoon = false,
	ActiveTycoon = nil,
	SelectedSlot = nil,
	TeamName = "Unknown",
	CoinSignalCount = 0,
	ButtonClaimEnabled = true,
	MoneyCollectEnabled = true,
	FlagCollectEnabled = false,
	AutoRebirthEnabled = false,
	RebirthInterval = 2,
	LastRebirthAt = 0,
	VisitFlagHitboxes = true,
	VisitClaimHitboxes = true,
	PadDelay = 0.05,
	CycleDelay = 0.1,
	LastStatus = "Claim a tycoon normally, select its slot, or scan for the owned base.",
	FlagCache = {},
	FlagCacheTime = 0,
	OnePassRunning = false,
	SelectedPlayer = nil,
	SpectatingPlayer = nil,
	FlingInProgress = false,
	ESPEnabled = false,
	ESPChamsEnabled = true,
	ESPNamesEnabled = true,
	ESPLinesEnabled = false,
	ESPColor = Color3.fromRGB(80, 200, 255),
	ESPFillTransparency = 0.55,
	ESPOutlineTransparency = 0,
	ESPLineWidth = 0.1,
	ESPNameSize = 14,
	ESPRefreshInterval = 0.5,
}

local connections = {}
local paidPadCache = setmetatable({}, {__mode = "k"})
local espEntries = {}

local function formatError(message)
	local text = tostring(message)
	if debug and type(debug.traceback) == "function" then
		return debug.traceback(text, 2)
	end
	return text
end

local function systemNotification(title, message, duration)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = tostring(title),
			Text = tostring(message):sub(1, 240),
			Duration = duration or 7,
		})
	end)
end

local function notify(title, message, image)
	if Rayfield then
		local success = pcall(function()
			Rayfield:Notify({
				Title = tostring(title),
				Content = tostring(message):sub(1, 300),
				Duration = 6,
				Image = image or "info",
			})
		end)
		if success then
			return
		end
	end
	systemNotification(title, message, 7)
end

local function updateStatus(message)
	if state.Stopped then
		return
	end
	message = tostring(message)
	if state.LastStatus == message then
		return
	end
	state.LastStatus = message
	if statusLabel then
		pcall(function()
			statusLabel:Set(message)
		end)
	end
end

local function fetchSource(url)
	local success, result = pcall(function()
		return game:HttpGet(url, true)
	end)
	if not success then
		return nil, "Download failed: " .. tostring(result)
	end
	if type(result) ~= "string" or #result < 20 then
		return nil, "The server returned an empty or invalid script."
	end
	return result, nil
end

local function compileSource(source, label)
	if type(loadstring) ~= "function" then
		return nil, "This executor does not provide loadstring."
	end
	local chunk, compileError = loadstring(source, "=" .. tostring(label))
	if type(chunk) ~= "function" then
		return nil, "Compile failed: " .. tostring(compileError or "unknown compiler error")
	end
	return chunk, nil
end

local function loadRayfield()
	local lastError = "Rayfield could not be downloaded."
	for _, url in ipairs(RAYFIELD_URLS) do
		local source, downloadError = fetchSource(url)
		if source then
			local chunk, compileError = compileSource(source, "Rayfield")
			if chunk then
				local success, result = xpcall(chunk, formatError)
				if success and type(result) == "table" then
					return result, nil
				end
				lastError = success and "Rayfield returned an invalid library." or tostring(result)
			else
				lastError = compileError
			end
		else
			lastError = downloadError
		end
	end
	return nil, lastError
end

local function trackConnection(connection)
	if connection then
		table.insert(connections, connection)
	end
	return connection
end

local function getRootPart()
	local character = player.Character
	if not character then
		return nil
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

local function moveTo(part)
	if state.Stopped or not part or not part:IsA("BasePart") or not part.Parent then
		return false
	end
	local rootPart = getRootPart()
	if not rootPart then
		return false
	end
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.CFrame = part.CFrame + TELEPORT_OFFSET
	return true
end

local function getTeamFolderName()
	local candidates = {state.TeamName}
	if player.Team then
		table.insert(candidates, player.Team.Name)
	end

	local textChannels = TextChatService:FindFirstChild("TextChannels")
	if textChannels then
		for _, channel in ipairs(textChannels:GetChildren()) do
			if channel:IsA("TextChannel") and channel.Name:sub(1, 7) == "RBXTeam" then
				table.insert(candidates, channel.Name:sub(8))
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		local normalized = tostring(candidate):lower()
		for color, folderName in pairs(TEAM_FOLDER_NAMES) do
			if normalized:find(color, 1, true) then
				return folderName
			end
		end
	end
	return nil
end

local function describeTycoon()
	local tycoon = state.ActiveTycoon
	if tycoon and tycoon.Parent then
		return tycoon.Name
	end
	return "none"
end

local function selectTycoon(slot)
	if state.Stopped then
		return false
	end
	state.SelectedSlot = slot
	local teamFolderName = getTeamFolderName()
	local tycoons = workspace:FindFirstChild("Tycoons")
	local tycoon = teamFolderName and tycoons and tycoons:FindFirstChild(teamFolderName .. tostring(slot))
	if tycoon then
		state.ActiveTycoon = tycoon
		local side = slot == 1 and "left" or "right"
		updateStatus(string.format("Selected %s (%s).", tycoon.Name, side))
		notify("Tycoon selected", tycoon.Name .. " is now the active base.", "castle")
		return true
	end

	state.ActiveTycoon = nil
	updateStatus("Could not find the selected color tycoon. Wait for your team to load and try again.")
	notify("Tycoon not found", "Your team color could not be matched to Tycoon " .. tostring(slot) .. ".", "triangle-alert")
	return false
end

local function hasPaidMarker(text)
	text = tostring(text):lower()
	return text:sub(1, 2) == "dp"
		or text:find("robux", 1, true) ~= nil
		or text:find("gamepass", 1, true) ~= nil
		or text:find("developerproduct", 1, true) ~= nil
		or text:find("premium", 1, true) ~= nil
		or text:find("productpurchase", 1, true) ~= nil
end

local function isPaidPad(pad)
	local cached = paidPadCache[pad]
	if cached ~= nil then
		return cached
	end

	local paid = pad:GetAttribute("IsRobuxPurchase") == true or hasPaidMarker(pad.Name)
	if not paid then
		for _, descendant in ipairs(pad:GetDescendants()) do
			if hasPaidMarker(descendant.Name) then
				paid = true
				break
			end
			if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
				local text = descendant.Text
				if hasPaidMarker(text) or tostring(text):find("R$", 1, true) then
					paid = true
					break
				end
			end
		end
	end

	paidPadCache[pad] = paid
	return paid
end

local function getFreePadHitboxes(tycoon)
	local hitboxes = {}
	local pads = tycoon and tycoon:FindFirstChild("Pads")
	if not pads then
		return hitboxes
	end

	for _, pad in ipairs(pads:GetChildren()) do
		if not isPaidPad(pad) then
			local hitbox = pad:FindFirstChild("Hitbox", true)
			if hitbox and hitbox:IsA("BasePart") then
				table.insert(hitboxes, hitbox)
			end
		end
	end
	return hitboxes
end

local function getCollectButton(tycoon)
	local sharedAuto = tycoon and tycoon:FindFirstChild("SharedAuto")
	local claimed = sharedAuto and sharedAuto:FindFirstChild("Claimed")
	local platform = claimed and claimed:FindFirstChild("Platform")
	local button = platform and platform:FindFirstChild("Button")
	if button and button:IsA("BasePart") then
		return button
	end
	return nil
end

local function refreshFlagHitboxes()
	local hitboxes = {}
	local tycoonFlags = workspace:FindFirstChild("TycoonFlags")
	if tycoonFlags then
		for _, flagName in ipairs(FLAG_NAMES) do
			local flag = tycoonFlags:FindFirstChild(flagName)
			if flag then
				if state.VisitFlagHitboxes then
					local flagHitbox = flag:FindFirstChild("FlagHitbox")
					if flagHitbox and flagHitbox:IsA("BasePart") then
						table.insert(hitboxes, flagHitbox)
					end
				end
				if state.VisitClaimHitboxes then
					local claimHitbox = flag:FindFirstChild("ClaimHitbox")
					if claimHitbox and claimHitbox:IsA("BasePart") then
						table.insert(hitboxes, claimHitbox)
					end
				end
			end
		end
	end
	state.FlagCache = hitboxes
	state.FlagCacheTime = os.clock()
	return hitboxes
end

local function getFlagHitboxes()
	local firstHitbox = state.FlagCache[1]
	local expired = os.clock() - state.FlagCacheTime >= 2.5
	local invalid = firstHitbox and not firstHitbox.Parent
	if expired or invalid or #state.FlagCache == 0 then
		return refreshFlagHitboxes()
	end
	return state.FlagCache
end

local function removeESPLine(entry)
	if entry.Beam and entry.Beam.Parent then
		entry.Beam:Destroy()
	end
	if entry.OriginAttachment and entry.OriginAttachment.Parent then
		entry.OriginAttachment:Destroy()
	end
	if entry.TargetAttachment and entry.TargetAttachment.Parent then
		entry.TargetAttachment:Destroy()
	end
	entry.Beam = nil
	entry.OriginAttachment = nil
	entry.TargetAttachment = nil
end

local function removePlayerESP(targetPlayer)
	local entry = espEntries[targetPlayer]
	if not entry then
		return
	end
	removeESPLine(entry)
	if entry.Highlight and entry.Highlight.Parent then
		entry.Highlight:Destroy()
	end
	if entry.Label and entry.Label.Parent then
		entry.Label:Destroy()
	end
	espEntries[targetPlayer] = nil
end

local function clearPlayerESP()
	local targets = {}
	for targetPlayer in pairs(espEntries) do
		table.insert(targets, targetPlayer)
	end
	for _, targetPlayer in ipairs(targets) do
		removePlayerESP(targetPlayer)
	end
end

local function updateESPLine(entry, character)
	if not state.ESPLinesEnabled then
		removeESPLine(entry)
		return
	end
	local localCharacter = player.Character
	local originRoot = localCharacter and (localCharacter:FindFirstChild("HumanoidRootPart") or localCharacter:FindFirstChild("Head"))
	local targetRoot = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Head")
	if not originRoot or not targetRoot then
		removeESPLine(entry)
		return
	end
	if entry.OriginAttachment and entry.OriginAttachment.Parent ~= originRoot then
		removeESPLine(entry)
	elseif entry.TargetAttachment and entry.TargetAttachment.Parent ~= targetRoot then
		removeESPLine(entry)
	end

	if not entry.Beam then
		local originAttachment = Instance.new("Attachment")
		originAttachment.Name = "BeanoPlayerLineOrigin"
		originAttachment.Parent = originRoot
		local targetAttachment = Instance.new("Attachment")
		targetAttachment.Name = "BeanoPlayerLineTarget"
		targetAttachment.Parent = targetRoot
		local beam = Instance.new("Beam")
		beam.Name = "BeanoPlayerLine"
		beam.Attachment0 = originAttachment
		beam.Attachment1 = targetAttachment
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Transparency = NumberSequence.new(0)
		beam.Parent = originRoot
		entry.OriginAttachment = originAttachment
		entry.TargetAttachment = targetAttachment
		entry.Beam = beam
	end
	entry.Beam.Color = ColorSequence.new(state.ESPColor)
	entry.Beam.Width0 = state.ESPLineWidth
	entry.Beam.Width1 = state.ESPLineWidth
end

local function refreshPlayerESP()
	if state.Stopped or not state.ESPEnabled then
		clearPlayerESP()
		return
	end

	local currentPlayers = {}
	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then
			currentPlayers[targetPlayer] = true
			local character = targetPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if character and humanoid and humanoid.Health > 0 then
				local entry = espEntries[targetPlayer]
				if entry and entry.Character ~= character then
					removePlayerESP(targetPlayer)
					entry = nil
				end
				if not entry then
					local highlight = Instance.new("Highlight")
					highlight.Name = "BeanoPlayerHighlight"
					highlight.Adornee = character
					highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					highlight.Parent = character

					local label = Instance.new("BillboardGui")
					label.Name = "BeanoPlayerName"
					label.Size = UDim2.fromOffset(220, 30)
					label.StudsOffset = Vector3.new(0, 3, 0)
					label.AlwaysOnTop = true
					label.Parent = character

					local labelText = Instance.new("TextLabel")
					labelText.BackgroundTransparency = 1
					labelText.Size = UDim2.fromScale(1, 1)
					labelText.Font = Enum.Font.GothamBold
					labelText.TextStrokeColor3 = Color3.new(0, 0, 0)
					labelText.TextStrokeTransparency = 0.25
					labelText.Parent = label

					entry = {
						Character = character,
						Highlight = highlight,
						Label = label,
						LabelText = labelText,
					}
					espEntries[targetPlayer] = entry
				end

				entry.Highlight.Enabled = state.ESPChamsEnabled
				entry.Highlight.FillColor = state.ESPColor
				entry.Highlight.OutlineColor = Color3.new(1, 1, 1)
				entry.Highlight.FillTransparency = state.ESPFillTransparency
				entry.Highlight.OutlineTransparency = state.ESPOutlineTransparency
				entry.Label.Enabled = state.ESPNamesEnabled
				entry.Label.Adornee = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
				entry.LabelText.Text = targetPlayer.DisplayName .. " (@" .. targetPlayer.Name .. ")"
				entry.LabelText.TextColor3 = state.ESPColor
				entry.LabelText.TextSize = state.ESPNameSize
				updateESPLine(entry, character)
			else
				removePlayerESP(targetPlayer)
			end
		end
	end

	local stalePlayers = {}
	for targetPlayer in pairs(espEntries) do
		if not currentPlayers[targetPlayer] then
			table.insert(stalePlayers, targetPlayer)
		end
	end
	for _, targetPlayer in ipairs(stalePlayers) do
		removePlayerESP(targetPlayer)
	end
end

local function stopSpectating()
	state.SpectatingPlayer = nil
	local camera = Workspace.CurrentCamera
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if camera and humanoid then
		camera.CameraSubject = humanoid
	end
end

local function setMasterToggleDisplay(value)
	if not masterToggle or updatingMasterToggle then
		return
	end
	updatingMasterToggle = true
	pcall(function()
		masterToggle:Set(value == true)
	end)
	updatingMasterToggle = false
end

local setRunning

local function runLoop(id)
	while state.Running and not state.Stopped and state.RunId == id do
		local tycoon = state.ActiveTycoon
		local needsTycoon = state.ButtonClaimEnabled or state.MoneyCollectEnabled
		if needsTycoon and (not tycoon or not tycoon:IsDescendantOf(workspace)) then
			state.ActiveTycoon = nil
			updateStatus("No claimed tycoon is selected. Select a slot or scan for your owned base.")
			setRunning(false)
			break
		end

		local didWork = false
		if state.MoneyCollectEnabled and tycoon then
			local collectButton = getCollectButton(tycoon)
			if collectButton then
				didWork = moveTo(collectButton) or didWork
				task.wait(state.PadDelay)
			end
		end

		if state.ButtonClaimEnabled and tycoon then
			local pads = getFreePadHitboxes(tycoon)
			updateStatus(string.format("Running %s: visiting %d free purchase pads.", tycoon.Name, #pads))
			for _, hitbox in ipairs(pads) do
				if not state.Running or state.Stopped or state.RunId ~= id then
					break
				end
				didWork = moveTo(hitbox) or didWork
				task.wait(state.PadDelay)
			end
		end

		if state.FlagCollectEnabled then
			local flags = getFlagHitboxes()
			updateStatus(string.format("Running flag collection: visiting %d hitboxes.", #flags))
			for _, hitbox in ipairs(flags) do
				if not state.Running or state.Stopped or state.RunId ~= id then
					break
				end
				didWork = moveTo(hitbox) or didWork
				task.wait(state.PadDelay)
			end
		end

		if not didWork then
			updateStatus("Automation is on, but no enabled targets are currently available.")
		end
		task.wait(state.CycleDelay)
	end
end

setRunning = function(value)
	if state.Stopped then
		return
	end
	value = value == true
	if value then
		local needsTycoon = state.ButtonClaimEnabled or state.MoneyCollectEnabled
		if needsTycoon and (not state.ActiveTycoon or not state.ActiveTycoon:IsDescendantOf(workspace)) then
			state.Running = false
			setMasterToggleDisplay(false)
			updateStatus("No claimed tycoon is selected. Claim one, select its slot, or use owned-base scan.")
			notify("Select a tycoon first", "A base is required while money or purchase-pad automation is enabled.", "triangle-alert")
			return
		end
	end

	if state.Running == value then
		setMasterToggleDisplay(value)
		return
	end
	state.Running = value
	state.RunId = state.RunId + 1
	setMasterToggleDisplay(value)
	if not value then
		updateStatus("Automation stopped. Use the toggle or your configured hotkey to resume.")
		return
	end

	local id = state.RunId
	updateStatus("Automation started for " .. describeTycoon() .. ".")
	task.spawn(runLoop, id)
end

local function flingTargetPlayer(targetPlayer)
	if not targetPlayer or targetPlayer == player then
		notify("No player selected", "Choose a current player from the dropdown first.", "users")
		return
	end
	if state.FlingInProgress then
		notify("Fling already running", "Wait for the current attempt to restore your position.", "users")
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local targetCharacter = targetPlayer.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not rootPart or not targetRoot then
		notify("Fling unavailable", "One of the characters is not currently loaded.", "triangle-alert")
		return
	end

	setRunning(false)
	state.FlingInProgress = true
	task.spawn(function()
		local originalCFrame = rootPart.CFrame
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
				descendant.CanCollide = descendant == rootPart
				descendant.CanTouch = descendant == rootPart
			end
		end

		local angularVelocity = Instance.new("BodyAngularVelocity")
		angularVelocity.Name = "BeanoFlingVelocity"
		angularVelocity.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
		angularVelocity.P = 1000000
		angularVelocity.AngularVelocity = Vector3.new(0, 9999, 0)
		angularVelocity.Parent = rootPart

		local stabilizer = Instance.new("BodyPosition")
		stabilizer.Name = "BeanoFlingStabilizer"
		stabilizer.MaxForce = Vector3.new(1000000000, 1000000000, 1000000000)
		stabilizer.P = 100000
		stabilizer.D = 2500
		stabilizer.Position = targetRoot.Position
		stabilizer.Parent = rootPart

		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		local succeeded = false
		local deadline = os.clock() + 5
		local step = 0

		pcall(function()
			while os.clock() < deadline do
				if state.Stopped or not state.FlingInProgress or not rootPart.Parent or not targetRoot.Parent then
					break
				end
				local targetSpeed = targetRoot.AssemblyLinearVelocity.Magnitude
				local targetDistance = (targetRoot.Position - targetStartPosition).Magnitude
				if targetSpeed >= 120 or targetDistance >= 75 then
					succeeded = true
					break
				end

				step = step + 1
				local phase = step % 4
				local offset = phase == 0 and CFrame.new(0, 0.25, 0)
					or phase == 1 and CFrame.new(0.8, 0, 0)
					or phase == 2 and CFrame.new(-0.8, 0, 0)
					or CFrame.new(0, -0.25, 0.8)
				local contactCFrame = targetRoot.CFrame * offset
				stabilizer.Position = contactCFrame.Position
				rootPart.CFrame = contactCFrame
				rootPart.AssemblyLinearVelocity = Vector3.zero
				RunService.Heartbeat:Wait()
			end
		end)

		if stabilizer.Parent then
			stabilizer:Destroy()
		end
		if angularVelocity.Parent then
			angularVelocity:Destroy()
		end
		for part, collisionState in pairs(collisionStates) do
			if part.Parent then
				part.CanCollide = collisionState.CanCollide
				part.CanTouch = collisionState.CanTouch
			end
		end
		if humanoid.Parent then
			humanoid.AutoRotate = originalAutoRotate
			humanoid.PlatformStand = originalPlatformStand
		end
		if rootPart.Parent then
			rootPart.AssemblyLinearVelocity = Vector3.zero
			rootPart.AssemblyAngularVelocity = Vector3.zero
			rootPart.CFrame = originalCFrame
			task.wait()
			if rootPart.Parent then
				rootPart.CFrame = originalCFrame
			end
		end

		state.FlingInProgress = false
		if not state.Stopped then
			notify(
				succeeded and "Fling completed" or "Fling stopped",
				succeeded and "The target was launched and your original position was restored."
					or "The five-second attempt ended and your original position was restored.",
				"users"
			)
		end
	end)
end

local function findOwnedTycoon()
	if state.Stopped or state.ScanningForTycoon then
		return
	end
	if not state.SoundReplicator then
		notify("Scan unavailable", "The Coins sound event was not found in RemoteSignals.", "triangle-alert")
		return
	end

	setRunning(false)
	state.ScanningForTycoon = true
	state.ScanId = state.ScanId + 1
	local id = state.ScanId
	updateStatus("Scanning collection buttons. Keep at least $1 waiting for detection.")
	notify("Owned-base scan started", "Keep at least $1 uncollected while every base is checked.", "search")

	task.spawn(function()
		local tycoons = workspace:FindFirstChild("Tycoons")
		if tycoons then
			for _, tycoon in ipairs(tycoons:GetChildren()) do
				if state.Stopped or state.ScanId ~= id then
					break
				end
				local collectButton = getCollectButton(tycoon)
				if collectButton then
					local signalsBefore = state.CoinSignalCount
					moveTo(collectButton)
					task.wait(0.35)
					if state.CoinSignalCount > signalsBefore then
						state.ActiveTycoon = tycoon
						state.SelectedSlot = tonumber(tycoon.Name:match("([12])$"))
						state.ScanningForTycoon = false
						updateStatus("Owned base found: " .. tycoon.Name .. ".")
						notify("Owned base found", tycoon.Name .. " is now selected.", "badge-check")
						return
					end
				end
			end
		end

		if not state.Stopped and state.ScanId == id then
			state.ScanningForTycoon = false
			updateStatus("No payout was detected. Leave at least $1 uncollected and try again.")
			notify("Owned base not found", "No Coins payout signal was detected during the scan.", "triangle-alert")
		end
	end)
end

local function runFlagPass()
	if state.Stopped or state.OnePassRunning then
		return
	end
	local flags = refreshFlagHitboxes()
	if #flags == 0 then
		notify("No flag hitboxes found", "Check the enabled flag target types and wait for TycoonFlags to load.", "triangle-alert")
		return
	end

	state.OnePassRunning = true
	local id = state.RunId
	task.spawn(function()
		for _, hitbox in ipairs(flags) do
			if state.Stopped or (state.Running and state.RunId ~= id) then
				break
			end
			moveTo(hitbox)
			task.wait(state.PadDelay)
		end
		state.OnePassRunning = false
		if not state.Stopped then
			updateStatus("Completed one flag and claim-point pass.")
		end
	end)
end

local function fireRebirth(showResult)
	if state.Stopped then
		return false
	end
	local rebirthRemote = state.RebirthRemote
	if not rebirthRemote or not rebirthRemote.Parent then
		if showResult then
			notify("Rebirth unavailable", "RemoteSignals.Rebirth was not found.", "triangle-alert")
		end
		return false
	end

	local success, rebirthError = pcall(function()
		rebirthRemote:FireServer()
	end)
	if showResult then
		if success then
			notify("Rebirth requested", "The rebirth event was sent to the server.", "refresh-cw")
		else
			notify("Rebirth failed", rebirthError, "triangle-alert")
		end
	end
	return success
end

local function clearSelectedTycoon()
	setRunning(false)
	state.ActiveTycoon = nil
	state.SelectedSlot = nil
	updateStatus("Selected tycoon cleared.")
end

local function resetDefaults()
	setRunning(false)
	state.ButtonClaimEnabled = true
	state.MoneyCollectEnabled = true
	state.FlagCollectEnabled = false
	state.AutoRebirthEnabled = false
	state.RebirthInterval = 2
	state.LastRebirthAt = 0
	state.VisitFlagHitboxes = true
	state.VisitClaimHitboxes = true
	state.PadDelay = 0.05
	state.CycleDelay = 0.1
	state.FlagCache = {}
	state.FlagCacheTime = 0
	pcall(function()
		controls.ButtonClaim:Set(true)
		controls.MoneyCollect:Set(true)
		controls.FlagCollect:Set(false)
		controls.AutoRebirth:Set(false)
		controls.RebirthInterval:Set(2)
		controls.VisitFlags:Set(true)
		controls.VisitClaims:Set(true)
		controls.PadDelay:Set(0.05)
		controls.CycleDelay:Set(0.1)
	end)
	updateStatus("Default automation settings restored.")
	notify("Defaults restored", "Automation controls and saved values were reset.", "rotate-ccw")
end

local function stopScript()
	if state.Stopped then
		return
	end
	state.Running = false
	state.Stopped = true
	state.FlingInProgress = false
	state.RunId = state.RunId + 1
	state.ScanId = state.ScanId + 1
	clearPlayerESP()
	stopSpectating()
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		for _, moverName in ipairs({"BeanoFlingVelocity", "BeanoFlingStabilizer"}) do
			local mover = rootPart:FindFirstChild(moverName)
			if mover then
				mover:Destroy()
			end
		end
	end
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(connections)
	if environment.__BEANO_GUI_CLEANUP == stopScript then
		environment.__BEANO_GUI_CLEANUP = nil
	end
	pcall(function()
		if Rayfield then
			Rayfield:Destroy()
		end
	end)
	Rayfield = nil
end

local previousGameCleanup = environment.__BEANO_GUI_CLEANUP
if type(previousGameCleanup) == "function" then
	pcall(previousGameCleanup)
end
environment.__BEANO_GUI_CLEANUP = stopScript

local remoteSignals = ReplicatedStorage:FindFirstChild("RemoteSignals") or ReplicatedStorage:WaitForChild("RemoteSignals", 10)
if remoteSignals then
	local tycoonClaimer = remoteSignals:FindFirstChild("TycoonClaimer") or remoteSignals:WaitForChild("TycoonClaimer", 5)
	local teamNeutrality = remoteSignals:FindFirstChild("TeamNeutrality") or remoteSignals:WaitForChild("TeamNeutrality", 5)
	local soundReplicator = remoteSignals:FindFirstChild("SoundReplicator") or remoteSignals:WaitForChild("SoundReplicator", 5)
	local rebirthRemote = remoteSignals:FindFirstChild("Rebirth") or remoteSignals:WaitForChild("Rebirth", 5)
	if tycoonClaimer and tycoonClaimer:IsA("RemoteEvent") then
		state.TycoonClaimer = tycoonClaimer
	end
	if teamNeutrality and teamNeutrality:IsA("RemoteEvent") then
		state.TeamNeutrality = teamNeutrality
	end
	if soundReplicator and soundReplicator:IsA("RemoteEvent") then
		state.SoundReplicator = soundReplicator
	end
	if rebirthRemote and rebirthRemote:IsA("RemoteEvent") then
		state.RebirthRemote = rebirthRemote
	end
end

local rayfieldError
Rayfield, rayfieldError = loadRayfield()
if not Rayfield then
	warn("Beano Wizard Tycoon: " .. tostring(rayfieldError))
	systemNotification("Wizard Tycoon failed to load", rayfieldError, 12)
	stopScript()
	return
end

if state.TycoonClaimer then
	trackConnection(state.TycoonClaimer.OnClientEvent:Connect(function(tycoon)
		if not state.SelectedSlot and tycoon and tycoon:IsDescendantOf(workspace) then
			state.ActiveTycoon = tycoon
			state.SelectedSlot = tonumber(tycoon.Name:match("([12])$"))
			updateStatus("Detected claimed tycoon: " .. tycoon.Name .. " (" .. state.TeamName .. ").")
		end
	end))
end

if state.TeamNeutrality then
	trackConnection(state.TeamNeutrality.OnClientEvent:Connect(function(_, incomingTeamName)
		if typeof(incomingTeamName) == "string" then
			state.TeamName = incomingTeamName
		end
	end))
end

if state.SoundReplicator then
	trackConnection(state.SoundReplicator.OnClientEvent:Connect(function(soundName)
		if soundName == "Coins" then
			state.CoinSignalCount = state.CoinSignalCount + 1
		end
	end))
end

local uiSuccess, uiError = xpcall(function()
	local Window = Rayfield:CreateWindow({
		Name = "Beano | 2 Player Wizard Tycoon",
		Icon = "wand-sparkles",
		LoadingTitle = "Beano Wizard Tycoon",
		LoadingSubtitle = "Tycoon automation",
		ShowText = "Beano",
		Theme = "Amethyst",
		ToggleUIKeybind = Enum.KeyCode.LeftControl,
		DisableRayfieldPrompts = true,
		DisableBuildWarnings = true,
		ConfigurationSaving = {
			Enabled = true,
			FolderName = "BeanoGUI",
			FileName = "WizardTycoon",
		},
		Discord = {
			Enabled = false,
			Invite = "",
			RememberJoins = false,
		},
		KeySystem = false,
	})

	local AutomationTab = Window:CreateTab("Automation", "sparkles")
	AutomationTab:CreateSection("Master control")
	statusLabel = AutomationTab:CreateLabel(state.LastStatus, "info")
	masterToggle = AutomationTab:CreateToggle({
		Name = "Run tycoon automation",
		CurrentValue = false,
		Flag = "beano_wizard_master",
		Callback = function(value)
			if not updatingMasterToggle then
				setRunning(value)
			end
		end,
	})
	AutomationTab:CreateKeybind({
		Name = "Automation toggle key",
		CurrentKeybind = "F1",
		HoldToInteract = false,
		Flag = "beano_wizard_master_key",
		Callback = function()
			setRunning(not state.Running)
		end,
	})
	AutomationTab:CreateSection("Automation modules")
	controls.ButtonClaim = AutomationTab:CreateToggle({
		Name = "Buy free tycoon pads",
		CurrentValue = state.ButtonClaimEnabled,
		Flag = "beano_wizard_buy_pads",
		Callback = function(value)
			state.ButtonClaimEnabled = value == true
		end,
	})
	controls.MoneyCollect = AutomationTab:CreateToggle({
		Name = "Collect tycoon money",
		CurrentValue = state.MoneyCollectEnabled,
		Flag = "beano_wizard_collect_money",
		Callback = function(value)
			state.MoneyCollectEnabled = value == true
		end,
	})
	controls.FlagCollect = AutomationTab:CreateToggle({
		Name = "Collect every base flag",
		CurrentValue = state.FlagCollectEnabled,
		Flag = "beano_wizard_collect_flags",
		Callback = function(value)
			state.FlagCollectEnabled = value == true
		end,
	})
	AutomationTab:CreateSection("Rebirth")
	controls.AutoRebirth = AutomationTab:CreateToggle({
		Name = "Auto rebirth",
		CurrentValue = state.AutoRebirthEnabled,
		Flag = "beano_wizard_auto_rebirth",
		Callback = function(value)
			state.AutoRebirthEnabled = value == true
			state.LastRebirthAt = 0
			if state.AutoRebirthEnabled and not state.RebirthRemote then
				notify("Auto rebirth unavailable", "RemoteSignals.Rebirth was not found.", "triangle-alert")
			end
		end,
	})
	controls.RebirthInterval = AutomationTab:CreateSlider({
		Name = "Rebirth interval",
		Range = {0.5, 30},
		Increment = 0.5,
		Suffix = " seconds",
		CurrentValue = state.RebirthInterval,
		Flag = "beano_wizard_rebirth_interval",
		Callback = function(value)
			state.RebirthInterval = math.max(tonumber(value) or 2, 0.5)
		end,
	})
	AutomationTab:CreateButton({
		Name = "Rebirth once now",
		Callback = function()
			fireRebirth(true)
		end,
	})
	AutomationTab:CreateSection("Timing")
	controls.PadDelay = AutomationTab:CreateSlider({
		Name = "Time between targets",
		Range = {0.05, 0.5},
		Increment = 0.05,
		Suffix = " seconds",
		CurrentValue = state.PadDelay,
		Flag = "beano_wizard_pad_delay",
		Callback = function(value)
			state.PadDelay = math.max(tonumber(value) or 0.05, 0.05)
		end,
	})
	controls.CycleDelay = AutomationTab:CreateSlider({
		Name = "Time between cycles",
		Range = {0.1, 2},
		Increment = 0.1,
		Suffix = " seconds",
		CurrentValue = state.CycleDelay,
		Flag = "beano_wizard_cycle_delay",
		Callback = function(value)
			state.CycleDelay = math.max(tonumber(value) or 0.1, 0.1)
		end,
	})

	local TycoonTab = Window:CreateTab("Tycoon", "castle")
	TycoonTab:CreateSection("Base selection")
	TycoonTab:CreateLabel("Select the left or right tycoon after your team color loads.", "mouse-pointer-click")
	TycoonTab:CreateButton({
		Name = "Select Tycoon 1 (left)",
		Callback = function()
			selectTycoon(1)
		end,
	})
	TycoonTab:CreateButton({
		Name = "Select Tycoon 2 (right)",
		Callback = function()
			selectTycoon(2)
		end,
	})
	TycoonTab:CreateSection("Automatic detection")
	TycoonTab:CreateLabel("Leave at least $1 ready to collect before scanning.", "circle-dollar-sign")
	TycoonTab:CreateButton({
		Name = "Find my owned base",
		Callback = findOwnedTycoon,
	})
	TycoonTab:CreateButton({
		Name = "Clear selected base",
		Callback = clearSelectedTycoon,
	})

	local FlagsTab = Window:CreateTab("Flags", "flag")
	FlagsTab:CreateSection("Flag targets")
	controls.VisitFlags = FlagsTab:CreateToggle({
		Name = "Visit flag hitboxes",
		CurrentValue = state.VisitFlagHitboxes,
		Flag = "beano_wizard_visit_flag_hitboxes",
		Callback = function(value)
			state.VisitFlagHitboxes = value == true
			refreshFlagHitboxes()
		end,
	})
	controls.VisitClaims = FlagsTab:CreateToggle({
		Name = "Visit matching claim hitboxes",
		CurrentValue = state.VisitClaimHitboxes,
		Flag = "beano_wizard_visit_claim_hitboxes",
		Callback = function(value)
			state.VisitClaimHitboxes = value == true
			refreshFlagHitboxes()
		end,
	})
	FlagsTab:CreateButton({
		Name = "Run one flag pass now",
		Callback = runFlagPass,
	})
	FlagsTab:CreateButton({
		Name = "Refresh flag locations",
		Callback = function()
			local hitboxes = refreshFlagHitboxes()
			notify("Flag locations refreshed", tostring(#hitboxes) .. " enabled hitboxes were found.", "refresh-cw")
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
			state.SelectedPlayer = playerOptionMap[option]
		end,
	})
	state.SelectedPlayer = playerOptionMap[initialPlayerOptions[1]]

	local function validSelectedPlayer()
		local selectedPlayer = state.SelectedPlayer
		if selectedPlayer and selectedPlayer.Parent == Players and selectedPlayer ~= player then
			return selectedPlayer
		end
		notify("No player selected", "Choose a current player from the dropdown first.", "users")
		return nil
	end

	PlayersTab:CreateButton({
		Name = "Teleport to selected player",
		Callback = function()
			local targetPlayer = validSelectedPlayer()
			local localRoot = getRootPart()
			local targetRoot = targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not localRoot or not targetRoot then
				notify("Teleport unavailable", "One of the characters is not currently loaded.", "triangle-alert")
				return
			end
			setRunning(false)
			localRoot.AssemblyLinearVelocity = Vector3.zero
			localRoot.AssemblyAngularVelocity = Vector3.zero
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
				notify("Spectate unavailable", "The selected character is not currently loaded.", "triangle-alert")
				return
			end
			state.SpectatingPlayer = targetPlayer
			camera.CameraSubject = targetHumanoid
		end,
	})
	PlayersTab:CreateButton({
		Name = "Stop spectating",
		Callback = stopSpectating,
	})
	PlayersTab:CreateSection("Player action")
	PlayersTab:CreateLabel("Fling attempts for up to five seconds, then restores your saved position.", "rotate-3d")
	PlayersTab:CreateButton({
		Name = "Fling selected player",
		Callback = function()
			flingTargetPlayer(validSelectedPlayer())
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
		local selectedPlayer = state.SelectedPlayer
		if not selectedPlayer or selectedPlayer.Parent ~= Players then
			selectedPlayerDropdown:Set({options[1]})
		else
			local selectedOption = selectedPlayer.DisplayName .. " (@" .. selectedPlayer.Name .. ")"
			selectedPlayerDropdown:Set({selectedOption})
		end
	end
	task.spawn(function()
		while not state.Stopped do
			task.wait(5)
			if not state.Stopped then
				pcall(refreshPlayerDropdown)
			end
		end
	end)

	local ESPTab = Window:CreateTab("ESP", "scan-eye")
	ESPTab:CreateSection("Player ESP")
	controls.ESPMaster = ESPTab:CreateToggle({
		Name = "Player ESP",
		CurrentValue = state.ESPEnabled,
		Flag = "beano_wizard_player_esp",
		Callback = function(value)
			state.ESPEnabled = value == true
			refreshPlayerESP()
		end,
	})
	controls.ESPChams = ESPTab:CreateToggle({
		Name = "Character chams",
		CurrentValue = state.ESPChamsEnabled,
		Flag = "beano_wizard_player_chams",
		Callback = function(value)
			state.ESPChamsEnabled = value == true
			refreshPlayerESP()
		end,
	})
	controls.ESPNames = ESPTab:CreateToggle({
		Name = "Player names",
		CurrentValue = state.ESPNamesEnabled,
		Flag = "beano_wizard_player_names",
		Callback = function(value)
			state.ESPNamesEnabled = value == true
			refreshPlayerESP()
		end,
	})
	controls.ESPLines = ESPTab:CreateToggle({
		Name = "Player tracer lines",
		CurrentValue = state.ESPLinesEnabled,
		Flag = "beano_wizard_player_lines",
		Callback = function(value)
			state.ESPLinesEnabled = value == true
			refreshPlayerESP()
		end,
	})
	ESPTab:CreateSection("ESP appearance")
	controls.ESPColor = ESPTab:CreateColorPicker({
		Name = "ESP color",
		Color = state.ESPColor,
		Flag = "beano_wizard_esp_color",
		Callback = function(value)
			if typeof(value) == "Color3" then
				state.ESPColor = value
				refreshPlayerESP()
			end
		end,
	})
	controls.ESPOpacity = ESPTab:CreateSlider({
		Name = "Cham opacity",
		Range = {0, 100},
		Increment = 5,
		Suffix = "%",
		CurrentValue = math.floor((1 - state.ESPFillTransparency) * 100 + 0.5),
		Flag = "beano_wizard_esp_opacity",
		Callback = function(value)
			state.ESPFillTransparency = 1 - ((tonumber(value) or 45) / 100)
			refreshPlayerESP()
		end,
	})
	controls.ESPOutlineOpacity = ESPTab:CreateSlider({
		Name = "White outline opacity",
		Range = {0, 100},
		Increment = 5,
		Suffix = "%",
		CurrentValue = math.floor((1 - state.ESPOutlineTransparency) * 100 + 0.5),
		Flag = "beano_wizard_esp_outline_opacity",
		Callback = function(value)
			state.ESPOutlineTransparency = 1 - ((tonumber(value) or 100) / 100)
			refreshPlayerESP()
		end,
	})
	controls.ESPLineWidth = ESPTab:CreateSlider({
		Name = "Tracer line width",
		Range = {0.03, 0.3},
		Increment = 0.01,
		Suffix = " studs",
		CurrentValue = state.ESPLineWidth,
		Flag = "beano_wizard_esp_line_width",
		Callback = function(value)
			state.ESPLineWidth = tonumber(value) or 0.1
			refreshPlayerESP()
		end,
	})
	controls.ESPNameSize = ESPTab:CreateSlider({
		Name = "Player name size",
		Range = {10, 24},
		Increment = 1,
		Suffix = " px",
		CurrentValue = state.ESPNameSize,
		Flag = "beano_wizard_esp_name_size",
		Callback = function(value)
			state.ESPNameSize = tonumber(value) or 14
			refreshPlayerESP()
		end,
	})
	ESPTab:CreateSection("Performance")
	controls.ESPRefresh = ESPTab:CreateSlider({
		Name = "ESP refresh interval",
		Range = {0.1, 2},
		Increment = 0.1,
		Suffix = " seconds",
		CurrentValue = state.ESPRefreshInterval,
		Flag = "beano_wizard_esp_refresh",
		Callback = function(value)
			state.ESPRefreshInterval = math.max(tonumber(value) or 0.5, 0.1)
		end,
	})
	task.spawn(function()
		while not state.Stopped do
			task.wait(state.ESPRefreshInterval)
			if not state.Stopped then
				pcall(refreshPlayerESP)
			end
		end
	end)
	task.spawn(function()
		while not state.Stopped do
			task.wait(0.25)
			if state.AutoRebirthEnabled and state.RebirthRemote then
				local now = os.clock()
				if state.LastRebirthAt == 0 or now - state.LastRebirthAt >= state.RebirthInterval then
					state.LastRebirthAt = now
					fireRebirth(false)
				end
			end
		end
	end)

	local SettingsTab = Window:CreateTab("Settings", "settings")
	SettingsTab:CreateSection("Interface")
	SettingsTab:CreateLabel("Left Control opens or closes Rayfield. Change the F1 hotkey on the Automation tab.", "keyboard")
	SettingsTab:CreateSection("Maintenance")
	SettingsTab:CreateButton({
		Name = "Reset automation values",
		Callback = resetDefaults,
	})
	SettingsTab:CreateButton({
		Name = "Stop and unload Wizard Tycoon",
		Callback = stopScript,
	})
	SettingsTab:CreateLabel("Stopping disconnects every remote event and cancels active automation and scans.", "circle-stop")

	task.defer(function()
		pcall(function()
			Rayfield:LoadConfiguration()
		end)
	end)
end, formatError)

if not uiSuccess then
	warn("Beano Wizard Tycoon UI error: " .. tostring(uiError))
	systemNotification("Wizard Tycoon UI error", uiError, 12)
	stopScript()
	return
end

if not remoteSignals then
	notify("Limited game detection", "RemoteSignals was not found. Manual base selection and Workspace automation remain available.", "triangle-alert")
elseif not state.SoundReplicator then
	notify("Owned-base scan unavailable", "SoundReplicator was not found, so use the left or right base buttons.", "triangle-alert")
end
if remoteSignals and not state.RebirthRemote then
	notify("Auto rebirth unavailable", "RemoteSignals.Rebirth was not found in this server.", "triangle-alert")
end
