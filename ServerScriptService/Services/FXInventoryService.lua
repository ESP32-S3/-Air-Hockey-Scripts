local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FX = require(Shared:WaitForChild("FX"))
local FXCatalog = require(Shared:WaitForChild("FXCatalog"))
local FXInventory = require(Shared:WaitForChild("FXInventory"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local FXPlayer = require(Shared:WaitForChild("FXPlayer"))
local VFXLibrary = require(Shared:WaitForChild("VFXLibrary"))
local EconomyService = require(script.Parent:WaitForChild("EconomyService"))
local PassService = require(script.Parent:WaitForChild("PassService"))

local FXInventoryService = {}

-- Everything is unlocked in Studio so cosmetics can be checked without
-- grinding for them. This is a session-only overlay: savePlayerState refuses
-- to write while it is active, because Studio talks to the *live* datastore
-- and silently persisting 46 granted items would hand them to the real account.
local DEV_GRANT_ALL = RunService:IsStudio() or game:GetAttribute("DevGrantAllInventory") == true
local DATASTORE_NAME = "AH_FXInventory_v1"
local MESSAGE_TOPIC = "AH_FXInventoryChanged_v1"
local SCHEMA_VERSION = 1

local dataStore = nil
pcall(function()
	dataStore = DataStoreService:GetDataStore(DATASTORE_NAME)
end)

local stateByUserId = {}
local saveQueuedByUserId = {}

-- ── FX Collector pass overlay ────────────────────────────────────────────────
-- The pass hands over every legendary in the two effect slots. That is kept as
-- an overlay rather than written into state.owned, for the same reason the
-- Studio dev grant is: state.owned is what gets persisted, and baking an
-- entitlement into it would leave the items behind if the pass were ever
-- refunded or revoked. Everything that reads ownership goes through
-- ownedWithPasses(); everything that writes still writes earned items only.

local PASS_GRANT_SLOTS = { "GoalVFX", "WinSFX" }

local passGrantIds: { [string]: { string } } = {}
for _, slot in ipairs(PASS_GRANT_SLOTS) do
	local ids = {}
	for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
		if entry.rarity == VFXLibrary.RARITY_LEGENDARY then
			table.insert(ids, entry.id)
		end
	end
	passGrantIds[slot] = ids
end

-- Defined below cloneOwned, which it needs; declared here so the readers
-- further down are not reading a global.
local ownedWithPasses

local function cloneOwned(owned)
	local copy = {}
	for slot, bucket in pairs(owned or {}) do
		copy[slot] = {}
		for id, value in pairs(bucket) do
			if value then
				copy[slot][id] = true
			end
		end
	end
	return copy
end

local function cloneEquipped(equipped)
	local copy = {}
	for slot, id in pairs(equipped or {}) do
		copy[slot] = id
	end
	return copy
end

function ownedWithPasses(player: Player, owned)
	if not PassService.owns(player, "FXCollector") then
		return owned
	end

	local merged = cloneOwned(owned)
	for slot, ids in pairs(passGrantIds) do
		merged[slot] = merged[slot] or {}
		for _, id in ipairs(ids) do
			merged[slot][id] = true
		end
	end
	return merged
end

local function buildDefaultState()
	return FXInventory.buildSnapshot(FXInventory.defaultOwned(), FXInventory.defaultEquipped())
end

local function applyGrantAll(state)
	for _, slot in ipairs(FXInventory.SLOTS) do
		state.owned[slot] = state.owned[slot] or {}
		for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
			state.owned[slot][entry.id] = true
		end
	end
	-- Equipped is deliberately left alone. Resetting it here would throw away
	-- the selection on every Studio run, which is exactly the thing you are
	-- usually trying to look at.
end

local function toRecord(state, version)
	return {
		schemaVersion = SCHEMA_VERSION,
		version = version,
		updatedAt = os.time(),
		writerJobId = game.JobId,
		owned = cloneOwned(state.owned),
		equipped = cloneEquipped(state.equipped),
	}
end

local function fromRecord(record)
	if typeof(record) ~= "table" then
		return buildDefaultState(), 0
	end

	local snapshot = FXInventory.buildSnapshot(record.owned, record.equipped)
	return snapshot, tonumber(record.version) or 0
end

local function getTeleportSnapshot(player: Player)
	local ok, teleportData = pcall(function()
		return TeleportService:GetPlayerTeleportData(player)
	end)
	if not ok or typeof(teleportData) ~= "table" then
		return nil
	end

	local rawOwned, rawEquipped = FXInventory.fromTeleportData(teleportData)
	if not rawOwned and not rawEquipped then
		return nil
	end

	return FXInventory.buildSnapshot(
		FXInventory.decodeOwned(rawOwned),
		FXInventory.decodeEquipped(rawEquipped)
	)
end

local function syncPlayer(player: Player)
	local state = stateByUserId[player.UserId]
	if not state then
		return
	end

	local owned = ownedWithPasses(player, state.owned)
	FXInventory.writePlayerAttributes(player, owned, state.equipped)
	Remotes.InventorySync:FireClient(player, FXInventory.buildSnapshot(owned, state.equipped))
end

local function publishUpdate(userId: number, state)
	if not dataStore then
		return
	end

	local payload = toRecord(state, state.version or 0)
	payload.userId = userId

	pcall(function()
		MessagingService:PublishAsync(MESSAGE_TOPIC, payload)
	end)
end

local function loadPlayerState(player: Player)
	local state = nil
	local version = 0

	if dataStore then
		local ok, stored = pcall(function()
			return dataStore:GetAsync(tostring(player.UserId))
		end)
		if ok and typeof(stored) == "table" then
			state, version = fromRecord(stored)
		end
	end

	if not state then
		state = buildDefaultState()
	end

	local teleportSnapshot = getTeleportSnapshot(player)
	if teleportSnapshot then
		state = teleportSnapshot
	end

	if DEV_GRANT_ALL then
		applyGrantAll(state)
	end

	stateByUserId[player.UserId] = {
		owned = cloneOwned(state.owned),
		equipped = cloneEquipped(state.equipped),
		version = version,
		devGranted = DEV_GRANT_ALL,
	}

	syncPlayer(player)
	return stateByUserId[player.UserId]
end

local function savePlayerState(userId: number)
	local state = stateByUserId[userId]
	if not state or not dataStore then
		return false
	end

	-- A dev-granted session must never reach the datastore: the grant is not
	-- something the player earned, and this datastore is shared with live.
	if state.devGranted then
		return false
	end

	local localVersion = tonumber(state.version) or 0
	local savedRecord = nil
	local ok = pcall(function()
		savedRecord = dataStore:UpdateAsync(tostring(userId), function(old)
			local oldVersion = typeof(old) == "table" and tonumber(old.version) or 0
			if oldVersion > localVersion then
				return old
			end

			return toRecord(state, math.max(oldVersion, localVersion) + 1)
		end)
	end)

	if not ok or typeof(savedRecord) ~= "table" then
		return false
	end

	local savedVersion = tonumber(savedRecord.version) or 0
	if savedRecord.writerJobId == game.JobId then
		state.version = savedVersion
		publishUpdate(userId, state)
		return true
	end

	local snapshot = FXInventory.buildSnapshot(savedRecord.owned, savedRecord.equipped)
	state.owned = cloneOwned(snapshot.owned)
	state.equipped = cloneEquipped(snapshot.equipped)
	state.version = savedVersion

	local player = Players:GetPlayerByUserId(userId)
	if player then
		syncPlayer(player)
	end

	return true
end

local function queueSave(userId: number)
	if saveQueuedByUserId[userId] then
		return
	end

	saveQueuedByUserId[userId] = true
	task.delay(1, function()
		saveQueuedByUserId[userId] = nil
		if stateByUserId[userId] then
			savePlayerState(userId)
		end
	end)
end

local function adoptRemoteUpdate(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.writerJobId == game.JobId then
		return
	end

	local userId = tonumber(payload.userId)
	local incomingVersion = tonumber(payload.version) or 0
	if not userId or incomingVersion <= 0 then
		return
	end

	local state = stateByUserId[userId]
	if not state or incomingVersion <= (tonumber(state.version) or 0) then
		return
	end

	local snapshot = FXInventory.buildSnapshot(payload.owned, payload.equipped)
	state.owned = cloneOwned(snapshot.owned)
	state.equipped = cloneEquipped(snapshot.equipped)
	state.version = incomingVersion

	local player = Players:GetPlayerByUserId(userId)
	if player then
		syncPlayer(player)
	end
end

function FXInventoryService.getSnapshot(player: Player)
	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	return FXInventory.buildSnapshot(ownedWithPasses(player, state.owned), state.equipped)
end

function FXInventoryService.getOwned(player: Player)
	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	return ownedWithPasses(player, state.owned)
end

function FXInventoryService.getEquipped(player: Player)
	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	return state.equipped
end

function FXInventoryService.isOwned(player: Player, slot: string, id: string): boolean
	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	local owned = ownedWithPasses(player, state.owned)
	return owned[slot] ~= nil and owned[slot][id] == true
end

function FXInventoryService.isEquipped(player: Player, slot: string, id: string): boolean
	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	return state.equipped[slot] == id
end

function FXInventoryService.equip(player: Player, slot: string, id: string)
	if typeof(slot) ~= "string" or typeof(id) ~= "string" then
		return false, "invalid_args"
	end

	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	if not FXCatalog.getEntry(slot, id) then
		return false, "invalid_item"
	end
	local owned = ownedWithPasses(player, state.owned)
	if not owned[slot] or not owned[slot][id] then
		return false, "unowned"
	end
	if state.equipped[slot] == id then
		return true, "already_equipped"
	end

	state.equipped[slot] = id
	syncPlayer(player)
	queueSave(player.UserId)
	return true, "equipped"
end

function FXInventoryService.buy(player: Player, slot: string, id: string)
	if typeof(slot) ~= "string" or typeof(id) ~= "string" then
		return false, "invalid_args"
	end

	local state = stateByUserId[player.UserId] or loadPlayerState(player)
	local entry = FXCatalog.getEntry(slot, id)
	if not entry then
		return false, "invalid_item"
	end
	-- Checked against the merged view, so a Collector never pays cash for
	-- something their pass already gives them.
	local owned = ownedWithPasses(player, state.owned)
	if owned[slot] and owned[slot][id] then
		return false, "owned"
	end

	local price = entry.price or 0
	if not EconomyService.trySpend(player, price, "buy:" .. slot .. "." .. id) then
		return false, "insufficient_cash"
	end

	state.owned[slot] = state.owned[slot] or {}
	state.owned[slot][id] = true

	-- Buying something implies wanting it on.
	state.equipped[slot] = id

	syncPlayer(player)
	queueSave(player.UserId)
	return true, "bought"
end

function FXInventoryService.applyTeleportData(player: Player)
	return loadPlayerState(player)
end

function FXInventoryService.init()
	FXPlayer.bindInventoryAccessor(function(player: Player)
		return FXInventoryService.getEquipped(player)
	end)

	local MESSAGES = {
		equipped = "Equipped!",
		already_equipped = "Already equipped.",
		bought = "Purchased & equipped!",
		unowned = "You don't own that yet.",
		owned = "You already own that.",
		insufficient_cash = "Not enough cash.",
		invalid_item = "That item doesn't exist.",
		invalid_args = "Bad request.",
	}

	local function reply(player: Player, action: string, ok: boolean, code: string, slot: string, id: string)
		Remotes.ShopResult:FireClient(player, {
			action = action,
			ok = ok,
			code = code,
			slot = slot,
			id = id,
			message = MESSAGES[code] or code,
		})
	end

	Remotes.EquipRequest.OnServerEvent:Connect(function(player: Player, slot: string, id: string)
		local ok, code = FXInventoryService.equip(player, slot, id)
		reply(player, "equip", ok, code, slot, id)
	end)

	Remotes.BuyRequest.OnServerEvent:Connect(function(player: Player, slot: string, id: string)
		local ok, code = FXInventoryService.buy(player, slot, id)
		reply(player, "buy", ok, code, slot, id)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		FXInventoryService.applyTeleportData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		saveQueuedByUserId[player.UserId] = nil
		savePlayerState(player.UserId)
		stateByUserId[player.UserId] = nil
	end)

	pcall(function()
		MessagingService:SubscribeAsync(MESSAGE_TOPIC, function(message)
			adoptRemoteUpdate(message.Data)
		end)
	end)

	-- Buying FX Collector mid-session lights up the legendaries immediately.
	PassService.Changed:Connect(function(player: Player, key: string)
		if key == "FXCollector" and stateByUserId[player.UserId] then
			syncPlayer(player)
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		FXInventoryService.applyTeleportData(player)
	end
end

return FXInventoryService
