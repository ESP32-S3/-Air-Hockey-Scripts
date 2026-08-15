local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FX = require(Shared:WaitForChild("FX"))
local folder = ReplicatedStorage:WaitForChild("AirHockeyRemotes")

return {
	PaddleTarget = folder:WaitForChild("PaddleTarget"),
	Countdown = folder:WaitForChild("Countdown"),
	State = folder:WaitForChild("State"),
	FX = folder:WaitForChild("FX"),
	Score = folder:WaitForChild("Score"),
	RoleAssign = folder:WaitForChild("RoleAssign"),
	InventorySync = folder:WaitForChild(FX.REMOTE_INVENTORY_SYNC),
	EquipRequest = folder:WaitForChild(FX.REMOTE_EQUIP_REQUEST),
	BuyRequest = folder:WaitForChild(FX.REMOTE_BUY_REQUEST),
	CashSync = folder:WaitForChild("CashSync"),
	ShopResult = folder:WaitForChild("ShopResult"),
	LeaveTable = folder:WaitForChild("LeaveTable"),
	Notify = folder:WaitForChild("Notify"),

	-- Monetization
	PassSync = folder:WaitForChild("PassSync"),          -- S->C  { [passKey]: true }
	LoadoutSync = folder:WaitForChild("LoadoutSync"),    -- S->C  { paddleSkin, title }
	LoadoutRequest = folder:WaitForChild("LoadoutRequest"), -- C->S  (kind, id)
	Emote = folder:WaitForChild("Emote"),                -- C->S  (emoteId) / S->C (role, emoteId)
	Rematch = folder:WaitForChild("Rematch"),            -- C->S  ()
	ClaimTable = folder:WaitForChild("ClaimTable"),      -- C->S  (tableName, action, wager)
}