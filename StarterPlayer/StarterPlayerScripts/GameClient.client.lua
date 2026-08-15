-- GameClient
-- Boots every client controller and tells the server when the character is ready
-- to be seated. Camera/HUD state is driven by player attributes, so there is no
-- role polling here any more.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Controllers = script.Parent:WaitForChild("Controllers")
local CameraController = require(Controllers:WaitForChild("CameraController"))
local UIController = require(Controllers:WaitForChild("UIController"))
local FXController = require(Controllers:WaitForChild("FXController"))
local InputController = require(Controllers:WaitForChild("InputController"))
local ShopController = require(Controllers:WaitForChild("ShopController"))
local SignController = require(Controllers:WaitForChild("SignController"))
local PassController = require(Controllers:WaitForChild("PassController"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

CameraController.init()
-- Before the UI controllers: both the shop and the HUD read entitlements on
-- their first render, and a PassController that has not read the attributes yet
-- reports everything as unowned.
PassController.init()
UIController.init()
FXController.init()
InputController.init()
ShopController.init()
SignController.init()

-- Tell the server the character exists so it can seat us at the pad we're on.
local function announceReady()
	local _ = player.Character or player.CharacterAdded:Wait()
	Remotes.RoleAssign:FireServer()
end

task.defer(announceReady)

-- Seat assignment can arrive before or after a respawn; re-announce either way.
player:GetAttributeChangedSignal("AirHockeyRole"):Connect(function()
	if player:GetAttribute("AirHockeyRole") then
		task.defer(announceReady)
	end
end)