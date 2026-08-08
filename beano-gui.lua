-- Client-side speed controller.
-- Place this as a LocalScript in StarterPlayerScripts or StarterGui.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Stop a previously running copy before creating any new events or visuals.
-- This makes rerunning an updated version safe even if the old window is hidden.
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

-- Remove the previous UI name once so rerunning the updated script does not
-- leave an old controller behind.
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
local tradeOverlayEnabled = true
local tradeOverlayPosition = "Top"
local lastTradeYourValue = 0
local lastTradeTheirValue = 0
local lastTradeAverageDemand = 0
local selectedPlayer = nil
local spectatingPlayer = nil
local flingInProgress = false
local interfaceReady = false

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

-- Lightweight state objects used by shared callbacks. They are never parented
-- to PlayerGui, so the removed legacy interface cannot render or flash.
local gui = Instance.new("ScreenGui")
gui.Name = "BeanoInternalState"
gui.Enabled = false
local frame = Instance.new("Frame")
local input = Instance.new("TextBox")
input.Text = tostring(targetSpeed)
local applyButton = Instance.new("TextButton")
local jumpInput = Instance.new("TextBox")
jumpInput.Text = tostring(targetJumpHeight)
local jumpApplyButton = Instance.new("TextButton")
local status = Instance.new("TextLabel")
local stopButton = Instance.new("TextButton")

local function setTargetSpeed()
	local parsed = tonumber(input.Text)
	if not parsed then
		status.Text = "Enter a number from 0 to 200"
		status.TextColor3 = Color3.fromRGB(255, 170, 140)
		input.Text = tostring(targetSpeed)
		return
	end

	targetSpeed = math.clamp(parsed, minimumSpeed, maximumSpeed)
	input.Text = tostring(targetSpeed)
	status.Text = ("Target speed: %d"):format(targetSpeed)
	status.TextColor3 = Color3.fromRGB(145, 255, 170)
	applySpeed()
end

local function setTargetJumpHeight()
	local parsed = tonumber(jumpInput.Text)
	if not parsed then
		status.Text = "Enter a jump height from 0 to 100"
		status.TextColor3 = Color3.fromRGB(255, 170, 140)
		jumpInput.Text = tostring(targetJumpHeight)
		return
	end

	targetJumpHeight = math.clamp(parsed, minimumJumpHeight, maximumJumpHeight)
	jumpInput.Text = tostring(targetJumpHeight)
	status.Text = ("Target jump height: %.1f"):format(targetJumpHeight)
	status.TextColor3 = Color3.fromRGB(145, 255, 170)
	applyJumpHeight()
end

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
	if gameTradeSummary and gameTradeSummary.Parent then
		gameTradeSummary:Destroy()
	end
	gameTradeSummary = nil
	flingInProgress = false
	spectatingPlayer = nil
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
	tradeGui = nil

	pcall(function()
		if script and script.Destroy then
			script:Destroy()
		end
	end)
end

table.insert(connections, applyButton.Activated:Connect(setTargetSpeed))
table.insert(connections, input.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		setTargetSpeed()
	end
end))

table.insert(connections, jumpApplyButton.Activated:Connect(setTargetJumpHeight))
table.insert(connections, jumpInput.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		setTargetJumpHeight()
	end
end))

table.insert(connections, player.CharacterAdded:Connect(function(character)
	character:WaitForChild("Humanoid", 5)
	applySpeed()
	applyJumpHeight()
end))

-- Keep the selected value applied during testing if another local
-- script changes WalkSpeed or JumpHeight while the character is active.
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

table.insert(connections, stopButton.Activated:Connect(stopScript))

applySpeed()
applyJumpHeight()

-- Supreme Values snapshot used by the trade calculator.
-- Source: https://www.supremevalues.com/mm2/
-- Snapshot date: August 8, 2026. Unknown items are reported instead of guessed.
local supremeValuesUpdated = "Aug 8, 2026"
local supremeValues = {
	["Gingerscope"] = 17750,
	["Traveler's Axe"] = 8100,
	["Celestial"] = 2350,
	["Vampire's Axe"] = 1225,
	["Harvester"] = 250,
	["Icepiercer"] = 160,
	["Icebreaker"] = 65,
	["Batwing"] = 42,
	["Elderwood Scythe"] = 38,
	["Swirly Axe"] = 38,
	["Hallowscythe"] = 30,
	["Logchopper"] = 18,
	["Icewing"] = 13,
	["Traveler's Gun"] = 5600,
	["Evergun"] = 3450,
	["Constellation"] = 2700,
	["Evergreen"] = 2500,
	["Turkey"] = 2450,
	["Vampire's Gun"] = 1950,
	["Alienbeam"] = 1850,
	["Darkshot"] = 1725,
	["Darksword"] = 1700,
	["Raygun"] = 1600,
	["Blossom"] = 1340,
	["Sakura"] = 1330,
	["Sunrise"] = 1125,
	["Snowcannon"] = 850,
	["Bauble"] = 825,
	["Sunset"] = 625,
	["Soul"] = 615,
	["Spirit"] = 605,
	["Rainbow Gun"] = 420,
	["Flora"] = 410,
	["Rainbow"] = 410,
	["Bloom"] = 400,
	["Heart Wand"] = 340,
	["Ocean"] = 285,
	["Waves"] = 280,
	["Xenoknife"] = 280,
	["Xenoshot"] = 280,
	["Flowerwood Gun"] = 265,
	["Blizzard"] = 260,
	["Flowerwood"] = 260,
	["Snowstorm"] = 260,
	["Snow Dagger"] = 250,
	["Watergun"] = 250,
	["Icecream"] = 160,
	["Treat"] = 155,
	["Beachy"] = 150,
	["Sands"] = 150,
	["Sweet"] = 150,
	["Borealis"] = 145,
	["Australis"] = 140,
	["Bat"] = 120,
	["Pearlshine"] = 85,
	["Pearl"] = 80,
	["Candy"] = 80,
	["Heartblade"] = 65,
	["Luger"] = 40,
	["Red Luger"] = 37,
	["Phantom"] = 35,
	["Spectre"] = 35,
	["Candleflame"] = 33,
	["Darkbringer"] = 33,
	["Elderwood Blade"] = 33,
	["Elderwood Revolver"] = 33,
	["Iceblaster"] = 33,
	["Lightbringer"] = 33,
	["Makeshift"] = 33,
	["Sugar"] = 32,
	["Ornament"] = 28,
	["Green Luger"] = 23,
	["Amerilaser"] = 22,
	["Laser"] = 22,
	["Hallowgun"] = 20,
	["Chroma Traveler's Gun"] = 220000,
	["Chroma Evergun"] = 75000,
	["Chroma Evergreen"] = 48000,
	["Chroma Bauble"] = 34000,
	["Chroma Vampire's Gun"] = 29000,
	["Chroma Constellation"] = 27000,
	["Chroma Alienbeam"] = 24000,
	["Chroma Sunrise"] = 13250,
	["Chroma Raygun"] = 12750,
	["Chroma Sunset"] = 8750,
	["Chroma Blizzard"] = 8000,
	["Chroma Snowcannon"] = 8000,
	["Chroma Snowstorm"] = 4250,
	["Chroma Heart Wand"] = 4250,
	["Chroma Snow Dagger"] = 4000,
	["Chroma Watergun"] = 3400,
	["Chroma Treat"] = 2700,
	["Chroma Sweet"] = 2300,
	["Chroma Icecream"] = 2000,
	["Chroma Sands"] = 1850,
	["Chroma Beachy"] = 1800,
	["Chroma Ornament"] = 1800,
	["Chroma Darkbringer"] = 65,
	["Chroma Lightbringer"] = 60,
	["Chroma Luger"] = 50,
	["Chroma Candleflame"] = 40,
	["Chroma Laser"] = 40,
	["Chroma Swirly Gun"] = 38,
	["Chroma Elderwood Blade"] = 37,
	["Chroma Deathshard"] = 35,
	["Chroma Cookiecane"] = 32,
	["Chroma Fang"] = 32,
	["Chroma Gemstone"] = 32,
	["Chroma Shark"] = 32,
	["Chroma Slasher"] = 32,
	["Chroma Heat"] = 28,
	["Chroma Seer"] = 28,
}

-- User-provided Supreme Values weapon snapshot.
-- Source file: C:\\Users\\jacks\\Downloads\\mm2_supreme_tradable_weapons.json
-- Retrieved: 2026-08-08T01:30:08.898Z
local supremeValuesJsonSnapshot = {
    ["Gingerscope"] = 17750,
    ["Nik's Scythe"] = "Priceless",
    ["Traveler's Axe"] = 8100,
    ["Celestial"] = 2350,
    ["Vampire's Axe"] = 1225,
    ["Harvester"] = 250,
    ["Icepiercer"] = 160,
    ["Icebreaker"] = 65,
    ["Batwing"] = 42,
    ["Elderwood Scythe"] = 38,
    ["Swirly Axe"] = 38,
    ["Hallowscythe"] = 30,
    ["Logchopper"] = 18,
    ["Icewing"] = 13,
    ["C. Traveler's Gun"] = 220000,
    ["Chroma Evergun"] = 75000,
    ["Chroma Evergreen"] = 48000,
    ["Chroma Bauble"] = 34000,
    ["C. Vampire's Gun"] = 29000,
    ["C. Constellation"] = 27000,
    ["Chroma Alienbeam"] = 24000,
    ["Chroma Sunrise"] = 13250,
    ["Chroma Raygun"] = 12750,
    ["Chroma Sunset"] = 8750,
    ["Chroma Blizzard"] = 8000,
    ["Chroma Snowcannon"] = 8000,
    ["Chroma Heart Wand"] = 4250,
    ["Chroma Snowstorm"] = 4250,
    ["Chroma Snow Dagger"] = 4000,
    ["Chroma Watergun"] = 3400,
    ["Chroma Treat"] = 2700,
    ["Chroma Sweet"] = 2300,
    ["Chroma Icecream"] = 2000,
    ["Chroma Sands"] = 1850,
    ["Chroma Beachy"] = 1800,
    ["Chroma Ornament"] = 1800,
    ["Chroma Darkbringer"] = 65,
    ["Chroma Lightbringer"] = 60,
    ["Chroma Luger"] = 50,
    ["Chroma Candleflame"] = 40,
    ["Chroma Laser"] = 40,
    ["Chroma Swirly Gun"] = 38,
    ["C. Elderwood Blade"] = 37,
    ["Chroma Deathshard"] = 35,
    ["Chroma Cookiecane"] = 32,
    ["Chroma Fang"] = 32,
    ["Chroma Gemstone"] = 32,
    ["Chroma Shark"] = 32,
    ["Chroma Slasher"] = 32,
    ["Chroma Heat"] = 28,
    ["Chroma Seer"] = 28,
    ["Chroma Gingerblade"] = 27,
    ["Chroma Tides"] = 27,
    ["Chroma Saw"] = 23,
    ["Chroma Boneblade"] = 22,
    ["Bats (Knife)"] = 240,
    ["Ghoulish"] = 100,
    ["Gifts (Knife)"] = 95,
    ["Pine (Knife)"] = 85,
    ["Glitch1"] = 70,
    ["Glitch2"] = 35,
    ["Frosted (Knife)"] = 30,
    ["Mummified"] = 30,
    ["Snowflakes (Gun)"] = 30,
    ["Sparkle9"] = 30,
    ["Wrapped (Gun)"] = 30,
    ["CandyCorn (2017)"] = 25,
    ["Ecto"] = 25,
    ["Snowman (Gun)"] = 25,
    ["Webbed (Gun)"] = 25,
    ["Slimy"] = 20,
    ["Sparkle10"] = 20,
    ["Sparkle8"] = 20,
    ["Sparkle7"] = 18,
    ["RIP"] = 17,
    ["Coal (Knife)"] = 15,
    ["Elf (Knife)"] = 15,
    ["Candy Corn (2019)"] = 12,
    ["Elf (2018)"] = 12,
    ["Prism"] = 12,
    ["Pumpkin (2019)"] = 12,
    ["Sparkle6"] = 12,
    ["Combat II"] = 10,
    ["Phantom"] = 10,
    ["Sparkle4"] = 10,
    ["Zombie"] = 10,
    ["Skool"] = 8,
    ["Sparkle5"] = 8,
    ["Tailslide"] = 7,
    ["Starry"] = 5,
    ["Alex"] = 4,
    ["Corl"] = 4,
    ["Denis"] = 4,
    ["Euro"] = 4,
    ["Ollie"] = 4,
    ["Sidewinder"] = 4,
    ["Sketchy"] = 4,
    ["Sub"] = 4,
    ["Apocalypse (Gun)"] = 3,
    ["Bats (2020)"] = 3,
    ["Ghosty"] = 3,
    ["Infected (Gun)"] = 3,
    ["Sparkle1"] = 3,
    ["Sparkle2"] = 3,
    ["Sparkle3"] = 3,
    ["Asteroid"] = 2,
    ["Grind"] = 2,
    ["Indy"] = 2,
    ["Bats (Gun)"] = 1,
    ["Grave (Gun)"] = 1,
    ["Grave (Knife)"] = 1,
    ["Haunted (Gun)"] = 1,
    ["Haunted (Knife)"] = 1,
    ["Slashed"] = 1,
    ["Slime (Gun)"] = 1,
    ["Slime (Knife)"] = 1,
    ["Batwing"] = 1000000,
    ["Black Luger"] = 1000000,
    ["Traveler's Gun"] = 5600,
    ["Evergun"] = 3450,
    ["Constellation"] = 2700,
    ["Evergreen"] = 2500,
    ["Turkey"] = 2450,
    ["Vampire's Gun"] = 1950,
    ["Alienbeam"] = 1850,
    ["Darkshot"] = 1725,
    ["Darksword"] = 1700,
    ["Raygun"] = 1600,
    ["Blossom"] = 1340,
    ["Sakura"] = 1330,
    ["Sunrise"] = 1125,
    ["Snowcannon"] = 850,
    ["Bauble"] = 825,
    ["Sunset"] = 625,
    ["Soul"] = 615,
    ["Spirit"] = 605,
    ["Rainbow Gun"] = 420,
    ["Flora"] = 410,
    ["Rainbow"] = 410,
    ["Bloom"] = 400,
    ["Heart Wand"] = 340,
    ["Ocean"] = 285,
    ["Waves"] = 280,
    ["Xenoknife"] = 280,
    ["Xenoshot"] = 280,
    ["Flowerwood Gun"] = 265,
    ["Blizzard"] = 260,
    ["Flowerwood"] = 260,
    ["Snowstorm"] = 260,
    ["Snow Dagger"] = 250,
    ["Watergun"] = 250,
    ["Icecream"] = 160,
    ["Treat"] = 155,
    ["Beachy"] = 150,
    ["Sands"] = 150,
    ["Sweet"] = 150,
    ["Borealis"] = 145,
    ["Australis"] = 140,
    ["Bat"] = 120,
    ["Pearlshine"] = 85,
    ["Candy"] = 80,
    ["Pearl"] = 80,
    ["Heartblade"] = 65,
    ["Luger"] = 40,
    ["Red Luger"] = 37,
    ["Phantom"] = 35,
    ["Spectre"] = 35,
    ["Candleflame"] = 33,
    ["Darkbringer"] = 33,
    ["Elderwood Blade"] = 33,
    ["Elderwood Revolver"] = 33,
    ["Iceblaster"] = 33,
    ["Lightbringer"] = 33,
    ["Makeshift"] = 33,
    ["Sugar"] = 32,
    ["Ornament"] = 28,
    ["Green Luger"] = 23,
    ["Amerilaser"] = 22,
    ["Laser"] = 22,
    ["Hallowgun"] = 20,
    ["Nightblade"] = 20,
    ["Latte (Gun)"] = 140,
    ["Latte (Knife)"] = 140,
    ["Spectral (Knife)"] = 55,
    ["Traveler (Gun)"] = 55,
    ["Aurora (Gun)"] = 50,
    ["Vampire (Gun)"] = 50,
    ["Beach"] = 35,
    ["Cotton Candy"] = 35,
    ["JD"] = 28,
    ["Arctic (Gun)"] = 10,
    ["Broken"] = 7,
    ["Cavern (Knife)"] = 7,
    ["Ghost (Knife)"] = 5,
    ["Ginger (Gun)"] = 5,
    ["Icedriller"] = 5,
    ["Nightsky"] = 5,
    ["Bunnies"] = 4,
    ["Red Scratch"] = 4,
    ["Skulls"] = 4,
    ["Aurora (Knife)"] = 3,
    ["Blue Elite"] = 3,
    ["Green Elite"] = 3,
    ["Santa's Magic"] = 3,
    ["Santa's Spirit"] = 3,
    ["Spectral (Gun)"] = 3,
    ["Traveler (Knife)"] = 3,
    ["Vampire (Knife)"] = 3,
    ["Witched"] = 3,
    ["Blue Scratch"] = 2,
    ["Energized (Gun)"] = 2,
    ["Frostfade (Knife)"] = 2,
    ["Ghost (Gun)"] = 2,
    ["Cavern (Gun)"] = 1,
    ["Chromatic (Knife)"] = 1,
    ["Icecracker"] = 1,
    ["Red Fire"] = 1,
    ["Cane (Knife)"] = 625,
    ["Dungeon"] = 225,
    ["Darkknife"] = 70,
    ["Silent Night (Knife)"] = 50,
    ["Makeshift (Knife)"] = 45,
    ["Zombified"] = 40,
    ["Starry (Gun)"] = 25,
    ["Swirl"] = 22,
    ["Watcher (Gun)"] = 20,
    ["Magma (Gun)"] = 15,
    ["Silent Night (Gun)"] = 12,
    ["Snowflakes"] = 12,
    ["Floral (Knife)"] = 10,
    ["Ghostfire"] = 10,
    ["Aurora (Knife)"] = 7,
    ["Ghastly (Gun)"] = 7,
    ["Toxic (Knife)"] = 7,
    ["Wraith (Knife)"] = 5,
    ["Icicles (Gun)"] = 3,
    ["Jack"] = 3,
    ["Magma"] = 3,
    ["Snakebite (Knife)"] = 3,
    ["Vampire (Gun)"] = 3,
    ["Bats"] = 2,
    ["Candy Swirl (Gun)"] = 2,
    ["Green Marble"] = 2,
    ["Orange Marble"] = 2,
    ["Sun"] = 2,
    ["Toxic (Gun)"] = 2,
    ["Aurora (Gun)"] = 1,
    ["Candy Swirl (Knife)"] = 1,
    ["Darkgun"] = 1,
    ["Gingerbread"] = 1,
    ["Monster"] = 1,
    ["Snakebite (Gun)"] = 1,
    ["Vampire (Knife)"] = 1,
    ["Bones"] = 225,
    ["Brains"] = 140,
    ["Zombified (Knife)"] = 120,
    ["Gingerbread (Knife)"] = 80,
    ["Sweater (Knife)"] = 60,
    ["Snowflake (Knife)"] = 55,
    ["Branches"] = 50,
    ["Mummy (2017)"] = 18,
    ["Skulls"] = 15,
    ["Zombified (Gun)"] = 15,
    ["Void"] = 12,
    ["Wrap (Gun)"] = 12,
    ["Wrap (Knife)"] = 12,
    ["Steel (Gun)"] = 8,
    ["Gothic (Gun)"] = 7,
    ["Zombie"] = 7,
    ["Hazard (Gun)"] = 5,
    ["Snowman (Gun)"] = 5,
    ["Zombie (Gun)"] = 5,
    ["Frozen (Gun)"] = 3,
    ["Gingerbread (Gun)"] = 3,
    ["Lantern"] = 3,
    ["Potion (2017)"] = 3,
    ["Webs"] = 3,
    ["Zombie (2023)"] = 3,
    ["Lights (Gun)"] = 2,
    ["Meltdown"] = 2,
    ["Mummy (Gun)"] = 2,
    ["Potion (Gun)"] = 2,
    ["Potion (Knife)"] = 2,
    ["Pumpkin Pie"] = 2,
    ["Stars (Knife)"] = 2,
    ["Tree (2021)"] = 2,
    ["Frozen (Knife)"] = 1,
    ["Holly (Gun)"] = 1,
    ["Lights (Knife)"] = 1,
    ["Moonlight"] = 1,
    ["Moons"] = 1,
    ["Mummy (Knife)"] = 1,
    ["Vampire"] = 1,
    ["Wolf"] = 1,
    ["Zombie (Knife)"] = 1,
    ["Corrupt"] = 450,
    ["Blood"] = 8,
    ["Ghost"] = 8,
    ["Laser"] = 8,
    ["America"] = 7,
    ["Prince"] = 6,
    ["Shadow"] = 6,
    ["Phaser"] = 5,
    ["Cowboy"] = 4,
    ["Golden"] = 4,
    ["Splitter"] = 3,
}
supremeValues = supremeValuesJsonSnapshot

-- Demand values from the user-provided Supreme snapshot.
local supremeDemandValues = {
	["Gingerscope"] = 6,
	["Nik's Scythe"] = 11,
	["Traveler's Axe"] = 5,
	["Celestial"] = 6,
	["Vampire's Axe"] = 5,
	["Harvester"] = 3,
	["Icepiercer"] = 3,
	["Icebreaker"] = 1,
	["Batwing"] = 10,
	["Elderwood Scythe"] = 1,
	["Swirly Axe"] = 1,
	["Hallowscythe"] = 1,
	["Logchopper"] = 1,
	["Icewing"] = 2,
	["C. Traveler's Gun"] = 9,
	["Chroma Evergun"] = 8,
	["Chroma Evergreen"] = 7,
	["Chroma Bauble"] = 7,
	["C. Vampire's Gun"] = 7,
	["C. Constellation"] = 7,
	["Chroma Alienbeam"] = 6,
	["Chroma Sunrise"] = 6,
	["Chroma Raygun"] = 6,
	["Chroma Sunset"] = 6,
	["Chroma Blizzard"] = 5,
	["Chroma Snowcannon"] = 5,
	["Chroma Heart Wand"] = 5,
	["Chroma Snowstorm"] = 5,
	["Chroma Snow Dagger"] = 5,
	["Chroma Watergun"] = 5,
	["Chroma Treat"] = 5,
	["Chroma Sweet"] = 5,
	["Chroma Icecream"] = 5,
	["Chroma Sands"] = 5,
	["Chroma Beachy"] = 5,
	["Chroma Ornament"] = 5,
	["Chroma Darkbringer"] = 1,
	["Chroma Lightbringer"] = 1,
	["Chroma Luger"] = 1,
	["Chroma Candleflame"] = 1,
	["Chroma Laser"] = 1,
	["Chroma Swirly Gun"] = 1,
	["C. Elderwood Blade"] = 1,
	["Chroma Deathshard"] = 1,
	["Chroma Cookiecane"] = 1,
	["Chroma Fang"] = 1,
	["Chroma Gemstone"] = 1,
	["Chroma Shark"] = 1,
	["Chroma Slasher"] = 1,
	["Chroma Heat"] = 1,
	["Chroma Seer"] = 1,
	["Chroma Gingerblade"] = 1,
	["Chroma Tides"] = 1,
	["Chroma Saw"] = 1,
	["Chroma Boneblade"] = 1,
	["Bats (Knife)"] = 3,
	["Ghoulish"] = 3,
	["Gifts (Knife)"] = 3,
	["Pine (Knife)"] = 3,
	["Glitch1"] = 3,
	["Glitch2"] = 2,
	["Frosted (Knife)"] = 2,
	["Mummified"] = 2,
	["Snowflakes (Gun)"] = 2,
	["Sparkle9"] = 2,
	["Wrapped (Gun)"] = 2,
	["CandyCorn (2017)"] = 2,
	["Ecto"] = 2,
	["Snowman (Gun)"] = 2,
	["Webbed (Gun)"] = 2,
	["Slimy"] = 2,
	["Sparkle10"] = 2,
	["Sparkle8"] = 2,
	["Sparkle7"] = 2,
	["RIP"] = 2,
	["Coal (Knife)"] = 2,
	["Elf (Knife)"] = 2,
	["Candy Corn (2019)"] = 2,
	["Elf (2018)"] = 2,
	["Prism"] = 2,
	["Pumpkin (2019)"] = 2,
	["Sparkle6"] = 2,
	["Combat II"] = 2,
	["Phantom"] = 1,
	["Sparkle4"] = 2,
	["Zombie"] = 2,
	["Skool"] = 2,
	["Sparkle5"] = 2,
	["Tailslide"] = 2,
	["Starry"] = 2,
	["Alex"] = 2,
	["Corl"] = 2,
	["Denis"] = 2,
	["Euro"] = 2,
	["Ollie"] = 2,
	["Sidewinder"] = 2,
	["Sketchy"] = 2,
	["Sub"] = 2,
	["Apocalypse (Gun)"] = 2,
	["Bats (2020)"] = 2,
	["Ghosty"] = 2,
	["Infected (Gun)"] = 2,
	["Sparkle1"] = 2,
	["Sparkle2"] = 2,
	["Sparkle3"] = 2,
	["Asteroid"] = 1,
	["Grind"] = 1,
	["Indy"] = 1,
	["Bats (Gun)"] = 1,
	["Grave (Gun)"] = 1,
	["Grave (Knife)"] = 1,
	["Haunted (Gun)"] = 1,
	["Haunted (Knife)"] = 1,
	["Slashed"] = 2,
	["Slime (Gun)"] = 1,
	["Slime (Knife)"] = 1,
	["Black Luger"] = 10,
	["Traveler's Gun"] = 5,
	["Evergun"] = 5,
	["Constellation"] = 5,
	["Evergreen"] = 5,
	["Turkey"] = 5,
	["Vampire's Gun"] = 5,
	["Alienbeam"] = 5,
	["Darkshot"] = 6,
	["Darksword"] = 6,
	["Raygun"] = 6,
	["Blossom"] = 6,
	["Sakura"] = 6,
	["Sunrise"] = 5,
	["Snowcannon"] = 5,
	["Bauble"] = 5,
	["Sunset"] = 5,
	["Soul"] = 5,
	["Spirit"] = 5,
	["Rainbow Gun"] = 5,
	["Flora"] = 5,
	["Rainbow"] = 5,
	["Bloom"] = 5,
	["Heart Wand"] = 4,
	["Ocean"] = 4,
	["Waves"] = 4,
	["Xenoknife"] = 4,
	["Xenoshot"] = 4,
	["Flowerwood Gun"] = 4,
	["Blizzard"] = 4,
	["Flowerwood"] = 4,
	["Snowstorm"] = 4,
	["Snow Dagger"] = 3,
	["Watergun"] = 3,
	["Icecream"] = 3,
	["Treat"] = 3,
	["Beachy"] = 3,
	["Sands"] = 3,
	["Sweet"] = 3,
	["Borealis"] = 3,
	["Australis"] = 3,
	["Bat"] = 2,
	["Pearlshine"] = 1,
	["Candy"] = 1,
	["Pearl"] = 1,
	["Heartblade"] = 1,
	["Luger"] = 1,
	["Red Luger"] = 1,
	["Spectre"] = 1,
	["Candleflame"] = 1,
	["Darkbringer"] = 1,
	["Elderwood Blade"] = 1,
	["Elderwood Revolver"] = 1,
	["Iceblaster"] = 1,
	["Lightbringer"] = 1,
	["Makeshift"] = 1,
	["Sugar"] = 1,
	["Ornament"] = 1,
	["Green Luger"] = 1,
	["Amerilaser"] = 1,
	["Laser"] = 1,
	["Hallowgun"] = 1,
	["Nightblade"] = 1,
	["Latte (Gun)"] = 3,
	["Latte (Knife)"] = 3,
	["Spectral (Knife)"] = 2,
	["Traveler (Gun)"] = 2,
	["Aurora (Gun)"] = 1,
	["Vampire (Gun)"] = 2,
	["Beach"] = 2,
	["Cotton Candy"] = 2,
	["JD"] = 2,
	["Arctic (Gun)"] = 2,
	["Broken"] = 2,
	["Cavern (Knife)"] = 2,
	["Ghost (Knife)"] = 1,
	["Ginger (Gun)"] = 1,
	["Icedriller"] = 2,
	["Nightsky"] = 2,
	["Bunnies"] = 2,
	["Red Scratch"] = 1,
	["Skulls"] = 2,
	["Aurora (Knife)"] = 2,
	["Blue Elite"] = 1,
	["Green Elite"] = 1,
	["Santa's Magic"] = 1,
	["Santa's Spirit"] = 1,
	["Spectral (Gun)"] = 2,
	["Traveler (Knife)"] = 2,
	["Vampire (Knife)"] = 1,
	["Witched"] = 2,
	["Blue Scratch"] = 1,
	["Energized (Gun)"] = 2,
	["Frostfade (Knife)"] = 2,
	["Ghost (Gun)"] = 1,
	["Cavern (Gun)"] = 1,
	["Chromatic (Knife)"] = 2,
	["Icecracker"] = 2,
	["Red Fire"] = 1,
	["Cane (Knife)"] = 4,
	["Dungeon"] = 3,
	["Darkknife"] = 3,
	["Silent Night (Knife)"] = 2,
	["Makeshift (Knife)"] = 2,
	["Zombified"] = 2,
	["Starry (Gun)"] = 2,
	["Swirl"] = 2,
	["Watcher (Gun)"] = 2,
	["Magma (Gun)"] = 2,
	["Silent Night (Gun)"] = 2,
	["Snowflakes"] = 2,
	["Floral (Knife)"] = 2,
	["Ghostfire"] = 2,
	["Ghastly (Gun)"] = 2,
	["Toxic (Knife)"] = 2,
	["Wraith (Knife)"] = 2,
	["Icicles (Gun)"] = 2,
	["Jack"] = 2,
	["Magma"] = 1,
	["Snakebite (Knife)"] = 2,
	["Bats"] = 1,
	["Candy Swirl (Gun)"] = 2,
	["Green Marble"] = 1,
	["Orange Marble"] = 1,
	["Sun"] = 2,
	["Toxic (Gun)"] = 1,
	["Candy Swirl (Knife)"] = 1,
	["Darkgun"] = 2,
	["Gingerbread"] = 1,
	["Monster"] = 1,
	["Snakebite (Gun)"] = 1,
	["Bones"] = 3,
	["Brains"] = 3,
	["Zombified (Knife)"] = 3,
	["Gingerbread (Knife)"] = 3,
	["Sweater (Knife)"] = 3,
	["Snowflake (Knife)"] = 3,
	["Branches"] = 3,
	["Mummy (2017)"] = 2,
	["Zombified (Gun)"] = 2,
	["Void"] = 2,
	["Wrap (Gun)"] = 2,
	["Wrap (Knife)"] = 2,
	["Steel (Gun)"] = 2,
	["Gothic (Gun)"] = 2,
	["Hazard (Gun)"] = 2,
	["Zombie (Gun)"] = 1,
	["Frozen (Gun)"] = 1,
	["Gingerbread (Gun)"] = 2,
	["Lantern"] = 2,
	["Potion (2017)"] = 1,
	["Webs"] = 2,
	["Zombie (2023)"] = 2,
	["Lights (Gun)"] = 1,
	["Meltdown"] = 2,
	["Mummy (Gun)"] = 1,
	["Potion (Gun)"] = 1,
	["Potion (Knife)"] = 1,
	["Pumpkin Pie"] = 2,
	["Stars (Knife)"] = 2,
	["Tree (2021)"] = 2,
	["Frozen (Knife)"] = 1,
	["Holly (Gun)"] = 1,
	["Lights (Knife)"] = 1,
	["Moonlight"] = 2,
	["Moons"] = 1,
	["Mummy (Knife)"] = 1,
	["Vampire"] = 1,
	["Wolf"] = 1,
	["Zombie (Knife)"] = 1,
	["Corrupt"] = 4,
	["Blood"] = 1,
	["Ghost"] = 1,
	["America"] = 1,
	["Prince"] = 1,
	["Shadow"] = 1,
	["Phaser"] = 1,
	["Cowboy"] = 1,
	["Golden"] = 1,
	["Splitter"] = 1,
}

-- Some Supreme entries intentionally share a display name but differ by category.
-- Trade event payloads include Category, so preserve those exact variants here.
local supremeCategoryValues = {
	["batwing"] = {
		["ancient"] = { name = "Batwing", value = 42 },
		["godly"] = { name = "Batwing", value = 1000000 },
	},
	["snowman gun"] = {
		["common"] = { name = "Snowman (Gun)", value = 25 },
		["uncommon"] = { name = "Snowman (Gun)", value = 5 },
	},
	["phantom"] = {
		["common"] = { name = "Phantom", value = 10 },
		["godly"] = { name = "Phantom", value = 35 },
	},
	["zombie"] = {
		["common"] = { name = "Zombie", value = 10 },
		["uncommon"] = { name = "Zombie", value = 7 },
	},
	["laser"] = {
		["godly"] = { name = "Laser", value = 22 },
		["vintage"] = { name = "Laser", value = 8 },
	},
	["aurora gun"] = {
		["legendary"] = { name = "Aurora (Gun)", value = 50 },
		["rare"] = { name = "Aurora (Gun)", value = 1 },
	},
	["vampire gun"] = {
		["legendary"] = { name = "Vampire (Gun)", value = 50 },
		["rare"] = { name = "Vampire (Gun)", value = 3 },
	},
	["skulls"] = {
		["legendary"] = { name = "Skulls", value = 4 },
		["uncommon"] = { name = "Skulls", value = 15 },
	},
	["aurora knife"] = {
		["legendary"] = { name = "Aurora (Knife)", value = 3 },
		["rare"] = { name = "Aurora (Knife)", value = 7 },
	},
	["vampire knife"] = {
		["legendary"] = { name = "Vampire (Knife)", value = 3 },
		["rare"] = { name = "Vampire (Knife)", value = 1 },
	},
}

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

for itemName, value in pairs(supremeValues) do
	local normalizedName = normalizeItemName(itemName)
	normalizedValues[normalizedName] = { name = itemName, value = value }
	table.insert(sortedValueNames, itemName)
end

table.sort(sortedValueNames, function(left, right)
	return #left > #right
end)

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

-- Category-specific demand values for duplicate display names.
local supremeCategoryDemands = {
	["batwing"] = {
		["ancient"] = 1,
		["godly"] = 10,
	},
	["snowman gun"] = {
		["common"] = 2,
		["uncommon"] = 2,
	},
	["phantom"] = {
		["common"] = 2,
		["godly"] = 1,
	},
	["zombie"] = {
		["common"] = 2,
		["uncommon"] = 2,
	},
	["laser"] = {
		["godly"] = 1,
		["vintage"] = 1,
	},
	["aurora gun"] = {
		["legendary"] = 2,
		["rare"] = 1,
	},
	["vampire gun"] = {
		["legendary"] = 2,
		["rare"] = 2,
	},
	["skulls"] = {
		["legendary"] = 1,
		["uncommon"] = 2,
	},
	["aurora knife"] = {
		["legendary"] = 2,
		["rare"] = 2,
	},
	["vampire knife"] = {
		["legendary"] = 2,
		["rare"] = 1,
	},
}


-- Complete expanded list from the newer user-provided JSON.
-- Expanded snapshot from the newer user-provided JSON (526 grouped entries).
-- Retrieved: 2026-08-08T01:48:48.761Z; source values last updated: 2026-08-06T14:59:00.
local expandedSupremeValues = {
	["Nik's Scythe"] = "Priceless",
	["Batwing"] = 42,
	["Black Luger"] = 1000000,
	["C. Traveler's Gun"] = 220000,
	["Chroma Evergun"] = 75000,
	["Chroma Evergreen"] = 48000,
	["Chroma Bauble"] = 34000,
	["C. Vampire's Gun"] = 29000,
	["C. Constellation"] = 27000,
	["Chroma Alienbeam"] = 24000,
	["Gingerscope"] = 17750,
	["Chroma Sunrise"] = 13250,
	["Chroma Raygun"] = 12750,
	["Chroma Sunset"] = 8750,
	["Traveler's Axe"] = 8100,
	["Chroma Blizzard"] = 8000,
	["Chroma Snowcannon"] = 8000,
	["Traveler's Gun"] = 5600,
	["Chroma Heart Wand"] = 4250,
	["Chroma Snowstorm"] = 4250,
	["Chroma Snow Dagger"] = 4000,
	["Evergun"] = 3450,
	["Chroma Watergun"] = 3400,
	["Chroma Treat"] = 2700,
	["Constellation"] = 2700,
	["Evergreen"] = 2500,
	["Turkey"] = 2450,
	["Celestial"] = 2350,
	["Chroma Sweet"] = 2300,
	["Chroma Icecream"] = 2000,
	["Vampire's Gun"] = 1950,
	["Alienbeam"] = 1850,
	["Chroma Sands"] = 1850,
	["Chroma Beachy"] = 1800,
	["Chroma Ornament"] = 1800,
	["Darkshot"] = 1725,
	["Darksword"] = 1700,
	["Raygun"] = 1600,
	["Blossom"] = "x4 T1 Legendaries",
	["Sakura"] = 1330,
	["Vampire's Axe"] = 1225,
	["Sunrise"] = 1125,
	["Snowcannon"] = 850,
	["Bauble"] = 825,
	["Zombie Dog"] = 750,
	["Cane (Knife)"] = 625,
	["Sunset"] = "x3 T1 Rares",
	["Soul"] = 615,
	["Spirit"] = 605,
	["Elf (2019)"] = 575,
	["Corrupt"] = 450,
	["Rainbow Gun"] = 420,
	["Flora"] = 410,
	["Rainbow"] = 410,
	["Bloom"] = 400,
	["Heart Wand"] = 340,
	["Ocean"] = 285,
	["Waves"] = 280,
	["Xenoknife"] = 280,
	["Xenoshot"] = 280,
	["Flowerwood Gun"] = 265,
	["Blizzard"] = 260,
	["Flowerwood"] = 260,
	["Snowstorm"] = 260,
	["Harvester"] = 250,
	["Snow Dagger"] = 250,
	["Watergun"] = 250,
	["Bats (Knife)"] = 240,
	["Bones"] = 225,
	["Dungeon"] = 225,
	["Blue Pumpkin"] = 220,
	["Icecream"] = 160,
	["Icepiercer"] = 160,
	["Treat"] = 155,
	["Beachy"] = 150,
	["Dogey"] = 150,
	["Sands"] = 150,
	["Sweet"] = 150,
	["Borealis"] = 145,
	["Australis"] = 140,
	["Brains"] = 140,
	["Latte (Gun)"] = 140,
	["Latte (Knife)"] = 140,
	["Bat"] = "x2 T1 Uncommons",
	["Red Pumpkin"] = 120,
	["Zombified (Knife)"] = 120,
	["Ghoulish"] = 100,
	["Gifts (Knife)"] = 95,
	["Pearlshine"] = 85,
	["Pine (Knife)"] = 85,
	["Black Cat"] = 80,
	["Candy"] = 80,
	["Gingerbread (Knife)"] = "x1 T1 Legendary",
	["Pearl"] = 80,
	["Darkknife"] = 70,
	["Glitch1"] = 70,
	["Chroma Darkbringer"] = 65,
	["Heartblade"] = 65,
	["Icebreaker"] = 65,
	["Chroma Lightbringer"] = 60,
	["Green Pumpkin"] = 60,
	["Sweater (Knife)"] = 60,
	["Mr. Reindeer"] = 55,
	["Piggy"] = 55,
	["Pumpkin (2017)"] = 55,
	["Snowflake (Knife)"] = 55,
	["Spectral (Knife)"] = 55,
	["Traveler (Gun)"] = 55,
	["Aurora (Gun)"] = 1,
	["Branches"] = 50,
	["Chroma Luger"] = 50,
	["Silent Night (Knife)"] = 50,
	["Vampire (Gun)"] = 3,
	["Makeshift (Knife)"] = 45,
	["Chroma Candleflame"] = 40,
	["Chroma Laser"] = 40,
	["Luger"] = 40,
	["Zombified"] = 40,
	["Chroma Swirly Gun"] = 38,
	["Elderwood Scythe"] = 38,
	["Swirly Axe"] = 38,
	["C. Elderwood Blade"] = 37,
	["Red Luger"] = 37,
	["Beach"] = 35,
	["Chroma Deathshard"] = 35,
	["Cotton Candy"] = 35,
	["Glitch2"] = 35,
	["Phantom"] = 10,
	["Spectre"] = 35,
	["Candleflame"] = 33,
	["Darkbringer"] = 33,
	["Elderwood Blade"] = 33,
	["Elderwood Revolver"] = 33,
	["Iceblaster"] = 33,
	["Lightbringer"] = 33,
	["Makeshift"] = 33,
	["Chroma Cookiecane"] = 32,
	["Chroma Fang"] = 32,
	["Chroma Gemstone"] = 32,
	["Chroma Shark"] = 32,
	["Chroma Slasher"] = 32,
	["Sugar"] = 32,
	["Frosted (Knife)"] = 30,
	["Hallowscythe"] = 30,
	["Mummified"] = 30,
	["Snowflakes (Gun)"] = 30,
	["Sparkle9"] = 30,
	["Wrapped (Gun)"] = "x4 T1 Legendaries",
	["Chroma Heat"] = 28,
	["Chroma Seer"] = 28,
	["JD"] = 28,
	["Ornament"] = 28,
	["Chroma Gingerblade"] = 27,
	["Chroma Tides"] = 27,
	["CandyCorn (2017)"] = 25,
	["Ecto"] = 25,
	["Elf"] = 25,
	["Snowman (Gun)"] = 5,
	["Starry (Gun)"] = 25,
	["Webbed (Gun)"] = 25,
	["Chroma Saw"] = 23,
	["Green Luger"] = 23,
	["Amerilaser"] = 22,
	["Chroma Boneblade"] = 22,
	["Laser"] = 8,
	["Swirl"] = 22,
	["Hallowgun"] = 20,
	["Nightblade"] = 20,
	["Slimy"] = 20,
	["Sparkle10"] = 20,
	["Sparkle8"] = 20,
	["Watcher (Gun)"] = 20,
	["Logchopper"] = 18,
	["Mr. Snowman"] = 18,
	["Mummy (2017)"] = 18,
	["Sparkle7"] = 18,
	["RIP"] = 17,
	["Coal (Knife)"] = 15,
	["Elf (Knife)"] = 15,
	["Magma (Gun)"] = 15,
	["Skulls"] = 4,
	["Skully"] = 15,
	["Zombified (Gun)"] = 15,
	["Icewing"] = 13,
	["Candy Corn (2019)"] = 12,
	["Elf (2018)"] = 12,
	["Prism"] = 12,
	["Pumpkin (2019)"] = "x3 T1 Uncommons",
	["Silent Night (Gun)"] = 12,
	["Snowflakes"] = 12,
	["Sparkle6"] = 12,
	["Void"] = 12,
	["Wrap (Gun)"] = 12,
	["Wrap (Knife)"] = 12,
	["Arctic (Gun)"] = 10,
	["Combat II"] = 10,
	["Floral (Knife)"] = 10,
	["Ghostfire"] = 10,
	["Sparkle4"] = 10,
	["Zombie"] = 7,
	["Blood"] = 8,
	["Ghost"] = 8,
	["Skool"] = 8,
	["Sparkle5"] = 8,
	["Steel (Gun)"] = 8,
	["<3"] = 7,
	["America"] = 7,
	["Aurora (Knife)"] = 3,
	["Broken"] = 7,
	["Cavern (Knife)"] = 7,
	["Ghastly (Gun)"] = 7,
	["Gothic (Gun)"] = 7,
	["Tailslide"] = 7,
	["Toxic (Knife)"] = 7,
	["Prince"] = 6,
	["Shadow"] = 6,
	["Ghost (Knife)"] = 5,
	["Ginger (Gun)"] = "x4 T1 Legendaries",
	["Hazard (Gun)"] = 5,
	["Icedriller"] = 5,
	["Nightsky"] = 5,
	["Nobledragon"] = 5,
	["Phaser"] = 5,
	["Shadow Pumpkin"] = 5,
	["Skeleton Key"] = 5,
	["Starry"] = 5,
	["Wraith (Knife)"] = 5,
	["Zombie (Gun)"] = 5,
	["Alex"] = 4,
	["Bunnies"] = 4,
	["Corl"] = 4,
	["Cowboy"] = 4,
	["Denis"] = 4,
	["Euro"] = 4,
	["Golden"] = 4,
	["Ollie"] = 4,
	["Red Scratch"] = 4,
	["Sidewinder"] = 4,
	["Sketchy"] = 4,
	["Sub"] = 4,
	["Apocalypse (Gun)"] = 3,
	["Bats (2020)"] = 3,
	["Blue Elite"] = 3,
	["Chilly"] = 3,
	["Chroma Fire Bat"] = 3,
	["Chroma Fire Bear"] = 3,
	["Chroma Fire Bunny"] = 3,
	["Chroma Fire Cat"] = 3,
	["Chroma Fire Dog"] = 3,
	["Chroma Fire Fox"] = 3,
	["Chroma Fire Pig"] = 3,
	["Eyeball"] = 3,
	["Fairy"] = 3,
	["Frozen (Gun)"] = "x4 T1 Legendaries",
	["Ghosty"] = 3,
	["Gingerbread (Gun)"] = "x4 T1 Legendaries",
	["Green Elite"] = 3,
	["Icicles (Gun)"] = 3,
	["Infected (Gun)"] = 3,
	["Jack"] = 3,
	["Jetstream"] = 3,
	["Lantern"] = 3,
	["Magma"] = 3,
	["Mechbug"] = 3,
	["Overseer Eye"] = 3,
	["Pengy"] = 3,
	["Potion (2017)"] = 3,
	["Purple Pumpkin"] = 3,
	["Reindeer"] = 3,
	["Rudolph"] = 3,
	["Santa's Magic"] = 3,
	["Santa's Spirit"] = 3,
	["Seahorsey"] = 3,
	["Snakebite (Knife)"] = 3,
	["Snowbear"] = 3,
	["Sparkle1"] = 3,
	["Sparkle2"] = 3,
	["Sparkle3"] = 3,
	["Spectral (Gun)"] = 3,
	["Splitter"] = 3,
	["Tankie"] = 3,
	["Traveler (Knife)"] = 3,
	["UFO"] = 3,
	["Vampire (Knife)"] = 1,
	["Vampire Bat"] = 3,
	["Webs"] = 3,
	["Witched"] = 3,
	["Zombie (2023)"] = 3,
	["Asteroid"] = 2,
	["Bats"] = 2,
	["Blue Papers"] = 2,
	["Blue Scratch"] = 2,
	["Box of Fertilizer"] = 2,
	["Candy Swirl (Gun)"] = 2,
	["Energized (Gun)"] = 2,
	["Frostfade (Knife)"] = 2,
	["Ghost (Gun)"] = 2,
	["Gold Papers"] = 2,
	["Green Marble"] = 2,
	["Green Papers"] = 2,
	["Grind"] = 2,
	["Indy"] = 2,
	["Lights (Gun)"] = 2,
	["Meltdown"] = 2,
	["Mummy (Gun)"] = 2,
	["Orange Marble"] = 2,
	["Potion (Gun)"] = 2,
	["Potion (Knife)"] = 2,
	["Pumpkin Pie"] = 2,
	["Purple Papers"] = 2,
	["Red Papers"] = 2,
	["Stars (Knife)"] = 2,
	["Sun"] = 2,
	["Toxic (Gun)"] = 2,
	["Tree (2021)"] = 2,
	["Ultra Wrap"] = 2,
	["Badger"] = 1,
	["Bats (Gun)"] = 1,
	["Candy Swirl (Knife)"] = 1,
	["Cavern (Gun)"] = 1,
	["Chromatic (Knife)"] = 1,
	["Darkgun"] = 1,
	["Frozen (Knife)"] = "x3 T1 Legendaries",
	["Gingerbread"] = 1,
	["Grave (Gun)"] = 1,
	["Grave (Knife)"] = 1,
	["Haunted (Gun)"] = 1,
	["Haunted (Knife)"] = 1,
	["Holly (Gun)"] = 1,
	["Icecracker"] = 1,
	["Lights (Knife)"] = 1,
	["Lil' Alien"] = 1,
	["Monster"] = 1,
	["Moonlight"] = 1,
	["Moons"] = 1,
	["Mummy (Knife)"] = 1,
	["Mystery Key"] = 1,
	["Red Fire"] = 1,
	["Slashed"] = 1,
	["Slime (Gun)"] = 1,
	["Slime (Knife)"] = 1,
	["Snakebite (Gun)"] = 1,
	["Vampire"] = 1,
	["Wolf"] = 1,
	["Zombie (Knife)"] = 1,
	["2015"] = "x4 T1 Legendaries",
	["Apocalypse (Knife)"] = "x4 T1 Legendaries",
	["Arctic (Knife)"] = "x4 T1 Legendaries",
	["Bunny"] = "x4 T1 Legendaries",
	["Cane (Gun)"] = "x4 T1 Legendaries",
	["Chromatic (Gun)"] = "x4 T1 Legendaries",
	["Cookie (Knife)"] = "x4 T1 Legendaries",
	["Cursed (Knife)"] = "x4 T1 Legendaries",
	["Emerald"] = "x4 T1 Legendaries",
	["Energized (Knife)"] = "x4 T1 Legendaries",
	["Gifted"] = "x4 T1 Legendaries",
	["Ginger (Knife)"] = "x2 T1 Legendaries",
	["Gothic (Knife)"] = "x4 T1 Legendaries",
	["Green Fire"] = "x4 T1 Legendaries",
	["Infected (Knife)"] = "x4 T1 Legendaries",
	["Mummy"] = "x4 T1 Legendaries",
	["Nightstar"] = "x4 T1 Legendaries",
	["Nutcracker"] = "x4 T1 Legendaries",
	["Overseer (Gun)"] = "x4 T1 Legendaries",
	["Predator (Knife)"] = "x4 T1 Legendaries",
	["Ripper (Knife)"] = "x4 T1 Legendaries",
	["Rupture"] = "x4 T1 Legendaries",
	["Snowman (Knife)"] = "x4 T1 Legendaries",
	["Snowy"] = "x3 T1 Legendaries",
	["Starry (Knife)"] = "x4 T1 Legendaries",
	["Tree (Gun)"] = "x4 T1 Legendaries",
	["Tree (Knife)"] = "x3 T1 Rares",
	["Web"] = "x4 T1 Legendaries",
	["Wrapped (Knife)"] = "x4 T1 Legendaries",
	["Aquarium (Gun)"] = "x3 T1 Legendaries",
	["Bubbles"] = "x3 T1 Legendaries",
	["Carrot Bunny"] = "x3 T1 Legendaries",
	["Cursed (Gun)"] = "x3 T1 Legendaries",
	["Deathspeaker"] = "x3 T1 Legendaries",
	["Electro"] = "x3 T1 Legendaries",
	["Frostbird"] = "x3 T1 Legendaries",
	["Frostfade (Gun)"] = "x3 T1 Legendaries",
	["Ice Phoenix"] = "x3 T1 Legendaries",
	["Icey"] = "x3 T1 Legendaries",
	["Icicles (Knife)"] = "x3 T1 Legendaries",
	["Magma (Knife)"] = "x3 T1 Legendaries",
	["Midnight"] = "x3 T1 Legendaries",
	["Nuke"] = "x3 T1 Legendaries",
	["Palms (Gun)"] = "x3 T1 Legendaries",
	["Phoenix"] = "x3 T1 Legendaries",
	["Sammy"] = "x3 T1 Legendaries",
	["Skelly"] = "x3 T1 Legendaries",
	["Sparkle"] = "x3 T1 Legendaries",
	["Steambird"] = "x3 T1 Legendaries",
	["Traveller"] = "x3 T1 Legendaries",
	["Watcher (Knife)"] = "x3 T1 Legendaries",
	["Aquarium (Knife)"] = "x2 T1 Legendaries",
	["Cupid"] = "x2 T1 Legendaries",
	["Fire Bat"] = "x2 T1 Legendaries",
	["Fire Bear"] = "x2 T1 Legendaries",
	["Fire Bunny"] = "x2 T1 Legendaries",
	["Fire Cat"] = "x2 T1 Legendaries",
	["Fire Dog"] = "x2 T1 Legendaries",
	["Fire Fox"] = "x2 T1 Legendaries",
	["Fire Pig"] = "x2 T1 Legendaries",
	["Ghastly (Knife)"] = "x2 T1 Legendaries",
	["Gifts 2015"] = "x2 T1 Legendaries",
	["Ice Camo"] = "x2 T1 Legendaries",
	["Logcutter"] = "x2 T1 Legendaries",
	["Molten (Gun)"] = "x2 T1 Legendaries",
	["Molten (Knife)"] = "x2 T1 Legendaries",
	["Palms (Knife)"] = "x2 T1 Legendaries",
	["Pumpkin (2018)"] = "x2 T1 Legendaries",
	["Ripper (Gun)"] = "x2 T1 Legendaries",
	["Snowflake Key"] = "x2 T1 Legendaries",
	["Steel (Knife)"] = "x2 T1 Legendaries",
	["Fade"] = "x4 T1 Rares",
	["Fusion"] = "x4 T1 Rares",
	["Overseer (Knife)"] = "x4 T1 Rares",
	["Plasmite"] = "x4 T1 Rares",
	["Predator (Gun)"] = "x4 T1 Rares",
	["Rune"] = "x4 T1 Rares",
	["Shiny"] = "x4 T1 Rares",
	["Splash (Knife)"] = "x4 T1 Rares",
	["Universe"] = "x4 T1 Rares",
	["Viper"] = "x4 T1 Rares",
	["Bio"] = "x3 T1 Rares",
	["Bones (Knife)"] = "x3 T1 Rares",
	["Curse"] = "x3 T1 Rares",
	["Elite"] = "x3 T1 Rares",
	["Frostflame (Gun)"] = "x3 T1 Rares",
	["Ghosts (Gun)"] = "x3 T1 Rares",
	["Gingercookie (Knife)"] = "x3 T1 Rares",
	["Hazard (Knife)"] = "x3 T1 Rares",
	["Hologram (Gun)"] = "x3 T1 Rares",
	["Mistletoe (Gun)"] = "x3 T1 Rares",
	["Pier"] = "x3 T1 Rares",
	["Pop Art (Knife)"] = "x3 T1 Rares",
	["Spearmint (Gun)"] = "x3 T1 Rares",
	["Splash (Gun)"] = "x3 T1 Rares",
	["Tree (2023)"] = "x3 T1 Rares",
	["Xeno (Knife)"] = "x3 T1 Rares",
	["Butterflies"] = "x1 T1 Legendary",
	["Candleflame (Gun)"] = "x1 T1 Legendary",
	["Damp"] = "x1 T1 Legendary",
	["Frostflame (Knife)"] = "x1 T1 Legendary",
	["Heart"] = "x1 T1 Legendary",
	["Neon"] = "x1 T1 Legendary",
	["Nether"] = "x1 T1 Legendary",
	["Painted (Knife)"] = "x1 T1 Legendary",
	["Pool Noodle"] = "x1 T1 Legendary",
	["Scarecrow"] = "x1 T1 Legendary",
	["Spitfire"] = "x1 T1 Legendary",
	["Storm"] = "x1 T1 Legendary",
	["Teddy"] = "x1 T1 Legendary",
	["Wraith (Gun)"] = "x1 T1 Legendary",
	["Wraiths (Knife)"] = "x1 T1 Legendary",
	["Gingerheart"] = "x2 T1 Rares",
	["Love (Gun)"] = "x2 T1 Rares",
	["Rose"] = "x2 T1 Rares",
	["Canes (Gun)"] = "x1 T1 Rare",
	["Cookie (Gun)"] = "x1 T1 Rare",
	["Fireplace"] = "x1 T1 Rare",
	["Forest"] = "x1 T1 Rare",
	["Frosty"] = "x1 T1 Rare",
	["Holly (Knife)"] = "x1 T1 Rare",
	["Marble"] = "x1 T1 Rare",
	["Melon"] = "x1 T1 Rare",
	["Snowflake (Gun)"] = "x1 T1 Rare",
	["Stockings (Knife)"] = "x3 T1 Uncommons",
	["Elitey"] = "x1 T1 Uncommon",
	["Santa Dog"] = "x1 T1 Uncommon",
	["Bear"] = "x3 T1 Commons",
	["Candies (2016)"] = "x2 T1 Commons",
	["Fox"] = "x2 T1 Commons",
	["Pig"] = "x2 T1 Commons",
	["Pumpkin (2020)"] = "x2 T1 Commons",
	["Candies (2017)"] = "x1 T1 Common",
	["Cat"] = "x1 T1 Common",
	["Dog"] = "x1 T1 Common",
	["Pumpkin (2021)"] = "x1 T1 Common",
	["Blaster"] = 17,
	["Blue"] = "Unvalued",
	["Cookiecane"] = 13,
	["Eternalcane"] = 13,
	["Ginger Luger"] = 17,
	["Gingerblade"] = 13,
	["Gingermint"] = 12,
	["Green"] = "Unvalued",
	["Icebeam"] = 18,
	["Iceflake"] = 15,
	["Lugercane"] = 13,
	["Minty"] = 13,
	["Old Glory"] = 15,
	["Plasmabeam"] = 18,
	["Plasmablade"] = 15,
	["Purple"] = "Unvalued",
	["Revolver"] = "Unvalued",
	["Scythe"] = "Unvalued",
	["Slasher"] = 15,
	["Swirly Blade"] = 12,
	["Swirly Gun"] = 18,
	["Virtual"] = 13,
}
local expandedSupremeDemands = {
	["Nik's Scythe"] = 11,
	["Batwing"] = 1,
	["Black Luger"] = 10,
	["C. Traveler's Gun"] = 9,
	["Chroma Evergun"] = 8,
	["Chroma Evergreen"] = 7,
	["Chroma Bauble"] = 7,
	["C. Vampire's Gun"] = 7,
	["C. Constellation"] = 7,
	["Chroma Alienbeam"] = 6,
	["Gingerscope"] = 6,
	["Chroma Sunrise"] = 6,
	["Chroma Raygun"] = 6,
	["Chroma Sunset"] = 6,
	["Traveler's Axe"] = 5,
	["Chroma Blizzard"] = 5,
	["Chroma Snowcannon"] = 5,
	["Traveler's Gun"] = 5,
	["Chroma Heart Wand"] = 5,
	["Chroma Snowstorm"] = 5,
	["Chroma Snow Dagger"] = 5,
	["Evergun"] = 5,
	["Chroma Watergun"] = 5,
	["Chroma Treat"] = 5,
	["Constellation"] = 5,
	["Evergreen"] = 5,
	["Turkey"] = 5,
	["Celestial"] = 6,
	["Chroma Sweet"] = 5,
	["Chroma Icecream"] = 5,
	["Vampire's Gun"] = 5,
	["Alienbeam"] = 5,
	["Chroma Sands"] = 5,
	["Chroma Beachy"] = 5,
	["Chroma Ornament"] = 5,
	["Darkshot"] = 6,
	["Darksword"] = 6,
	["Raygun"] = 6,
	["Blossom"] = 1,
	["Sakura"] = 6,
	["Vampire's Axe"] = 5,
	["Sunrise"] = 5,
	["Snowcannon"] = 5,
	["Bauble"] = 5,
	["Zombie Dog"] = 4,
	["Cane (Knife)"] = 4,
	["Sunset"] = 1,
	["Soul"] = 5,
	["Spirit"] = 5,
	["Elf (2019)"] = 4,
	["Corrupt"] = 4,
	["Rainbow Gun"] = 5,
	["Flora"] = 5,
	["Rainbow"] = 5,
	["Bloom"] = 5,
	["Heart Wand"] = 4,
	["Ocean"] = 4,
	["Waves"] = 4,
	["Xenoknife"] = 4,
	["Xenoshot"] = 4,
	["Flowerwood Gun"] = 4,
	["Blizzard"] = 4,
	["Flowerwood"] = 4,
	["Snowstorm"] = 4,
	["Harvester"] = 3,
	["Snow Dagger"] = 3,
	["Watergun"] = 3,
	["Bats (Knife)"] = 3,
	["Bones"] = 3,
	["Dungeon"] = 3,
	["Blue Pumpkin"] = 3,
	["Icecream"] = 3,
	["Icepiercer"] = 3,
	["Treat"] = 3,
	["Beachy"] = 3,
	["Dogey"] = 3,
	["Sands"] = 3,
	["Sweet"] = 3,
	["Borealis"] = 3,
	["Australis"] = 3,
	["Brains"] = 3,
	["Latte (Gun)"] = 3,
	["Latte (Knife)"] = 3,
	["Bat"] = 1,
	["Red Pumpkin"] = 3,
	["Zombified (Knife)"] = 3,
	["Ghoulish"] = 3,
	["Gifts (Knife)"] = 3,
	["Pearlshine"] = 1,
	["Pine (Knife)"] = 3,
	["Black Cat"] = 3,
	["Candy"] = 1,
	["Gingerbread (Knife)"] = 2,
	["Pearl"] = 1,
	["Darkknife"] = 3,
	["Glitch1"] = 3,
	["Chroma Darkbringer"] = 1,
	["Heartblade"] = 1,
	["Icebreaker"] = 1,
	["Chroma Lightbringer"] = 1,
	["Green Pumpkin"] = 3,
	["Sweater (Knife)"] = 3,
	["Mr. Reindeer"] = 3,
	["Piggy"] = 3,
	["Pumpkin (2017)"] = 3,
	["Snowflake (Knife)"] = 3,
	["Spectral (Knife)"] = 2,
	["Traveler (Gun)"] = 2,
	["Aurora (Gun)"] = 1,
	["Branches"] = 3,
	["Chroma Luger"] = 1,
	["Silent Night (Knife)"] = 2,
	["Vampire (Gun)"] = 2,
	["Makeshift (Knife)"] = 2,
	["Chroma Candleflame"] = 1,
	["Chroma Laser"] = 1,
	["Luger"] = 1,
	["Zombified"] = 2,
	["Chroma Swirly Gun"] = 1,
	["Elderwood Scythe"] = 1,
	["Swirly Axe"] = 1,
	["C. Elderwood Blade"] = 1,
	["Red Luger"] = 1,
	["Beach"] = 2,
	["Chroma Deathshard"] = 1,
	["Cotton Candy"] = 2,
	["Glitch2"] = 2,
	["Phantom"] = 2,
	["Spectre"] = 1,
	["Candleflame"] = 1,
	["Darkbringer"] = 1,
	["Elderwood Blade"] = 1,
	["Elderwood Revolver"] = 1,
	["Iceblaster"] = 1,
	["Lightbringer"] = 1,
	["Makeshift"] = 1,
	["Chroma Cookiecane"] = 1,
	["Chroma Fang"] = 1,
	["Chroma Gemstone"] = 1,
	["Chroma Shark"] = 1,
	["Chroma Slasher"] = 1,
	["Sugar"] = 1,
	["Frosted (Knife)"] = 2,
	["Hallowscythe"] = 1,
	["Mummified"] = 2,
	["Snowflakes (Gun)"] = 2,
	["Sparkle9"] = 2,
	["Wrapped (Gun)"] = 1,
	["Chroma Heat"] = 1,
	["Chroma Seer"] = 1,
	["JD"] = 2,
	["Ornament"] = 1,
	["Chroma Gingerblade"] = 1,
	["Chroma Tides"] = 1,
	["CandyCorn (2017)"] = 2,
	["Ecto"] = 2,
	["Elf"] = 2,
	["Snowman (Gun)"] = 2,
	["Starry (Gun)"] = 2,
	["Webbed (Gun)"] = 2,
	["Chroma Saw"] = 1,
	["Green Luger"] = 1,
	["Amerilaser"] = 1,
	["Chroma Boneblade"] = 1,
	["Laser"] = 1,
	["Swirl"] = 2,
	["Hallowgun"] = 1,
	["Nightblade"] = 1,
	["Slimy"] = 2,
	["Sparkle10"] = 2,
	["Sparkle8"] = 2,
	["Watcher (Gun)"] = 2,
	["Logchopper"] = 1,
	["Mr. Snowman"] = 2,
	["Mummy (2017)"] = 2,
	["Sparkle7"] = 2,
	["RIP"] = 2,
	["Coal (Knife)"] = 2,
	["Elf (Knife)"] = 2,
	["Magma (Gun)"] = 2,
	["Skulls"] = 1,
	["Skully"] = 2,
	["Zombified (Gun)"] = 2,
	["Icewing"] = 2,
	["Candy Corn (2019)"] = 2,
	["Elf (2018)"] = 2,
	["Prism"] = 2,
	["Pumpkin (2019)"] = 1,
	["Silent Night (Gun)"] = 2,
	["Snowflakes"] = 2,
	["Sparkle6"] = 2,
	["Void"] = 2,
	["Wrap (Gun)"] = 2,
	["Wrap (Knife)"] = 2,
	["Arctic (Gun)"] = 2,
	["Combat II"] = 2,
	["Floral (Knife)"] = 2,
	["Ghostfire"] = 2,
	["Sparkle4"] = 2,
	["Zombie"] = 2,
	["Blood"] = 1,
	["Ghost"] = 1,
	["Skool"] = 2,
	["Sparkle5"] = 2,
	["Steel (Gun)"] = 2,
	["<3"] = 1,
	["America"] = 1,
	["Aurora (Knife)"] = 2,
	["Broken"] = 2,
	["Cavern (Knife)"] = 2,
	["Ghastly (Gun)"] = 2,
	["Gothic (Gun)"] = 2,
	["Tailslide"] = 2,
	["Toxic (Knife)"] = 2,
	["Prince"] = 1,
	["Shadow"] = 1,
	["Ghost (Knife)"] = 1,
	["Ginger (Gun)"] = 1,
	["Hazard (Gun)"] = 2,
	["Icedriller"] = 2,
	["Nightsky"] = 2,
	["Nobledragon"] = 1,
	["Phaser"] = 1,
	["Shadow Pumpkin"] = 2,
	["Skeleton Key"] = 1,
	["Starry"] = 2,
	["Wraith (Knife)"] = 2,
	["Zombie (Gun)"] = 1,
	["Alex"] = 2,
	["Bunnies"] = 2,
	["Corl"] = 2,
	["Cowboy"] = 1,
	["Denis"] = 2,
	["Euro"] = 2,
	["Golden"] = 1,
	["Ollie"] = 2,
	["Red Scratch"] = 1,
	["Sidewinder"] = 2,
	["Sketchy"] = 2,
	["Sub"] = 2,
	["Apocalypse (Gun)"] = 2,
	["Bats (2020)"] = 2,
	["Blue Elite"] = 1,
	["Chilly"] = 1,
	["Chroma Fire Bat"] = 1,
	["Chroma Fire Bear"] = 1,
	["Chroma Fire Bunny"] = 1,
	["Chroma Fire Cat"] = 1,
	["Chroma Fire Dog"] = 1,
	["Chroma Fire Fox"] = 1,
	["Chroma Fire Pig"] = 1,
	["Eyeball"] = 1,
	["Fairy"] = 1,
	["Frozen (Gun)"] = 2,
	["Ghosty"] = 2,
	["Gingerbread (Gun)"] = 2,
	["Green Elite"] = 1,
	["Icicles (Gun)"] = 2,
	["Infected (Gun)"] = 2,
	["Jack"] = 2,
	["Jetstream"] = 1,
	["Lantern"] = 2,
	["Magma"] = 1,
	["Mechbug"] = 1,
	["Overseer Eye"] = 1,
	["Pengy"] = 1,
	["Potion (2017)"] = 1,
	["Purple Pumpkin"] = 1,
	["Reindeer"] = 1,
	["Rudolph"] = 1,
	["Santa's Magic"] = 1,
	["Santa's Spirit"] = 1,
	["Seahorsey"] = 1,
	["Snakebite (Knife)"] = 2,
	["Snowbear"] = 2,
	["Sparkle1"] = 2,
	["Sparkle2"] = 2,
	["Sparkle3"] = 2,
	["Spectral (Gun)"] = 2,
	["Splitter"] = 1,
	["Tankie"] = 1,
	["Traveler (Knife)"] = 2,
	["UFO"] = 1,
	["Vampire (Knife)"] = 1,
	["Vampire Bat"] = 1,
	["Webs"] = 2,
	["Witched"] = 2,
	["Zombie (2023)"] = 2,
	["Asteroid"] = 1,
	["Bats"] = 1,
	["Blue Papers"] = 1,
	["Blue Scratch"] = 1,
	["Box of Fertilizer"] = 1,
	["Candy Swirl (Gun)"] = 2,
	["Energized (Gun)"] = 2,
	["Frostfade (Knife)"] = 2,
	["Ghost (Gun)"] = 1,
	["Gold Papers"] = 1,
	["Green Marble"] = 1,
	["Green Papers"] = 1,
	["Grind"] = 1,
	["Indy"] = 1,
	["Lights (Gun)"] = 1,
	["Meltdown"] = 2,
	["Mummy (Gun)"] = 1,
	["Orange Marble"] = 1,
	["Potion (Gun)"] = 1,
	["Potion (Knife)"] = 1,
	["Pumpkin Pie"] = 2,
	["Purple Papers"] = 1,
	["Red Papers"] = 1,
	["Stars (Knife)"] = 2,
	["Sun"] = 2,
	["Toxic (Gun)"] = 1,
	["Tree (2021)"] = 2,
	["Ultra Wrap"] = 1,
	["Badger"] = 1,
	["Bats (Gun)"] = 1,
	["Candy Swirl (Knife)"] = 1,
	["Cavern (Gun)"] = 1,
	["Chromatic (Knife)"] = 2,
	["Darkgun"] = 2,
	["Frozen (Knife)"] = 2,
	["Gingerbread"] = 1,
	["Grave (Gun)"] = 1,
	["Grave (Knife)"] = 1,
	["Haunted (Gun)"] = 1,
	["Haunted (Knife)"] = 1,
	["Holly (Gun)"] = 1,
	["Icecracker"] = 2,
	["Lights (Knife)"] = 1,
	["Lil' Alien"] = 2,
	["Monster"] = 1,
	["Moonlight"] = 2,
	["Moons"] = 1,
	["Mummy (Knife)"] = 1,
	["Mystery Key"] = 2,
	["Red Fire"] = 1,
	["Slashed"] = 2,
	["Slime (Gun)"] = 1,
	["Slime (Knife)"] = 1,
	["Snakebite (Gun)"] = 1,
	["Vampire"] = 1,
	["Wolf"] = 1,
	["Zombie (Knife)"] = 1,
	["2015"] = 1,
	["Apocalypse (Knife)"] = 2,
	["Arctic (Knife)"] = 2,
	["Bunny"] = 1,
	["Cane (Gun)"] = 1,
	["Chromatic (Gun)"] = 2,
	["Cookie (Knife)"] = 2,
	["Cursed (Knife)"] = 2,
	["Emerald"] = 2,
	["Energized (Knife)"] = 2,
	["Gifted"] = 1,
	["Ginger (Knife)"] = 2,
	["Gothic (Knife)"] = 2,
	["Green Fire"] = 1,
	["Infected (Knife)"] = 2,
	["Mummy"] = 1,
	["Nightstar"] = 2,
	["Nutcracker"] = 1,
	["Overseer (Gun)"] = 2,
	["Predator (Knife)"] = 2,
	["Ripper (Knife)"] = 2,
	["Rupture"] = 1,
	["Snowman (Knife)"] = 1,
	["Snowy"] = 1,
	["Starry (Knife)"] = 2,
	["Tree (Gun)"] = 1,
	["Tree (Knife)"] = 2,
	["Web"] = 1,
	["Wrapped (Knife)"] = 1,
	["Aquarium (Gun)"] = 2,
	["Bubbles"] = 2,
	["Carrot Bunny"] = 2,
	["Cursed (Gun)"] = 2,
	["Deathspeaker"] = 1,
	["Electro"] = 1,
	["Frostbird"] = 1,
	["Frostfade (Gun)"] = 2,
	["Ice Phoenix"] = 1,
	["Icey"] = 1,
	["Icicles (Knife)"] = 1,
	["Magma (Knife)"] = 2,
	["Midnight"] = 2,
	["Nuke"] = 2,
	["Palms (Gun)"] = 2,
	["Phoenix"] = 1,
	["Sammy"] = 1,
	["Skelly"] = 1,
	["Sparkle"] = 2,
	["Steambird"] = 1,
	["Traveller"] = 1,
	["Watcher (Knife)"] = 2,
	["Aquarium (Knife)"] = 1,
	["Cupid"] = 2,
	["Fire Bat"] = 1,
	["Fire Bear"] = 1,
	["Fire Bunny"] = 1,
	["Fire Cat"] = 1,
	["Fire Dog"] = 1,
	["Fire Fox"] = 1,
	["Fire Pig"] = 1,
	["Ghastly (Knife)"] = 2,
	["Gifts 2015"] = 1,
	["Ice Camo"] = 2,
	["Logcutter"] = 2,
	["Molten (Gun)"] = 2,
	["Molten (Knife)"] = 2,
	["Palms (Knife)"] = 1,
	["Pumpkin (2018)"] = 2,
	["Ripper (Gun)"] = 2,
	["Snowflake Key"] = 1,
	["Steel (Knife)"] = 2,
	["Fade"] = 1,
	["Fusion"] = 1,
	["Overseer (Knife)"] = 2,
	["Plasmite"] = 1,
	["Predator (Gun)"] = 2,
	["Rune"] = 2,
	["Shiny"] = 1,
	["Splash (Knife)"] = 1,
	["Universe"] = 2,
	["Viper"] = 2,
	["Bio"] = 2,
	["Bones (Knife)"] = 2,
	["Curse"] = 2,
	["Elite"] = 1,
	["Frostflame (Gun)"] = 2,
	["Ghosts (Gun)"] = 2,
	["Gingercookie (Knife)"] = 2,
	["Hazard (Knife)"] = 2,
	["Hologram (Gun)"] = 2,
	["Mistletoe (Gun)"] = 2,
	["Pier"] = 1,
	["Pop Art (Knife)"] = 2,
	["Spearmint (Gun)"] = 2,
	["Splash (Gun)"] = 1,
	["Tree (2023)"] = 2,
	["Xeno (Knife)"] = 2,
	["Butterflies"] = 2,
	["Candleflame (Gun)"] = 2,
	["Damp"] = 2,
	["Frostflame (Knife)"] = 2,
	["Heart"] = 2,
	["Neon"] = 2,
	["Nether"] = 2,
	["Painted (Knife)"] = 2,
	["Pool Noodle"] = 2,
	["Scarecrow"] = 2,
	["Spitfire"] = 2,
	["Storm"] = 2,
	["Teddy"] = 2,
	["Wraith (Gun)"] = 2,
	["Wraiths (Knife)"] = 2,
	["Gingerheart"] = 2,
	["Love (Gun)"] = 2,
	["Rose"] = 2,
	["Canes (Gun)"] = 2,
	["Cookie (Gun)"] = 2,
	["Fireplace"] = 2,
	["Forest"] = 2,
	["Frosty"] = 1,
	["Holly (Knife)"] = 1,
	["Marble"] = 2,
	["Melon"] = 2,
	["Snowflake (Gun)"] = 2,
	["Stockings (Knife)"] = 2,
	["Elitey"] = 1,
	["Santa Dog"] = 1,
	["Bear"] = 1,
	["Candies (2016)"] = 1,
	["Fox"] = 1,
	["Pig"] = 1,
	["Pumpkin (2020)"] = 1,
	["Candies (2017)"] = 1,
	["Cat"] = 1,
	["Dog"] = 1,
	["Pumpkin (2021)"] = 1,
	["Blaster"] = 1,
	["Blue"] = 3,
	["Cookiecane"] = 1,
	["Eternalcane"] = 1,
	["Ginger Luger"] = 1,
	["Gingerblade"] = 1,
	["Gingermint"] = 1,
	["Green"] = 3,
	["Icebeam"] = 1,
	["Iceflake"] = 1,
	["Lugercane"] = 1,
	["Minty"] = 1,
	["Old Glory"] = 1,
	["Plasmabeam"] = 1,
	["Plasmablade"] = 1,
	["Purple"] = 3,
	["Revolver"] = 1,
	["Scythe"] = 1,
	["Slasher"] = 1,
	["Swirly Blade"] = 1,
	["Swirly Gun"] = 1,
	["Virtual"] = 1,
}
local expandedSupremeCategoryValues = {
	["batwing"] = {
		["godly"] = { name = "Batwing", value = 1000000 },
		["ancient"] = { name = "Batwing", value = 42 },
	},
	["blossom"] = {
		["godly"] = { name = "Blossom", value = 1340 },
		["common"] = { name = "Blossom", value = "x4 T1 Legendaries" },
	},
	["sunset"] = {
		["godly"] = { name = "Sunset", value = 625 },
		["rare"] = { name = "Sunset", value = "x3 T1 Rares" },
	},
	["bat"] = {
		["godly"] = { name = "Bat", value = 120 },
		["pet"] = { name = "Bat", value = "x2 T1 Uncommons" },
	},
	["gingerbread knife"] = {
		["uncommon"] = { name = "Gingerbread (Knife)", value = 80 },
		["rare"] = { name = "Gingerbread (Knife)", value = "x1 T1 Legendary" },
	},
	["aurora gun"] = {
		["legendary"] = { name = "Aurora (Gun)", value = 50 },
		["rare"] = { name = "Aurora (Gun)", value = 1 },
	},
	["vampire gun"] = {
		["legendary"] = { name = "Vampire (Gun)", value = 50 },
		["rare"] = { name = "Vampire (Gun)", value = 3 },
	},
	["phantom"] = {
		["godly"] = { name = "Phantom", value = 35 },
		["common"] = { name = "Phantom", value = 10 },
	},
	["wrapped gun"] = {
		["common"] = { name = "Wrapped (Gun)", value = 30 },
		["uncommon"] = { name = "Wrapped (Gun)", value = "x4 T1 Legendaries" },
	},
	["snowman gun"] = {
		["common"] = { name = "Snowman (Gun)", value = 25 },
		["uncommon"] = { name = "Snowman (Gun)", value = 5 },
	},
	["laser"] = {
		["godly"] = { name = "Laser", value = 22 },
		["vintage"] = { name = "Laser", value = 8 },
	},
	["skulls"] = {
		["uncommon"] = { name = "Skulls", value = 15 },
		["legendary"] = { name = "Skulls", value = 4 },
	},
	["pumpkin 2019"] = {
		["common"] = { name = "Pumpkin (2019)", value = 12 },
		["pet"] = { name = "Pumpkin (2019)", value = "x3 T1 Uncommons" },
	},
	["zombie"] = {
		["common"] = { name = "Zombie", value = 10 },
		["uncommon"] = { name = "Zombie", value = 7 },
	},
	["aurora knife"] = {
		["rare"] = { name = "Aurora (Knife)", value = 7 },
		["legendary"] = { name = "Aurora (Knife)", value = 3 },
	},
	["ginger gun"] = {
		["legendary"] = { name = "Ginger (Gun)", value = 5 },
		["rare"] = { name = "Ginger (Gun)", value = "x4 T1 Legendaries" },
	},
	["frozen gun"] = {
		["uncommon"] = { name = "Frozen (Gun)", value = 3 },
		["legendary"] = { name = "Frozen (Gun)", value = "x4 T1 Legendaries" },
	},
	["gingerbread gun"] = {
		["uncommon"] = { name = "Gingerbread (Gun)", value = 3 },
		["rare"] = { name = "Gingerbread (Gun)", value = "x4 T1 Legendaries" },
	},
	["vampire knife"] = {
		["legendary"] = { name = "Vampire (Knife)", value = 3 },
		["rare"] = { name = "Vampire (Knife)", value = 1 },
	},
	["frozen knife"] = {
		["uncommon"] = { name = "Frozen (Knife)", value = 1 },
		["legendary"] = { name = "Frozen (Knife)", value = "x3 T1 Legendaries" },
	},
	["ginger knife"] = {
		["rare"] = { name = "Ginger (Knife)", value = "x4 T1 Legendaries" },
		["legendary"] = { name = "Ginger (Knife)", value = "x2 T1 Legendaries" },
	},
	["snowy"] = {
		["uncommon"] = { name = "Snowy", value = "x4 T1 Legendaries" },
		["rare"] = { name = "Snowy", value = "x3 T1 Legendaries" },
	},
	["tree knife"] = {
		["legendary"] = { name = "Tree (Knife)", value = "x4 T1 Legendaries" },
		["rare"] = { name = "Tree (Knife)", value = "x3 T1 Rares" },
	},
}
local expandedSupremeCategoryDemands = {
	["batwing"] = {
		["godly"] = 10,
		["ancient"] = 1,
	},
	["blossom"] = {
		["godly"] = 6,
		["common"] = 1,
	},
	["sunset"] = {
		["godly"] = 5,
		["rare"] = 1,
	},
	["bat"] = {
		["godly"] = 2,
		["pet"] = 1,
	},
	["gingerbread knife"] = {
		["uncommon"] = 3,
		["rare"] = 2,
	},
	["aurora gun"] = {
		["legendary"] = 2,
		["rare"] = 1,
	},
	["vampire gun"] = {
		["legendary"] = 2,
		["rare"] = 2,
	},
	["phantom"] = {
		["godly"] = 1,
		["common"] = 2,
	},
	["wrapped gun"] = {
		["common"] = 2,
		["uncommon"] = 1,
	},
	["snowman gun"] = {
		["common"] = 2,
		["uncommon"] = 2,
	},
	["laser"] = {
		["godly"] = 1,
		["vintage"] = 1,
	},
	["skulls"] = {
		["uncommon"] = 2,
		["legendary"] = 1,
	},
	["pumpkin 2019"] = {
		["common"] = 2,
		["pet"] = 1,
	},
	["zombie"] = {
		["common"] = 2,
		["uncommon"] = 2,
	},
	["aurora knife"] = {
		["rare"] = 2,
		["legendary"] = 2,
	},
	["ginger gun"] = {
		["legendary"] = 1,
		["rare"] = 1,
	},
	["frozen gun"] = {
		["uncommon"] = 1,
		["legendary"] = 2,
	},
	["gingerbread gun"] = {
		["uncommon"] = 2,
		["rare"] = 2,
	},
	["vampire knife"] = {
		["legendary"] = 2,
		["rare"] = 1,
	},
	["frozen knife"] = {
		["uncommon"] = 1,
		["legendary"] = 2,
	},
	["ginger knife"] = {
		["rare"] = 1,
		["legendary"] = 2,
	},
	["snowy"] = {
		["uncommon"] = 1,
		["rare"] = 1,
	},
	["tree knife"] = {
		["legendary"] = 1,
		["rare"] = 2,
	},
}
supremeValues = expandedSupremeValues
supremeDemandValues = expandedSupremeDemands
supremeCategoryValues = expandedSupremeCategoryValues
supremeCategoryDemands = expandedSupremeCategoryDemands

-- The trade payload uses internal item IDs. Resolve known IDs to their physical
-- display item before reading the Supreme value table.
local tradeNameAliases = {
	["scythe"] = "batwing",
}

-- Rebuild the normalized indexes after loading the expanded snapshot.
normalizedValues = {}
sortedValueNames = {}
for itemName, value in pairs(supremeValues) do
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
	normalizedName = tradeNameAliases[normalizedName] or normalizedName
	local categoryEntries = supremeCategoryValues[normalizedName]
	if categoryEntries then
		local normalizedCategory = normalizeCategory(category)
		if normalizedCategory ~= "" and categoryEntries[normalizedCategory] then
			return categoryEntries[normalizedCategory]
		end
		-- Batwing is the Ancient item in normal MM2 trade payloads. Some payloads
		-- omit the category or send a generic category, so keep its 42-value entry.
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
	normalizedName = tradeNameAliases[normalizedName] or normalizedName
	local categoryEntries = supremeCategoryDemands[normalizedName]
	if categoryEntries then
		local normalizedCategory = normalizeCategory(category)
		if normalizedCategory ~= "" and categoryEntries[normalizedCategory] then
			return categoryEntries[normalizedCategory]
		end
		if normalizedName == "batwing" then
			return categoryEntries.ancient
		end
		return supremeDemandValues[normalizedName]
	end
	return supremeDemandValues[normalizedName]
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

-- Internal controls retain shared state for the trade and role callbacks without
-- constructing or parenting the removed legacy interface.
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
tradeUpdated.Text = "Supreme snapshot: " .. supremeValuesUpdated
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

-- Role diagnostics: this only reads an explicit Role/TeamRole attribute
-- or StringValue exposed by your own test place. It does not inspect remotes or
-- infer hidden roles from live-game state.

local function playerHasTool(targetPlayer, toolName)
	local character = targetPlayer.Character
	local backpack = targetPlayer:FindFirstChild("Backpack")
	-- Equipped and backpack Tools are direct children. Avoid recursive searches
	-- here because this function runs repeatedly for every player.
	return (character and character:FindFirstChild(toolName) ~= nil)
		or (backpack and backpack:FindFirstChild(toolName) ~= nil)
end

local function readRole(targetPlayer)

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

	-- Test fallback: mirror the public tool markers used by your own
	-- test place without reading remotes, disabling idle connections, or
	-- sending player data anywhere. Explicit role attributes still win.
	local hasKnife = playerHasTool(targetPlayer, "Knife")
	local hasGun = playerHasTool(targetPlayer, "Gun")
	if hasKnife then
		return "Murderer"
	elseif hasGun then
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
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		local hasKnife = playerHasTool(targetPlayer, "Knife")
		local hasGun = playerHasTool(targetPlayer, "Gun")
		if hasKnife then
			trackedMurderers[targetPlayer] = true
		elseif not hasGun and not trackedMurderers[targetPlayer] then
			-- Any player seen unarmed before they take the gun can be a Hero.
			trackedInnocents[targetPlayer] = true
		elseif hasGun and not trackedSheriff and now - trackedRoundStartedAt <= roleGracePeriod then
			trackedSheriff = targetPlayer
		end
	end
end

local function isDroppedGunName(name)
	local normalizedName = string.lower(name):gsub("[%s_%-]", "")
	return normalizedName == "gun"
		or normalizedName == "gundrop"
		or normalizedName == "droppedgun"
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

	-- MM2 parents GunDrop directly to Workspace. Only inspect top-level children;
	-- walking an entire map can allocate a very large descendants array during
	-- round transitions and was a source of severe frame spikes.
	for _, instance in ipairs(Workspace:GetChildren()) do
		local canBeGunDrop = instance:IsA("Tool") or instance:IsA("Model") or instance:IsA("BasePart")
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
end

local function moveDroppedGunToPlayer(droppedGun)
	if not autoPickupGunEnabled then
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
	lastGunPickupAttempt = now

	local gunPart = getGunPart(droppedGun)
	if not gunPart then
		return
	end

	local pickupCFrame = root.CFrame * CFrame.new(0, -2, 0)
	if droppedGun:IsA("Model") then
		droppedGun:PivotTo(pickupCFrame)
	else
		gunPart.CFrame = pickupCFrame
	end

	local prompt = droppedGun:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt and type(fireproximityprompt) == "function" then
		pcall(fireproximityprompt, prompt)
	end
	if type(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, gunPart, 0)
			firetouchinterest(root, gunPart, 1)
		end)
	end
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
					labelText.Text = targetPlayer.DisplayName .. " • " .. role
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
					entry.labelText.Text = targetPlayer.DisplayName .. " • " .. role
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
		roleHighlightStatus.Text = ("Role highlights on • %d players with exposed roles"):format(shown)
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

local mainNav = createNavButton("Main", 82)
local tradeNav = createNavButton("Trade", 124)
local playerNav = createNavButton("Player", 166)
local settingsNav = createNavButton("Settings", 208)

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

local function teleportToRole(roleName)
	local localCharacter = player.Character
	local localRoot = localCharacter and localCharacter:FindFirstChild("HumanoidRootPart")
	if not localRoot then
		roleHighlightStatus.Text = "Your character is not ready to teleport."
		return
	end

	for _, targetPlayer in ipairs(Players:GetPlayers()) do
		if targetPlayer ~= player then
			local detectedRole = string.lower(readRole(targetPlayer) or "")
			local matchesRole = roleName == "Sheriff / Hero"
				and (detectedRole:find("sheriff", 1, true) ~= nil
					or detectedRole:find("detective", 1, true) ~= nil
					or detectedRole:find("hero", 1, true) ~= nil)
				or roleName == "Murderer"
				and (detectedRole:find("murder", 1, true) ~= nil or detectedRole:find("killer", 1, true) ~= nil)
			if matchesRole then
				local targetCharacter = targetPlayer.Character
				local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
				if targetRoot then
					localRoot.CFrame = targetRoot.CFrame * CFrame.new(3, 0, 0)
					roleHighlightStatus.Text = "Teleported to " .. targetPlayer.DisplayName .. " (" .. roleName .. ")"
					return
				end
			end
		end
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

table.insert(connections, Workspace.ChildAdded:Connect(requestGunScan))
table.insert(connections, Workspace.ChildRemoved:Connect(requestGunScan))

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
	-- MM2's visible headings are more reliable than its internal instance names.
	-- Find the nearest panel that contains both offer headings.
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

	-- Fallback for trade UIs whose offer containers do not include predictable
	-- names. Prefer the largest visible GUI object named like a trade window.
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
	-- The game's trade frame can appear just after its data event, so retry once
	-- after the UI has had a moment to render.
	task.delay(0.5, function()
		if not stopped then
			updateBuiltInTradeSummary()
		end
	end)
end

-- Offer slots are normally inserted/removed as the trade changes. Coalesce a
-- burst of UI changes into one scan instead of repeatedly walking PlayerGui.
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
			-- Prefer a physical label when the payload ID has no value, or when
			-- the visible slot explicitly marks the item as Chroma.
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

-- Rayfield interface (requires an executor that supports loadstring and HttpGet).
-- Try the official short URL first and the official source as a fallback so a
-- temporary redirect failure does not leave the script running without a GUI.
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
			input.Text = tostring(value)
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
			jumpInput.Text = tostring(value)
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

	local PlayerTab = Window:CreateTab("Player", "users")
	PlayerTab:CreateSection("Roles")
	PlayerTab:CreateToggle({
		Name = "Role highlights",
		CurrentValue = roleHighlightsEnabled,
		Flag = "beano_role_highlights",
		Callback = function(value)
			roleHighlightsEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	PlayerTab:CreateToggle({
		Name = "Character chams",
		CurrentValue = roleChamsEnabled,
		Flag = "beano_role_chams",
		Callback = function(value)
			roleChamsEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	PlayerTab:CreateToggle({
		Name = "Role names",
		CurrentValue = roleNamesEnabled,
		Flag = "beano_role_names",
		Callback = function(value)
			roleNamesEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	local roleLinesToggle = PlayerTab:CreateToggle({
		Name = "Role lines",
		CurrentValue = roleLinesEnabled,
		Flag = "beano_role_lines",
		Callback = function(value)
			roleLinesEnabled = value
			updateRoleToggleButtons()
			refreshRoleHighlights()
		end,
	})
	PlayerTab:CreateButton({
		Name = "Teleport to Sheriff / Hero",
		Callback = function()
			teleportToRole("Sheriff / Hero")
		end,
	})
	PlayerTab:CreateButton({
		Name = "Teleport to Murderer",
		Callback = function()
			teleportToRole("Murderer")
		end,
	})

	PlayerTab:CreateSection("Player actions")
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
	local selectedPlayerDropdown = PlayerTab:CreateDropdown({
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

	PlayerTab:CreateButton({
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
	PlayerTab:CreateButton({
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
	PlayerTab:CreateButton({
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
	PlayerTab:CreateButton({
		Name = "Fling selected player",
		Callback = function()
			local targetPlayer = validSelectedPlayer()
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
				local collisionStates = {}
				for _, descendant in ipairs(character:GetDescendants()) do
					if descendant:IsA("BasePart") then
						collisionStates[descendant] = descendant.CanCollide
						descendant.CanCollide = false
					end
				end

				local angularVelocity = Instance.new("BodyAngularVelocity")
				angularVelocity.Name = "BeanoFlingVelocity"
				angularVelocity.MaxTorque = Vector3.new(0, math.huge, 0)
				angularVelocity.P = 1250
				angularVelocity.AngularVelocity = Vector3.new(0, 1000000, 0)
				angularVelocity.Parent = root
				humanoid.AutoRotate = false

				pcall(function()
					for step = 1, 30 do
						if stopped or not flingInProgress or not root.Parent or not targetRoot.Parent then
							break
						end
						local angle = step * math.pi * 0.55
						root.CFrame = targetRoot.CFrame * CFrame.new(math.cos(angle) * 1.2, 0.5, math.sin(angle) * 1.2)
						root.AssemblyLinearVelocity = Vector3.new(0, 80, 0)
						RunService.Heartbeat:Wait()
					end
				end)

				if angularVelocity.Parent then
					angularVelocity:Destroy()
				end
				for part, canCollide in pairs(collisionStates) do
					if part.Parent then
						part.CanCollide = canCollide
					end
				end
				if humanoid.Parent then
					humanoid.AutoRotate = originalAutoRotate
				end
				if root.Parent then
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					root.CFrame = originalCFrame
				end
				flingInProgress = false
			end)
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

	PlayerTab:CreateToggle({
		Name = "Auto pickup dropped gun",
		CurrentValue = autoPickupGunEnabled,
		Flag = "beano_auto_pickup_gun",
		Callback = function(value)
			autoPickupGunEnabled = value
			updateAutoPickupGunButton()
		end,
	})
	PlayerTab:CreateToggle({
		Name = "Dropped gun ESP",
		CurrentValue = gunChamEnabled,
		Flag = "beano_gun_esp",
		Callback = function(value)
			gunChamEnabled = value
			gunScanRequested = true
			updateDroppedGunCham(findDroppedGun())
		end,
	})
	PlayerTab:CreateSection("Appearance")
	PlayerTab:CreateSlider({
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
	PlayerTab:CreateSlider({
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
	PlayerTab:CreateSlider({
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
			-- Turn off the two continuously rendered/enforced options first.
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
	SettingsTab:CreateLabel("Kill disconnects every managed event and removes all script-created visuals.", "circle-stop")
	SettingsTab:CreateButton({
		Name = "Kill script completely",
		Callback = function()
			stopScript()
		end,
	})
	-- The current Rayfield build loads configuration on its own after the window
	-- finishes assembling. Do not trigger it a second time during startup.
	interfaceReady = true
	scheduleVisibleTradeRefresh()

	-- gui is an unparented state container, so Rayfield remains the only UI.
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
