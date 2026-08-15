-- Client audio/VFX only. UI text/overlays live in UIController.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local FX = require(Shared:WaitForChild("FX"))
local InventoryClient = require(Shared:WaitForChild("InventoryClient"))
local FXPlayer = require(Shared:WaitForChild("FXPlayer"))

local FXController = {}

function FXController.init()
	local player = Players.LocalPlayer
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("AirHockeyUI")

	InventoryClient.bootstrapFromPlayer(player)
	FXPlayer.bindInventoryAccessor(InventoryClient.getEquipped)

	Remotes.InventorySync.OnClientEvent:Connect(function(snapshot)
		InventoryClient.setSnapshot(snapshot)
	end)

	local matchState = FX.STATE_WAITING
	Remotes.State.OnClientEvent:Connect(function(state: string)
		matchState = state
	end)

	-- `variant` is the hit sound name for KIND_HIT, and the scoring player's
	-- equipped loadout for KIND_GOAL / KIND_WIN.
	Remotes.FX.OnClientEvent:Connect(function(kind: string, team: string, variant: any, volumeScale: number?)
		if kind == FX.KIND_HIT and not FX.isPlayingState(matchState) then
			return
		end
		FXPlayer.playForRemoteKind(player, gui, kind, variant, volumeScale, team)
	end)
end

return FXController