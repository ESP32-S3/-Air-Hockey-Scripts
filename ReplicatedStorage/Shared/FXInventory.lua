-- FXInventory: codec, validation, and snapshot helpers for the FX catalog.
-- Live state lives in FXInventoryService (server) and InventoryClient (client).

local HttpService = game:GetService("HttpService")
local FXCatalog = require(script.Parent:WaitForChild("FXCatalog"))
local FX = require(script.Parent:WaitForChild("FX"))

-- Forward declarations: the attribute codec above the helpers needs these, and
-- the helpers need the catalog, so neither can simply come first.
local slotIsValid, addOwnedId

local FXInventory = {}

-- No HitSFX: the paddle hit sound is fixed game audio, not an owned item. Slots
-- missing from saved data are ignored on decode, so old records carrying one
-- simply drop it.
local SLOTS = { "GoalSFX", "GoalVFX", "WinSFX" }
FXInventory.SLOTS = SLOTS
FXInventory.ATTR_OWNED = FX.ATTR_OWNED
FXInventory.ATTR_EQUIPPED = FX.ATTR_EQUIPPED

-- The engine caps attribute string values at 50 characters under server
-- authority. Ownership used to be mirrored as a comma-joined id list
-- ("bass,cheer,default"), which silently truncated once a slot held more than
-- a handful of items — with 20 cosmetics per slot a player would lose things
-- they had paid for. Ownership is now packed into a bitmask keyed on each
-- entry's catalog order and written in base 36, which keeps a 20 item slot to
-- four characters and leaves room for a hundred more.
--
-- JSON is still used for the datastore record and teleport payloads, which
-- have no such cap and stay id-keyed so saves survive any catalog reshuffle.
local BITS_PER_CHUNK = 20
local BASE36_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
-- Packed values carry a marker because a legacy id list is not distinguishable
-- from base 36 on its own: tonumber("default", 36) is a perfectly valid
-- number, so sniffing for a comma would misread a single-item legacy value.
local PACKED_PREFIX = "#"

local function ownedAttrName(slot: string): string
	return FX.ATTR_OWNED .. "_" .. slot
end

local function equippedAttrName(slot: string): string
	return FX.ATTR_EQUIPPED .. "_" .. slot
end

local function toBase36(value: number): string
	if value <= 0 then
		return "0"
	end
	local out = ""
	while value > 0 do
		local digit = value % 36
		out = string.sub(BASE36_DIGITS, digit + 1, digit + 1) .. out
		value = math.floor(value / 36)
	end
	return out
end

-- Chunked so the mask never has to survive a round trip through a float:
-- 20 bits per chunk stays well inside exact integer range.
local function bitSlot(order: number): (number, number)
	local index = math.max((order or 1) - 1, 0)
	return math.floor(index / BITS_PER_CHUNK) + 1, index % BITS_PER_CHUNK
end

local function packOwned(slot: string, ownedForSlot): string
	local chunks: { number } = {}
	local highest = 0
	for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
		if ownedForSlot and ownedForSlot[entry.id] then
			local chunkIndex, bit = bitSlot(entry.order)
			chunks[chunkIndex] = bit32.bor(chunks[chunkIndex] or 0, bit32.lshift(1, bit))
			highest = math.max(highest, chunkIndex)
		end
	end

	local parts = {}
	for index = 1, highest do
		table.insert(parts, toBase36(chunks[index] or 0))
	end
	return PACKED_PREFIX .. table.concat(parts, ":")
end

local function unpackOwned(slot: string, packed: string, owned)
	local chunks: { number } = {}
	local count = 0
	for piece in string.gmatch(string.sub(packed, #PACKED_PREFIX + 1), "[^:]+") do
		count += 1
		chunks[count] = tonumber(piece, 36) or 0
	end

	for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
		local chunkIndex, bit = bitSlot(entry.order)
		local chunk = chunks[chunkIndex]
		if chunk and bit32.band(chunk, bit32.lshift(1, bit)) ~= 0 then
			if slotIsValid(slot) then
				owned[slot][entry.id] = true
			end
		end
	end
end

function slotIsValid(slot: string): boolean
	for _, candidate in ipairs(SLOTS) do
		if candidate == slot then
			return true
		end
	end
	return false
end

function addOwnedId(owned, slot: string, id: string)
	if slotIsValid(slot) and typeof(id) == "string" and FXCatalog.getEntry(slot, id) then
		owned[slot][id] = true
	end
end

local function buildDefaultOwned()
	local owned = {}
	for _, slot in ipairs(SLOTS) do
		owned[slot] = {}
		for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
			if entry.defaultOwned then
				owned[slot][entry.id] = true
			end
		end
	end
	return owned
end

local function buildDefaultEquipped()
	return FXCatalog.getDefaultEquipped()
end

local function buildSlotSnapshot(slot: string, owned, equippedId: string)
	local all = {}
	local ownedItems = {}
	local unownedItems = {}

	for _, entry in ipairs(FXCatalog.getAllForSlot(slot)) do
		local isOwned = owned[slot] and owned[slot][entry.id] == true
		local isEquipped = equippedId == entry.id
		local record = {
			id = entry.id,
			slot = slot,
			displayName = entry.displayName,
			description = entry.description or "",
			rarity = entry.rarity,
			order = entry.order,
			price = entry.price or 0,
			defaultOwned = entry.defaultOwned == true,
			owned = isOwned,
			equipped = isEquipped,
			canBuy = not isOwned and not entry.defaultOwned and (entry.price or 0) > 0,
		}

		table.insert(all, record)
		if isOwned then
			table.insert(ownedItems, record)
		else
			table.insert(unownedItems, record)
		end
	end

	return {
		all = all,
		owned = ownedItems,
		unowned = unownedItems,
		equippedId = equippedId,
	}
end

function FXInventory.defaultOwned()
	return buildDefaultOwned()
end

function FXInventory.defaultEquipped()
	return buildDefaultEquipped()
end

function FXInventory.sanitizeOwned(rawOwned)
	local owned = buildDefaultOwned()
	if typeof(rawOwned) ~= "table" then
		return owned
	end

	for _, slot in ipairs(SLOTS) do
		local bucket = rawOwned[slot]
		if typeof(bucket) == "table" then
			for key, value in pairs(bucket) do
				if typeof(key) == "number" and typeof(value) == "string" then
					addOwnedId(owned, slot, value)
				elseif typeof(key) == "string" and value then
					addOwnedId(owned, slot, key)
				end
			end
		elseif typeof(bucket) == "string" then
			addOwnedId(owned, slot, bucket)
		end
	end

	return owned
end

function FXInventory.sanitizeEquipped(owned, rawEquipped)
	local equipped = buildDefaultEquipped()
	if typeof(rawEquipped) ~= "table" then
		return equipped
	end

	for _, slot in ipairs(SLOTS) do
		local id = rawEquipped[slot]
		if typeof(id) == "string" and FXCatalog.getEntry(slot, id) and owned[slot] and owned[slot][id] then
			equipped[slot] = id
		end
	end

	return equipped
end

function FXInventory.encodeOwned(owned): string
	local out = {}
	for _, slot in ipairs(SLOTS) do
		out[slot] = {}
		for id in pairs((owned and owned[slot]) or {}) do
			table.insert(out[slot], id)
		end
		table.sort(out[slot])
	end
	return HttpService:JSONEncode(out)
end

function FXInventory.encodeEquipped(equipped): string
	return HttpService:JSONEncode(equipped or buildDefaultEquipped())
end

function FXInventory.decodeOwned(raw: string?)
	if typeof(raw) ~= "string" or raw == "" then
		return buildDefaultOwned()
	end

	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(data) ~= "table" then
		return buildDefaultOwned()
	end

	return FXInventory.sanitizeOwned(data)
end

function FXInventory.decodeEquipped(raw: string?)
	local equipped = buildDefaultEquipped()
	if typeof(raw) ~= "string" or raw == "" then
		return equipped
	end

	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(data) ~= "table" then
		return equipped
	end

	for _, slot in ipairs(SLOTS) do
		local id = data[slot]
		if typeof(id) == "string" and FXCatalog.getEntry(slot, id) then
			equipped[slot] = id
		end
	end

	return equipped
end

function FXInventory.buildSnapshot(owned, equipped)
	local normalizedOwned = FXInventory.sanitizeOwned(owned)
	local normalizedEquipped = FXInventory.sanitizeEquipped(normalizedOwned, equipped)

	local slots = {}
	local allItems = {}
	local ownedItems = {}
	local unownedItems = {}

	for _, slot in ipairs(SLOTS) do
		local slotSnapshot = buildSlotSnapshot(slot, normalizedOwned, normalizedEquipped[slot])
		slots[slot] = slotSnapshot
		allItems[slot] = slotSnapshot.all
		ownedItems[slot] = slotSnapshot.owned
		unownedItems[slot] = slotSnapshot.unowned
	end

	return {
		owned = normalizedOwned,
		equipped = normalizedEquipped,
		slots = slots,
		allItems = allItems,
		ownedItems = ownedItems,
		unownedItems = unownedItems,
	}
end

function FXInventory.getSnapshotFromAttributes(player: Player)
	local owned = FXInventory.readPlayerOwned(player)
	return FXInventory.buildSnapshot(owned, FXInventory.readPlayerEquipped(player, owned))
end

function FXInventory.writePlayerAttributes(player: Player, owned, equipped)
	local normalizedOwned = FXInventory.sanitizeOwned(owned)
	local normalizedEquipped = FXInventory.sanitizeEquipped(normalizedOwned, equipped)

	for _, slot in ipairs(SLOTS) do
		player:SetAttribute(ownedAttrName(slot), packOwned(slot, normalizedOwned[slot]))
		player:SetAttribute(equippedAttrName(slot), normalizedEquipped[slot] or FXCatalog.getDefaultId(slot))
	end
end

function FXInventory.readPlayerOwned(player: Player)
	local owned = buildDefaultOwned()
	for _, slot in ipairs(SLOTS) do
		local raw = player:GetAttribute(ownedAttrName(slot))
		if typeof(raw) == "string" and raw ~= "" then
			if string.sub(raw, 1, #PACKED_PREFIX) == PACKED_PREFIX then
				unpackOwned(slot, raw, owned)
			else
				-- Legacy comma-joined id list from before the bitmask codec.
				for id in string.gmatch(raw, "[^,]+") do
					addOwnedId(owned, slot, id)
				end
			end
		end
	end
	return owned
end

function FXInventory.readPlayerEquipped(player: Player, owned)
	local equipped = buildDefaultEquipped()
	for _, slot in ipairs(SLOTS) do
		local id = player:GetAttribute(equippedAttrName(slot))
		if typeof(id) == "string" and FXCatalog.getEntry(slot, id) then
			equipped[slot] = id
		end
	end
	return FXInventory.sanitizeEquipped(owned or FXInventory.readPlayerOwned(player), equipped)
end

function FXInventory.ensureDefaults(player: Player)
	local complete = true
	for _, slot in ipairs(SLOTS) do
		if typeof(player:GetAttribute(ownedAttrName(slot))) ~= "string"
			or typeof(player:GetAttribute(equippedAttrName(slot))) ~= "string"
		then
			complete = false
			break
		end
	end

	local snapshot = FXInventory.getSnapshotFromAttributes(player)
	if not complete then
		FXInventory.writePlayerAttributes(player, snapshot.owned, snapshot.equipped)
	end
	return snapshot
end

function FXInventory.fromTeleportData(data: any): (string?, string?)
	if typeof(data) ~= "table" then
		return nil, nil
	end

	local rawOwned = data[FX.ATTR_OWNED] or data.fxOwned
	local rawEquipped = data[FX.ATTR_EQUIPPED] or data.fxEquipped

	if typeof(rawOwned) == "table" then
		rawOwned = HttpService:JSONEncode(rawOwned)
	end
	if typeof(rawEquipped) == "table" then
		rawEquipped = HttpService:JSONEncode(rawEquipped)
	end

	return typeof(rawOwned) == "string" and rawOwned or nil,
		typeof(rawEquipped) == "string" and rawEquipped or nil
end

function FXInventory.applyFromTeleportData(player: Player, data: any)
	local rawOwned, rawEquipped = FXInventory.fromTeleportData(data)
	if not rawOwned and not rawEquipped then
		return nil
	end

	local snapshot = FXInventory.buildSnapshot(
		FXInventory.decodeOwned(rawOwned),
		FXInventory.decodeEquipped(rawEquipped)
	)
	FXInventory.writePlayerAttributes(player, snapshot.owned, snapshot.equipped)
	return snapshot
end

function FXInventory.getOwned(player: Player)
	return FXInventory.readPlayerOwned(player)
end

function FXInventory.getEquipped(player: Player)
	return FXInventory.readPlayerEquipped(player)
end

function FXInventory.getDefaultEquippedJson()
	return FXInventory.encodeEquipped(FXInventory.defaultEquipped())
end

function FXInventory.getDefaultOwnedJson()
	return FXInventory.encodeOwned(FXInventory.defaultOwned())
end

return FXInventory
