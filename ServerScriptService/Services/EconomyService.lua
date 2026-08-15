-- EconomyService
-- Single source of truth for player Cash.
--   * persisted in a DataStore (best-effort; falls back to session-only in Studio)
--   * also persists a small `meta` table alongside the balance, for the one-shot
--     and once-per-day monetization grants (see PassService). Those need to
--     remember something across sessions and it would be silly to open a second
--     datastore for two scalars that are already written on every cash change.
--   * mirrored onto the player as the "Cash" attribute (read by FXInventoryService)
--   * mirrored into leaderstats so it shows on the player list
--   * pushed to the client through Remotes.CashSync
--
-- Everything that moves money (wagers, shop purchases) must go through here so
-- there is exactly one place that can create or destroy currency.

local Players          = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local EconomyService = {}

local DATASTORE_NAME = "AH_Cash_v1"
local AUTOSAVE_SECONDS = 60

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore(DATASTORE_NAME)
end)

local cashByUserId: { [number]: number } = {}
local metaByUserId: { [number]: { [string]: any } } = {}
local dirtyByUserId: { [number]: boolean } = {}
local loadedByUserId: { [number]: boolean } = {}
local loadingByUserId: { [number]: boolean } = {}

local changedEvent = Instance.new("BindableEvent")
EconomyService.Changed = changedEvent.Event  -- (player, newCash, delta, reason)

local function clampCash(value: number): number
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function ensureLeaderstats(player: Player): IntValue
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end
	local value = folder:FindFirstChild("Cash")
	if not value then
		value = Instance.new("IntValue")
		value.Name = "Cash"
		value.Parent = folder
	end
	return value :: IntValue
end

local function push(player: Player, delta: number?, reason: string?)
	local cash = cashByUserId[player.UserId] or 0
	player:SetAttribute(Constants.CASH_ATTR, cash)
	ensureLeaderstats(player).Value = cash
	Remotes.CashSync:FireClient(player, cash, delta or 0, reason)
	changedEvent:Fire(player, cash, delta or 0, reason)
end

local function loadPlayer(player: Player)
	if loadedByUserId[player.UserId] then
		return cashByUserId[player.UserId]
	end

	-- The loaded flag is only set *after* the datastore read, so two callers
	-- arriving during that window would both start a read and both write the
	-- stored balance back. Whatever the first caller did with its result in
	-- between — a join-time grant, say — was then silently erased by the second
	-- write. Later callers now wait for the read already in flight instead.
	if loadingByUserId[player.UserId] then
		repeat task.wait() until not loadingByUserId[player.UserId]
		return cashByUserId[player.UserId] or 0
	end
	loadingByUserId[player.UserId] = true

	local cash = Constants.STARTING_CASH
	local meta = {}
	-- Records written before the meta table existed are a bare number. Both
	-- shapes are read so an established player does not get reset to the
	-- starting balance the first time they join after this shipped.
	if store then
		local ok, stored = pcall(function()
			return store:GetAsync(tostring(player.UserId))
		end)
		if ok and typeof(stored) == "number" then
			cash = stored
		elseif ok and typeof(stored) == "table" and typeof(stored.cash) == "number" then
			cash = stored.cash
			if typeof(stored.meta) == "table" then
				meta = stored.meta
			end
		end
	end

	loadingByUserId[player.UserId] = nil

	cashByUserId[player.UserId] = clampCash(cash)
	metaByUserId[player.UserId] = meta
	loadedByUserId[player.UserId] = true
	if player.Parent then
		push(player, 0, "load")
	end
	return cashByUserId[player.UserId]
end

local function savePlayer(userId: number)
	if not store or not dirtyByUserId[userId] then
		return
	end
	local cash = cashByUserId[userId]
	if typeof(cash) ~= "number" then
		return
	end
	local record = { cash = cash, meta = metaByUserId[userId] or {} }
	local ok = pcall(function()
		store:SetAsync(tostring(userId), record)
	end)
	if ok then
		dirtyByUserId[userId] = nil
	end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function EconomyService.get(player: Player): number
	if not loadedByUserId[player.UserId] then
		loadPlayer(player)
	end
	return cashByUserId[player.UserId] or 0
end

-- Adds (or, with a negative amount, removes) cash. Never drops below zero.
function EconomyService.add(player: Player, amount: number, reason: string?): number
	if typeof(amount) ~= "number" or amount == 0 then
		return EconomyService.get(player)
	end
	local before = EconomyService.get(player)
	local after = clampCash(before + amount)
	cashByUserId[player.UserId] = after
	dirtyByUserId[player.UserId] = true
	push(player, after - before, reason)
	return after
end

function EconomyService.canAfford(player: Player, amount: number): boolean
	return EconomyService.get(player) >= (tonumber(amount) or 0)
end

-- Atomic spend. Returns false and changes nothing when the player is short.
function EconomyService.trySpend(player: Player, amount: number, reason: string?): boolean
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return true
	end
	if not EconomyService.canAfford(player, amount) then
		return false
	end
	EconomyService.add(player, -amount, reason)
	return true
end

-- ── Persisted meta ──────────────────────────────────────────────────────────
-- Small scalars only (booleans, timestamps). This rides along with the balance
-- write, so anything large would bloat every save.

function EconomyService.getMeta(player: Player, key: string): any
	if not loadedByUserId[player.UserId] then
		loadPlayer(player)
	end
	local meta = metaByUserId[player.UserId]
	return meta and meta[key]
end

function EconomyService.setMeta(player: Player, key: string, value: any)
	if not loadedByUserId[player.UserId] then
		loadPlayer(player)
	end
	local meta = metaByUserId[player.UserId]
	if not meta then
		meta = {}
		metaByUserId[player.UserId] = meta
	end
	meta[key] = value
	dirtyByUserId[player.UserId] = true
end

function EconomyService.set(player: Player, amount: number, reason: string?): number
	local before = EconomyService.get(player)
	local after = clampCash(amount)
	cashByUserId[player.UserId] = after
	dirtyByUserId[player.UserId] = true
	push(player, after - before, reason)
	return after
end

function EconomyService.init()
	local function onAdded(player: Player)
		ensureLeaderstats(player)
		task.spawn(loadPlayer, player)
	end

	Players.PlayerAdded:Connect(onAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		savePlayer(player.UserId)
		cashByUserId[player.UserId] = nil
		metaByUserId[player.UserId] = nil
		loadedByUserId[player.UserId] = nil
		loadingByUserId[player.UserId] = nil
		dirtyByUserId[player.UserId] = nil
	end)

	game:BindToClose(function()
		for userId in pairs(cashByUserId) do
			savePlayer(userId)
		end
		if RunService:IsStudio() then
			task.wait(0.5)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for userId in pairs(dirtyByUserId) do
				savePlayer(userId)
			end
		end
	end)
end

return EconomyService
