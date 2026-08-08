if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local environment = (getgenv and getgenv()) or _G
local Rayfield = nil
local loopConnection = nil
local refreshNoticeShown = false

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

local state = {
	Enabled = false,
	Stopped = false,
	LoopDelay = 0.05,
	NextLocation = 1,
	Elapsed = 0,
	IncludeFlagHitbox = true,
	IncludeClaimHitbox = true,
	Locations = {},
	LastRefresh = 0,
	OnePassRunning = false,
}

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

local function refreshLocations(showNotice)
	local locations = {}
	local tycoonFlags = workspace:FindFirstChild("TycoonFlags")
	if tycoonFlags then
		for _, flagName in ipairs(FLAG_NAMES) do
			local flagFolder = tycoonFlags:FindFirstChild(flagName)
			if flagFolder then
				if state.IncludeFlagHitbox then
					local flagHitbox = flagFolder:FindFirstChild("FlagHitbox")
					if flagHitbox and flagHitbox:IsA("BasePart") then
						table.insert(locations, {
							Name = flagName .. " flag",
							Part = flagHitbox,
						})
					end
				end
				if state.IncludeClaimHitbox then
					local claimHitbox = flagFolder:FindFirstChild("ClaimHitbox")
					if claimHitbox and claimHitbox:IsA("BasePart") then
						table.insert(locations, {
							Name = flagName .. " claim",
							Part = claimHitbox,
						})
					end
				end
			end
		end
	end

	state.Locations = locations
	state.LastRefresh = os.clock()
	if state.NextLocation > #locations then
		state.NextLocation = 1
	end

	if showNotice then
		if #locations > 0 then
			notify("Locations refreshed", tostring(#locations) .. " flag locations are ready.", "refresh-cw")
		else
			notify("No flags found", "TycoonFlags or its enabled hitboxes are not available yet.", "triangle-alert")
		end
	end
	return locations
end

local function getLocations()
	local cacheExpired = os.clock() - state.LastRefresh >= 2.5
	local firstEntry = state.Locations[1]
	local cacheInvalid = firstEntry and (not firstEntry.Part or not firstEntry.Part.Parent)
	if cacheExpired or cacheInvalid or #state.Locations == 0 then
		return refreshLocations(false)
	end
	return state.Locations
end

local function teleportTo(entry)
	if state.Stopped or not entry or not entry.Part or not entry.Part.Parent then
		return false
	end
	local rootPart = getRootPart()
	if not rootPart then
		return false
	end
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	rootPart.CFrame = entry.Part.CFrame + Vector3.new(0, 2.5, 0)
	return true
end

local function disconnectLoop()
	if loopConnection then
		loopConnection:Disconnect()
		loopConnection = nil
	end
end

local function setLoopEnabled(value)
	if state.Stopped then
		return
	end
	value = value == true
	if state.Enabled == value then
		return
	end

	state.Enabled = value
	state.Elapsed = state.LoopDelay
	disconnectLoop()
	if not value then
		return
	end

	local locations = refreshLocations(false)
	if #locations == 0 and not refreshNoticeShown then
		refreshNoticeShown = true
		notify("Waiting for flags", "No matching flag hitboxes were found. The list will keep refreshing.", "triangle-alert")
	end

	loopConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if state.Stopped or not state.Enabled then
			return
		end
		state.Elapsed = state.Elapsed + deltaTime
		if state.Elapsed < state.LoopDelay then
			return
		end
		state.Elapsed = state.Elapsed % state.LoopDelay

		local currentLocations = getLocations()
		if #currentLocations == 0 then
			return
		end
		state.NextLocation = ((state.NextLocation - 1) % #currentLocations) + 1
		if teleportTo(currentLocations[state.NextLocation]) then
			state.NextLocation = (state.NextLocation % #currentLocations) + 1
		end
	end)
end

local function runOnePass()
	if state.Stopped or state.OnePassRunning then
		return
	end
	local locations = refreshLocations(false)
	if #locations == 0 then
		notify("No flags found", "There are no matching flag hitboxes to visit.", "triangle-alert")
		return
	end

	state.OnePassRunning = true
	task.spawn(function()
		for _, entry in ipairs(locations) do
			if state.Stopped then
				break
			end
			teleportTo(entry)
			task.wait(math.max(state.LoopDelay, 0.05))
		end
		state.OnePassRunning = false
	end)
end

local function stopScript()
	if state.Stopped then
		return
	end
	state.Stopped = true
	state.Enabled = false
	disconnectLoop()
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

local rayfieldError
Rayfield, rayfieldError = loadRayfield()
if not Rayfield then
	warn("Beano Wizard Tycoon: " .. tostring(rayfieldError))
	systemNotification("Wizard Tycoon failed to load", rayfieldError, 12)
	stopScript()
	return
end

local uiSuccess, uiError = xpcall(function()
	local Window = Rayfield:CreateWindow({
		Name = "Beano | Wizard Tycoon",
		Icon = "wand-sparkles",
		LoadingTitle = "Beano Wizard Tycoon",
		LoadingSubtitle = "Flag collector",
		ShowText = "Beano",
		Theme = "Amethyst",
		ToggleUIKeybind = "LeftControl",
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

	local FlagsTab = Window:CreateTab("Flags", "flag")
	FlagsTab:CreateSection("Automatic flag collection")
	local loopToggle = FlagsTab:CreateToggle({
		Name = "Collect every base flag",
		CurrentValue = false,
		Flag = "beano_wizard_auto_flags",
		Callback = function(value)
			setLoopEnabled(value)
		end,
	})
	FlagsTab:CreateKeybind({
		Name = "Flag loop toggle key",
		CurrentKeybind = "F1",
		HoldToInteract = false,
		Flag = "beano_wizard_loop_key",
		Callback = function()
			loopToggle:Set(not state.Enabled)
		end,
	})
	FlagsTab:CreateSlider({
		Name = "Time between teleports",
		Range = {0.05, 1},
		Increment = 0.05,
		Suffix = " seconds",
		CurrentValue = state.LoopDelay,
		Flag = "beano_wizard_loop_delay",
		Callback = function(value)
			state.LoopDelay = math.max(tonumber(value) or 0.05, 0.05)
			state.Elapsed = math.min(state.Elapsed, state.LoopDelay)
		end,
	})
	FlagsTab:CreateSection("Locations")
	FlagsTab:CreateToggle({
		Name = "Visit flag hitboxes",
		CurrentValue = true,
		Flag = "beano_wizard_visit_flags",
		Callback = function(value)
			state.IncludeFlagHitbox = value == true
			refreshLocations(false)
		end,
	})
	FlagsTab:CreateToggle({
		Name = "Visit claim hitboxes",
		CurrentValue = true,
		Flag = "beano_wizard_visit_claims",
		Callback = function(value)
			state.IncludeClaimHitbox = value == true
			refreshLocations(false)
		end,
	})
	FlagsTab:CreateButton({
		Name = "Run one pass now",
		Callback = runOnePass,
	})
	FlagsTab:CreateButton({
		Name = "Refresh flag locations",
		Callback = function()
			refreshLocations(true)
		end,
	})

	local SettingsTab = Window:CreateTab("Settings", "settings")
	SettingsTab:CreateSection("Interface")
	SettingsTab:CreateLabel("Left Control opens or closes Rayfield. The F1 loop key can be changed on the Flags tab.", "keyboard")
	SettingsTab:CreateSection("Script")
	SettingsTab:CreateButton({
		Name = "Stop and unload Wizard Tycoon",
		Callback = stopScript,
	})
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
end
