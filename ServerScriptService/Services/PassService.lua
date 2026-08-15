-- PassService
-- Owns every question of the form "has this player paid for X".
--
--   * caches game pass ownership per session and mirrors it onto the player as
--     an attribute, so clients can grey out a shop row without a round trip
--   * refreshes the moment a purchase completes, so a pass works immediately
--     rather than on next join
--   * handles ProcessReceipt for the cash developer products
--   * runs the two grants that need memory across sessions (Big Bankroll's
--     one-time top-up, Daily Payday's 24h claim)
--
-- Server-side callers must use PassService.owns(). The mirrored attribute is
-- replicated state and a client can lie about it locally; anything that moves
-- money reads the cache here instead.

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local DataStoreService   = game:GetService("DataStoreService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local Shared        = ReplicatedStorage:WaitForChild("Shared")
local Monetization  = require(Shared:WaitForChild("Monetization"))
local Remotes       = require(Shared:WaitForChild("Remotes"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))

local PassService = {}

-- Opt-in rather than automatic-in-Studio (which is how the FX inventory grant
-- works): with passes, the locked state is usually the thing being tested.
--
-- The flag lives on ServerScriptService rather than on `game`, because
-- attributes set on the DataModel in Edit mode do not survive into the Play
-- datamodel — they read back nil the moment you press Play, which makes for a
-- dev switch that silently never works.
local DEV_GRANT_ALL = script.Parent.Parent:GetAttribute("DevGrantAllPasses") == true

local RECEIPT_STORE_NAME = "AH_Receipts_v1"
local META_BONUS_CLAIMED = "bonusClaimed"
local META_STIPEND_AT    = "stipendAt"

local receiptStore = nil
pcall(function()
	receiptStore = DataStoreService:GetDataStore(RECEIPT_STORE_NAME)
end)

-- userId -> { [passKey]: boolean }
local ownedByUserId: { [number]: { [string]: boolean } } = {}
-- userId -> true once the initial ownership sweep has finished
local readyByUserId: { [number]: boolean } = {}

local changedEvent = Instance.new("BindableEvent")
PassService.Changed = changedEvent.Event  -- (player, passKey, owned)

local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return "$" .. out
end

local function notify(player: Player, message: string, kind: string?)
	if player and player.Parent then
		Remotes.Notify:FireClient(player, message, kind or "info")
	end
end

local function syncPlayer(player: Player)
	local owned = ownedByUserId[player.UserId]
	if not owned then return end
	Remotes.PassSync:FireClient(player, owned)
end

local function setOwned(player: Player, key: string, owned: boolean)
	local bucket = ownedByUserId[player.UserId]
	if not bucket then
		bucket = {}
		ownedByUserId[player.UserId] = bucket
	end
	if bucket[key] == owned then return end
	bucket[key] = owned
	player:SetAttribute(Monetization.attrFor(key), owned)
	changedEvent:Fire(player, key, owned)
end

-- ── Grants ─────────────────────────────────────────────────────────────────

-- Big Bankroll brings a player *up to* a floor rather than adding a lump sum.
-- Adding would make buying it at Celestial rank a pure profit button; this way
-- it is exactly what it says on the tin — a head start — and is worth nothing
-- to someone who already has one.
local function grantStartingBonus(player: Player)
	if not PassService.owns(player, "StartingBonus") then return end
	if EconomyService.getMeta(player, META_BONUS_CLAIMED) == true then return end

	EconomyService.setMeta(player, META_BONUS_CLAIMED, true)

	local current = EconomyService.get(player)
	local topUp = Monetization.STARTING_BONUS_FLOOR - current
	if topUp > 0 then
		EconomyService.add(player, topUp, "pass_starting_bonus")
		notify(player, "Big Bankroll: topped up to " .. money(Monetization.STARTING_BONUS_FLOOR) .. "!", "win")
	else
		notify(player, "Big Bankroll claimed — you were already above "
			.. money(Monetization.STARTING_BONUS_FLOOR) .. ".", "info")
	end
end

-- Rolling 24h window rather than a calendar day, so the reset does not depend
-- on which timezone the server happens to be in.
local function grantDailyStipend(player: Player)
	if not PassService.owns(player, "DailyStipend") then return end

	local now = os.time()
	local last = tonumber(EconomyService.getMeta(player, META_STIPEND_AT)) or 0
	local elapsed = now - last
	if last > 0 and elapsed < Monetization.DAY_SECONDS then
		local hours = math.ceil((Monetization.DAY_SECONDS - elapsed) / 3600)
		notify(player, "Next payday in " .. hours .. "h.", "info")
		return
	end

	EconomyService.setMeta(player, META_STIPEND_AT, now)
	EconomyService.add(player, Monetization.DAILY_STIPEND, "pass_daily_stipend")
	notify(player, "Daily Payday: " .. money(Monetization.DAILY_STIPEND) .. " collected!", "win")
end

-- Run after ownership is known, and again after any purchase, so a pass bought
-- mid-session pays out straight away instead of on next join.
local function runGrants(player: Player)
	if not player.Parent then return end
	local ok, err = pcall(function()
		grantStartingBonus(player)
		grantDailyStipend(player)
	end)
	if not ok then
		warn("[PassService] grant failed for", player.Name, err)
	end
end

-- ── Ownership ─────────────────────────────────────────────────────────────

local function queryPass(player: Player, def)
	if DEV_GRANT_ALL then
		setOwned(player, def.key, true)
		return
	end

	-- An unpublished pass is simply not owned. Asking Marketplace about id 0
	-- throws, so the whole feature set can be built before any asset exists.
	if not Monetization.isConfigured(def) then
		setOwned(player, def.key, false)
		return
	end

	local ok, result = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
	end)
	setOwned(player, def.key, ok and result == true)
	if not ok then
		warn("[PassService] ownership check failed for", def.key, result)
	end
end

local function loadPlayer(player: Player)
	ownedByUserId[player.UserId] = ownedByUserId[player.UserId] or {}

	-- Fourteen sequential web calls would leave a joining player waiting several
	-- seconds with every entitlement reading false; fired together they all land
	-- inside one.
	local pending = #Monetization.PASSES
	for _, def in ipairs(Monetization.PASSES) do
		task.spawn(function()
			queryPass(player, def)
			pending -= 1
		end)
	end

	-- Polled rather than signalled, and bounded. A thread that dies inside
	-- queryPass would never fire a completion event, and the cost of that is a
	-- player who is permanently "still loading"; the cost of the timeout firing
	-- early is one sync that reads a pass as unowned until the next purchase.
	local deadline = os.clock() + 15
	while pending > 0 and os.clock() < deadline and player.Parent do
		task.wait(0.1)
	end
	if pending > 0 then
		warn("[PassService] ownership sweep for", player.Name, "did not finish;", pending, "outstanding")
	end

	readyByUserId[player.UserId] = true
	if not player.Parent then return end

	local ownedNames = {}
	for key, value in pairs(ownedByUserId[player.UserId]) do
		if value then table.insert(ownedNames, key) end
	end
	table.sort(ownedNames)
	print(string.format("[PassService] %s entitlements loaded: %s", player.Name,
		#ownedNames > 0 and table.concat(ownedNames, ", ") or "none"))

	syncPlayer(player)
	runGrants(player)
end

-- Non-yielding on purpose: this is called from the match loop and from payout
-- code. An unknown player reads as not owning, which fails closed.
function PassService.owns(player: Player?, key: string): boolean
	if not player then return false end
	local bucket = ownedByUserId[player.UserId]
	return (bucket and bucket[key]) == true
end

function PassService.getOwned(player: Player): { [string]: boolean }
	local bucket = ownedByUserId[player.UserId] or {}
	local copy = {}
	for key, value in pairs(bucket) do
		copy[key] = value
	end
	return copy
end

function PassService.isReady(player: Player): boolean
	return readyByUserId[player.UserId] == true
end

-- A closure shaped for Extras.canUseSkin / canUseTitle, which take a predicate
-- so the same rule can be evaluated against attributes on the client and
-- against this cache on the server.
function PassService.predicateFor(player: Player): (string) -> boolean
	return function(key: string): boolean
		return PassService.owns(player, key)
	end
end

-- ── Developer products ──────────────────────────────────────────────────────

-- Roblox retries ProcessReceipt until it returns PurchaseGranted, and may call
-- it again for a purchase that was already granted if the acknowledgement was
-- lost. Every granted PurchaseId is therefore recorded, and a repeat is
-- acknowledged without paying out twice.
local function alreadyGranted(purchaseId: string): boolean
	if not receiptStore then return false end
	local ok, seen = pcall(function()
		return receiptStore:GetAsync(purchaseId)
	end)
	return ok and seen == true
end

local function recordGranted(purchaseId: string): boolean
	if not receiptStore then
		-- No datastore (Studio without API access). Paying out is the right call:
		-- the alternative is refusing a purchase the player was charged for.
		return true
	end
	local ok = pcall(function()
		receiptStore:SetAsync(purchaseId, true)
	end)
	return ok
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left before it landed. NotProcessedYet means Roblox retries when
		-- they next join, which is exactly what should happen.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local def = Monetization.getProductById(receiptInfo.ProductId)
	if not def then
		warn("[PassService] unknown product id", receiptInfo.ProductId, "— add it to Monetization.PRODUCTS")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if alreadyGranted(purchaseKey) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local ok = pcall(function()
		EconomyService.add(player, def.cash, "product:" .. def.key)
	end)
	if not ok then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not recordGranted(purchaseKey) then
		-- The cash is already in their balance. Refusing here would have Roblox
		-- retry and pay it a second time, so acknowledge and accept that a lost
		-- write means one unrecorded receipt.
		warn("[PassService] could not record receipt", purchaseKey)
	end

	notify(player, def.name .. ": " .. money(def.cash) .. " added!", "win")
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ── Init ──────────────────────────────────────────────────────────────────

function PassService.init()
	local function onAdded(player: Player)
		-- Written before the sweep so the attributes exist from the first frame;
		-- the client watches them and would otherwise see nil, not false.
		for _, def in ipairs(Monetization.PASSES) do
			if player:GetAttribute(Monetization.attrFor(def.key)) == nil then
				player:SetAttribute(Monetization.attrFor(def.key), false)
			end
		end
		task.spawn(loadPlayer, player)
	end

	Players.PlayerAdded:Connect(onAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		ownedByUserId[player.UserId] = nil
		readyByUserId[player.UserId] = nil
	end)

	-- A pass bought from the in-game prompt has to work now, not next join.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if not wasPurchased then return end
		for _, def in ipairs(Monetization.PASSES) do
			if def.id == gamePassId and def.id > 0 then
				setOwned(player, def.key, true)
				syncPlayer(player)
				notify(player, def.name .. " unlocked!", "win")
				task.spawn(runGrants, player)
				return
			end
		end
	end)

	MarketplaceService.ProcessReceipt = processReceipt

	if DEV_GRANT_ALL then
		warn("[PassService] DevGrantAllPasses is set — every pass reads as owned this session.")
	end
	if RunService:IsStudio() and not receiptStore then
		print("[PassService] No receipt datastore; product purchases will not be de-duplicated.")
	end
end

return PassService
