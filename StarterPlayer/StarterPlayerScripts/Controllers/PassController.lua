-- PassController
-- Client half of the monetization features:
--   * mirrors pass ownership and the cosmetic loadout, and raises Changed so
--     the shop can re-render
--   * opens Roblox purchase prompts for passes and cash products
--   * emote input (number row) and the bubbles they produce
--   * the spectator camera (V)
--
-- Ownership here is read from replicated attributes, which is fine for showing
-- and hiding UI. Nothing in this file is allowed to be the reason a benefit is
-- granted — every actual entitlement is re-checked server-side.

local Players            = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Remotes      = require(Shared:WaitForChild("Remotes"))
local Monetization = require(Shared:WaitForChild("Monetization"))
local Extras       = require(Shared:WaitForChild("Extras"))

local CameraController = require(script.Parent:WaitForChild("CameraController"))

local PassController = {}

local player = Players.LocalPlayer

local changedEvent = Instance.new("BindableEvent")
PassController.Changed = changedEvent.Event

local owned: { [string]: boolean } = {}
local loadout = {
	effective = { paddleSkin = Extras.DEFAULT_PADDLE_SKIN, title = Extras.DEFAULT_TITLE },
	choice    = { paddleSkin = Extras.DEFAULT_PADDLE_SKIN, title = Extras.DEFAULT_TITLE },
}

-- ── State ──────────────────────────────────────────────────────────────────

function PassController.owns(key: string): boolean
	return owned[key] == true
end

function PassController.getLoadout()
	return loadout
end

-- Shaped for Extras.canUseSkin / canUseTitle.
function PassController.predicate(): (string) -> boolean
	return PassController.owns
end

local function readAttributes()
	local changed = false
	for _, def in ipairs(Monetization.PASSES) do
		local value = player:GetAttribute(Monetization.attrFor(def.key)) == true
		if owned[def.key] ~= value then
			owned[def.key] = value
			changed = true
		end
	end
	return changed
end

-- ── Purchasing ────────────────────────────────────────────────────────────
-- Both prompts are safe to call with an unpublished id only because we refuse
-- to: MarketplaceService throws on id 0, and the shop renders those rows as
-- COMING SOON rather than wiring them to a button that errors.

function PassController.promptPass(key: string): boolean
	local def = Monetization.getPass(key)
	if not (def and Monetization.isConfigured(def)) then return false end
	local ok = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, def.id)
	end)
	return ok
end

function PassController.promptProduct(key: string): boolean
	local def = Monetization.getProduct(key)
	if not (def and Monetization.isConfigured(def)) then return false end
	local ok = pcall(function()
		MarketplaceService:PromptProductPurchase(player, def.id)
	end)
	return ok
end

-- Real prices come from Roblox, never from the suggested figure in
-- Monetization: that one is a note to whoever publishes the asset, and showing
-- it as fact would mislead anyone who set a different price on the dashboard.
-- Fetches are async, so the first render shows a placeholder and Changed pulls
-- the shop back through once the answer lands.
-- Cached as a small record rather than a bare number, because "no price yet"
-- and "published but taken off sale" are different states and the shop has to
-- render them differently. An offsale asset reports IsForSale = false and
-- usually no price at all; without this the row would sit on its loading
-- placeholder forever and the buy button would open a prompt that cannot
-- complete.
type PriceInfo = { price: number?, forSale: boolean }

local priceCache: { [string]: PriceInfo } = {}
local priceFetching: { [string]: boolean } = {}

local function fetchPrice(cacheKey: string, assetId: number, infoType: Enum.InfoType)
	if priceFetching[cacheKey] then return end
	priceFetching[cacheKey] = true
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		if ok and typeof(info) == "table" then
			priceCache[cacheKey] = {
				price = tonumber(info.PriceInRobux),
				forSale = info.IsForSale ~= false,
			}
			changedEvent:Fire()
		else
			-- Let a failed lookup be retried on the next render rather than
			-- caching a wrong answer.
			priceFetching[cacheKey] = nil
		end
	end)
end

local function lookup(cacheKey: string, assetId: number, infoType: Enum.InfoType): PriceInfo?
	local cached = priceCache[cacheKey]
	if cached then return cached end
	fetchPrice(cacheKey, assetId, infoType)
	return nil
end

-- Returns nil while the lookup is still in flight.
function PassController.priceInfoForPass(key: string): PriceInfo?
	local def = Monetization.getPass(key)
	if not (def and Monetization.isConfigured(def)) then return nil end
	return lookup("pass:" .. key, def.id, Enum.InfoType.GamePass)
end

function PassController.priceInfoForProduct(key: string): PriceInfo?
	local def = Monetization.getProduct(key)
	if not (def and Monetization.isConfigured(def)) then return nil end
	return lookup("product:" .. key, def.id, Enum.InfoType.Product)
end

function PassController.selectPaddle(id: string)
	Remotes.LoadoutRequest:FireServer("paddle", id)
end

function PassController.selectTitle(id: string)
	Remotes.LoadoutRequest:FireServer("title", id)
end

-- ── Emote bubbles ─────────────────────────────────────────────────────────
-- Drawn on the paddle rather than the character, because during a match the
-- camera is locked to the table and the characters are parked out of shot.

local EMOTE_LIFETIME = 2.2

-- Enum.KeyCode.One is named "One", not "1", so the digit has to be mapped
-- rather than parsed out of the name.
local DIGIT_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
}

local function findPaddle(role: string): Model?
	local tableName = player:GetAttribute("AirHockeyTable")
	if typeof(tableName) ~= "string" then return nil end
	local found = workspace:FindFirstChild(role .. "Paddle_" .. tableName)
	return (found and found:IsA("Model")) and found or nil
end

local function showEmote(role: string, emoteId: string)
	local emote = Extras.getEmote(emoteId)
	if not emote then return end

	local paddle = findPaddle(role)
	local root = paddle and (paddle.PrimaryPart or paddle:FindFirstChildWhichIsA("BasePart", true))
	if not root then return end

	-- One bubble per paddle: a second emote replaces the first rather than
	-- stacking two labels on top of each other.
	local existing = root:FindFirstChild("EmoteBubble")
	if existing then existing:Destroy() end

	local gui = Instance.new("BillboardGui")
	gui.Name = "EmoteBubble"
	gui.Size = UDim2.fromOffset(220, 60)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Arcade
	label.TextScaled = true
	label.Text = emote.text
	label.TextColor3 = emote.color
	label.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(15, 20, 35)
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()

	gui.Parent = root

	task.delay(EMOTE_LIFETIME, function()
		if gui.Parent then
			TweenService:Create(label, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
			TweenService:Create(stroke, TweenInfo.new(0.3), { Transparency = 1 }):Play()
			task.wait(0.35)
			gui:Destroy()
		end
	end)
end

-- ── Spectator camera ──────────────────────────────────────────────────────
-- V cycles through the tables and then hands the camera back. Sitting down
-- cancels it, because CameraController re-syncs on the seat attributes and
-- overwrites whatever we pointed it at.

local spectateIndex = 0

local function spectatableTables(): { Model }
	local out = {}
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("Model") and obj:FindFirstChild("Cameras") and obj:FindFirstChild("Pads") then
			table.insert(out, obj)
		end
	end
	table.sort(out, function(a, b) return a.Name < b.Name end)
	return out
end

local function stopSpectating()
	spectateIndex = 0
	CameraController.release()
end

PassController.stopSpectating = stopSpectating

local function cycleSpectate()
	if not PassController.owns("Spectate") then return false end
	-- Seated players are already looking at their own table.
	if player:GetAttribute("AirHockeyRole") then return false end

	local tables = spectatableTables()
	if #tables == 0 then return false end

	spectateIndex += 1
	if spectateIndex > #tables then
		stopSpectating()
		return true
	end

	CameraController.attach(tables[spectateIndex].Name, "Blue")
	return true
end

-- ── Init ──────────────────────────────────────────────────────────────────

function PassController.init()
	readAttributes()

	for _, def in ipairs(Monetization.PASSES) do
		player:GetAttributeChangedSignal(Monetization.attrFor(def.key)):Connect(function()
			if readAttributes() then
				changedEvent:Fire()
			end
		end)
	end

	Remotes.PassSync.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then return end
		for key, value in pairs(payload) do
			owned[key] = value == true
		end
		changedEvent:Fire()
	end)

	Remotes.LoadoutSync.OnClientEvent:Connect(function(payload)
		if typeof(payload) ~= "table" then return end
		if typeof(payload.effective) == "table" then loadout.effective = payload.effective end
		if typeof(payload.choice) == "table" then loadout.choice = payload.choice end
		changedEvent:Fire()
	end)

	Remotes.Emote.OnClientEvent:Connect(function(role: string, emoteId: string)
		if typeof(role) ~= "string" or typeof(emoteId) ~= "string" then return end
		showEmote(role, emoteId)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end

		if input.KeyCode == Enum.KeyCode.V then
			cycleSpectate()
			return
		end

		-- Emotes only make sense while seated, and only for pass holders. The
		-- server re-checks both; this just avoids firing a remote that will be
		-- thrown away.
		if not (PassController.owns("EmotePack") and player:GetAttribute("AirHockeyRole")) then
			return
		end
		local digit = DIGIT_KEYS[input.KeyCode]
		if not digit then return end
		local emote = Extras.getEmoteByKey(digit)
		if emote then
			Remotes.Emote:FireServer(emote.id)
		end
	end)

	-- Taking a seat ends a spectate, so the index does not leave us thinking we
	-- are still part-way through the cycle.
	player:GetAttributeChangedSignal("AirHockeyRole"):Connect(function()
		if player:GetAttribute("AirHockeyRole") then
			spectateIndex = 0
		end
	end)
end

return PassController
