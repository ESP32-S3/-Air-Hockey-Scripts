local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FXInventory = require(Shared:WaitForChild("FXInventory"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local InventoryClient = {}

local changedEvent = Instance.new("BindableEvent")
local snapshot = FXInventory.buildSnapshot(FXInventory.defaultOwned(), FXInventory.defaultEquipped())

InventoryClient.Changed = changedEvent.Event

local function getSlot(snapshotTable, slot: string)
	return snapshotTable and snapshotTable.slots and snapshotTable.slots[slot]
end

function InventoryClient.setSnapshot(nextSnapshot)
	if typeof(nextSnapshot) ~= "table" then
		return snapshot
	end

	snapshot = nextSnapshot
	changedEvent:Fire(snapshot)
	return snapshot
end

function InventoryClient.bootstrapFromPlayer(player: Player)
	return InventoryClient.setSnapshot(FXInventory.getSnapshotFromAttributes(player))
end

function InventoryClient.getSnapshot()
	return snapshot
end

function InventoryClient.getEquipped(arg)
	if typeof(arg) == "Instance" and arg:IsA("Player") then
		return snapshot.equipped
	end
	if typeof(arg) == "string" then
		return snapshot.equipped and snapshot.equipped[arg]
	end
	return snapshot.equipped
end

function InventoryClient.getOwned(arg)
	if typeof(arg) == "Instance" and arg:IsA("Player") then
		return snapshot.owned
	end
	if typeof(arg) == "string" then
		return snapshot.owned and snapshot.owned[arg] or {}
	end
	return snapshot.owned
end

function InventoryClient.isOwned(slot: string, id: string): boolean
	return snapshot.owned
		and snapshot.owned[slot] ~= nil
		and snapshot.owned[slot][id] == true
		or false
end

function InventoryClient.isEquipped(slot: string, id: string): boolean
	return snapshot.equipped ~= nil and snapshot.equipped[slot] == id
end

function InventoryClient.getSlotSnapshot(slot: string)
	return getSlot(snapshot, slot)
end

function InventoryClient.getItemsForSlot(slot: string)
	local slotSnapshot = getSlot(snapshot, slot)
	return slotSnapshot and slotSnapshot.all or {}
end

function InventoryClient.getOwnedItemsForSlot(slot: string)
	local slotSnapshot = getSlot(snapshot, slot)
	return slotSnapshot and slotSnapshot.owned or {}
end

function InventoryClient.getUnownedItemsForSlot(slot: string)
	local slotSnapshot = getSlot(snapshot, slot)
	return slotSnapshot and slotSnapshot.unowned or {}
end

function InventoryClient.requestEquip(slot: string, id: string)
	Remotes.EquipRequest:FireServer(slot, id)
end

function InventoryClient.requestBuy(slot: string, id: string)
	Remotes.BuyRequest:FireServer(slot, id)
end

return InventoryClient