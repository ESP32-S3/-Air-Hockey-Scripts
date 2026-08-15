-- Catalog of purchasable FX.
--
-- Entries are built from VFXLibrary.META, which is the single source of truth
-- for what exists, what it costs and how rare it is. The catalog used to
-- discover entries by walking the AirHockeyFXPackage folder tree; that let the
-- shop and the actual effects drift apart, so the tree is no longer consulted
-- for these slots. It still holds the fixed paddle-hit Sounds, which FXPlayer
-- reads directly.
--
-- Hit sounds are deliberately not a slot: the paddle hit is fixed game audio,
-- not a cosmetic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

export type FxSlot = "GoalSFX" | "GoalVFX" | "WinSFX"

export type FxEntry = {
	id: string,
	slot: FxSlot,
	displayName: string,
	description: string,
	rarity: string,
	order: number,
	defaultOwned: boolean?,
	price: number?,
	-- GoalSFX only: these entries are a bare licensed sound rather than a recipe.
	soundId: number?,
	volume: number?,
	stopAfter: number?,
}

local FXCatalog = {}

-- Declared before discovery runs: the public fields at the bottom of this file
-- are assigned too late for findAssetsRoot() to see them.
local ASSETS_ROOT_NAMES = { "AirHockeyFXPackage", "AirHockeyFX" }

local SLOT_ORDER: { FxSlot } = { "GoalVFX", "GoalSFX", "WinSFX" }

local bySlotAndId: { [FxSlot]: { [string]: FxEntry } } = {
	GoalSFX = {},
	GoalVFX = {},
	WinSFX = {},
}
local bySlot: { [FxSlot]: { FxEntry } } = {
	GoalSFX = {},
	GoalVFX = {},
	WinSFX = {},
}

-- A GoalVFX or WinSFX row without a matching recipe would sell a player an
-- effect that plays nothing, so those slots are filtered against VFXLibrary.
local function hasBackingRecipe(slot: FxSlot, id: string): boolean
	if slot == "GoalVFX" then
		return VFXLibrary.GOAL[id] ~= nil
	end
	if slot == "WinSFX" then
		return VFXLibrary.WIN[id] ~= nil
	end
	return true
end

for _, slot in ipairs(SLOT_ORDER) do
	for _, row in ipairs(VFXLibrary.META[slot] or {}) do
		if hasBackingRecipe(slot, row.id) then
			local entry: FxEntry = {
				id = row.id,
				slot = slot,
				displayName = row.name,
				description = row.desc or "",
				rarity = row.rarity or VFXLibrary.RARITY_COMMON,
				order = row.order,
				price = row.price or 0,
				defaultOwned = row.defaultOwned == true,
				soundId = row.soundId,
				volume = row.volume,
				stopAfter = row.stopAfter,
			}
			bySlotAndId[slot][entry.id] = entry
			table.insert(bySlot[slot], entry)
		else
			warn(string.format("[FXCatalog] %s.%s has no recipe; hidden from the shop", slot, tostring(row.id)))
		end
	end

	-- Shop order is the rarity ladder, not alphabetical: cheap commons first,
	-- legendaries last, so scrolling the list reads as a progression.
	table.sort(bySlot[slot], function(a, b)
		return (a.order or 0) < (b.order or 0)
	end)
end

function FXCatalog.getEntry(slot: FxSlot, id: string): FxEntry?
	local bucket = bySlotAndId[slot]
	return bucket and bucket[id]
end

function FXCatalog.getAllForSlot(slot: FxSlot): { FxEntry }
	return bySlot[slot] or {}
end

function FXCatalog.getDefaultId(slot: FxSlot): string
	for _, entry in ipairs(bySlot[slot] or {}) do
		if entry.defaultOwned then
			return entry.id
		end
	end
	return (bySlot[slot] and bySlot[slot][1] and bySlot[slot][1].id) or "default"
end

function FXCatalog.getDefaultOwnedIds(): { [FxSlot]: { string } }
	local owned: { [FxSlot]: { string } } = {
		GoalSFX = {},
		GoalVFX = {},
		WinSFX = {},
	}
	for _, slot in ipairs(SLOT_ORDER) do
		for _, entry in ipairs(bySlot[slot]) do
			if entry.defaultOwned then
				table.insert(owned[slot], entry.id)
			end
		end
	end
	return owned
end

function FXCatalog.getSlots(): { FxSlot }
	return { SLOT_ORDER[1], SLOT_ORDER[2], SLOT_ORDER[3] }
end

function FXCatalog.getRarityColor(rarity: string?): Color3
	return VFXLibrary.RARITY_COLORS[rarity or ""] or VFXLibrary.RARITY_COLORS.Common
end

function FXCatalog.getDefaultEquipped(): { [FxSlot]: string }
	return {
		GoalSFX = FXCatalog.getDefaultId("GoalSFX"),
		GoalVFX = FXCatalog.getDefaultId("GoalVFX"),
		WinSFX = FXCatalog.getDefaultId("WinSFX"),
	}
end

function FXCatalog.getPrice(slot: FxSlot, id: string): number
	local entry = FXCatalog.getEntry(slot, id)
	return entry and (entry.price or 0) or 0
end

FXCatalog.ASSETS_ROOT_NAME = ASSETS_ROOT_NAMES[1]
FXCatalog.ASSETS_ROOT_NAMES = ASSETS_ROOT_NAMES

return FXCatalog
