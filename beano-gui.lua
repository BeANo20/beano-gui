if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local player = Players.LocalPlayer
local environment = (getgenv and getgenv()) or _G
local rayfieldLibrary = nil
local stopped = false
local gameLaunching = false

local RAYFIELD_URLS = {
	"https://sirius.menu/rayfield",
	"https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
}
local MM2_URL = "https://raw.githubusercontent.com/BeANo20/beano-gui/main/mm2.lua"

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
			Duration = duration or 8,
		})
	end)
end

local function hubNotification(title, message, image)
	if rayfieldLibrary then
		local success = pcall(function()
			rayfieldLibrary:Notify({
				Title = tostring(title),
				Content = tostring(message):sub(1, 300),
				Duration = 7,
				Image = image or "info",
			})
		end)
		if success then
			return
		end
	end
	systemNotification(title, message, 8)
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

local function stopHub()
	if stopped then
		return
	end
	stopped = true
	pcall(function()
		if rayfieldLibrary then
			rayfieldLibrary:Destroy()
		end
	end)
	if environment.__BEANO_HUB_CLEANUP == stopHub then
		environment.__BEANO_HUB_CLEANUP = nil
	end
	rayfieldLibrary = nil
end

local previousHubCleanup = environment.__BEANO_HUB_CLEANUP
if type(previousHubCleanup) == "function" then
	pcall(previousHubCleanup)
end
local previousGameCleanup = environment.__BEANO_GUI_CLEANUP
if type(previousGameCleanup) == "function" then
	pcall(previousGameCleanup)
end
environment.__BEANO_HUB_CLEANUP = stopHub

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

local rayfieldError
rayfieldLibrary, rayfieldError = loadRayfield()
if not rayfieldLibrary then
	warn("Beano Hub: " .. tostring(rayfieldError))
	systemNotification("Beano Hub failed to load", rayfieldError, 12)
	stopHub()
	return
end

local uiSuccess, uiError = xpcall(function()
	local Window = rayfieldLibrary:CreateWindow({
		Name = "Beano Hub",
		Icon = "sparkles",
		LoadingTitle = "Beano Hub",
		LoadingSubtitle = "Universal script hub",
		ShowText = "Beano",
		Theme = "Amethyst",
		ToggleUIKeybind = "F8",
		DisableRayfieldPrompts = true,
		DisableBuildWarnings = true,
		ConfigurationSaving = {
			Enabled = false,
		},
		Discord = {
			Enabled = false,
			Invite = "",
			RememberJoins = false,
		},
		KeySystem = false,
	})

	local GamesTab = Window:CreateTab("Games", "gamepad-2")
	GamesTab:CreateSection("Game selection")
	GamesTab:CreateLabel("Select a game to load its dedicated tools.", "layout-grid")
	GamesTab:CreateButton({
		Name = "MM2",
		Callback = function()
			if stopped or gameLaunching then
				return
			end
			gameLaunching = true
			hubNotification("Loading MM2", "Downloading and checking the MM2 module...", "loader-circle")
			task.defer(function()
				local source, downloadError = fetchSource(MM2_URL .. "?v=" .. tostring(os.time()))
				if not source then
					gameLaunching = false
					hubNotification("MM2 download failed", downloadError, "triangle-alert")
					return
				end
				local chunk, compileError = compileSource(source, "Beano MM2")
				if not chunk then
					gameLaunching = false
					hubNotification("MM2 compile failed", compileError, "triangle-alert")
					warn("Beano Hub: " .. tostring(compileError))
					return
				end
				stopHub()
				task.wait(0.1)
				local success, runtimeError = xpcall(chunk, formatError)
				if not success then
					warn("Beano MM2 runtime error: " .. tostring(runtimeError))
					systemNotification("MM2 runtime error", runtimeError, 12)
				end
			end)
		end,
	})
	GamesTab:CreateLabel("More games can be added to this menu later.", "plus")

	local HubTab = Window:CreateTab("Hub", "settings")
	HubTab:CreateSection("Hub controls")
	HubTab:CreateButton({
		Name = "Close and stop hub",
		Callback = stopHub,
	})
end, formatError)

if not uiSuccess then
	warn("Beano Hub UI error: " .. tostring(uiError))
	systemNotification("Beano Hub UI error", uiError, 12)
	stopHub()
end
