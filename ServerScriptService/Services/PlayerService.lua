-- PlayerService (v3 — per-table)
-- Roles tracked per-table. TableManager calls assignPadRole/releaseRole.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local Remotes           = require(Shared:WaitForChild("Remotes"))

local PlayerService = {}

-- tableKey -> { roleByPlayer, playerByRole, callbacks }
local tables: { [Model]: any } = {}


local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 50
local DEFAULT_JUMP_HEIGHT = 7.2

-- Where a player is put down after leaving a table. Set by TableManager.
local lobbyCFrame: CFrame? = nil

function PlayerService.setLobbyCFrame(cf: CFrame)
	lobbyCFrame = cf
end

local function freezeCharacter(player: Player, role: string, tableModel: Model)
	local cameras = tableModel:WaitForChild("Cameras")
	local camPart = role == "Blue" and cameras:WaitForChild("BlueCam")
		or cameras:WaitForChild("RedCam")
	local char = player.Character or player.CharacterAdded:Wait()
	local hrp  = char:WaitForChild("HumanoidRootPart") :: BasePart
	hrp.Anchored = true
	hrp.CFrame   = camPart.CFrame * CFrame.new(0, 5, 0)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed = 0; hum.JumpPower = 0; hum.JumpHeight = 0 end
end

local positionCharacter = freezeCharacter

-- Undo freezeCharacter. Without this a player who finishes a match stays welded
-- in mid-air above the table forever.
local function thawCharacter(player: Player)
	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed  = DEFAULT_WALK_SPEED
		hum.JumpPower  = DEFAULT_JUMP_POWER
		hum.JumpHeight = DEFAULT_JUMP_HEIGHT
	end
	if hrp then
		hrp.Anchored = false
		if lobbyCFrame then
			hrp.CFrame = lobbyCFrame * CFrame.new(math.random(-6, 6), 0, math.random(-4, 4))
		end
		hrp.AssemblyLinearVelocity  = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
end

PlayerService.thawCharacter = thawCharacter

-- Register table instance with callbacks
function PlayerService.registerTable(tableModel: Model, callbacks: {
	onRoleAssigned:  (Player, string) -> (),
	onPlayerRemoved: (Player, string) -> (),
})
	tables[tableModel] = {
		roleByPlayer = {} :: { [Player]: string },
		playerByRole = { Blue = nil, Orange = nil } :: { [string]: Player? },
		callbacks    = callbacks,
	}
end

function PlayerService.unregisterTable(tableModel: Model)
	tables[tableModel] = nil
end

-- Called by TableManager when pad stepped on
function PlayerService.assignPadRole(tableModel: Model, player: Player, role: string): boolean
	local t = tables[tableModel]
	if not t then return false end
	if t.roleByPlayer[player]  then return false end
	if t.playerByRole[role]    then return false end
	t.roleByPlayer[player] = role
	t.playerByRole[role]   = player
	player:SetAttribute("AirHockeyRole",  role)
	player:SetAttribute("AirHockeyTable", tableModel.Name)
	if t.callbacks.onRoleAssigned then t.callbacks.onRoleAssigned(player, role) end
	return true
end

-- Called by TableManager when pad vacated pre-match
function PlayerService.releaseRole(tableModel: Model, player: Player)
	local t = tables[tableModel]
	if not t then return end
	local role = t.roleByPlayer[player]
	if not role then return end
	t.roleByPlayer[player] = nil
	t.playerByRole[role]   = nil
	player:SetAttribute("AirHockeyRole",  nil)
	player:SetAttribute("AirHockeyTable", nil)
	player:SetAttribute("AirHockeyWager", nil)
	thawCharacter(player)
	if t.callbacks.onPlayerRemoved then t.callbacks.onPlayerRemoved(player, role) end
end

-- Releases every player still seated at a table (used when a match wraps up).
function PlayerService.releaseAll(tableModel: Model)
	local t = tables[tableModel]
	if not t then return end
	for _, role in ipairs({ "Blue", "Orange" }) do
		local player = t.playerByRole[role]
		if player then
			t.roleByPlayer[player] = nil
			t.playerByRole[role]   = nil
			player:SetAttribute("AirHockeyRole",  nil)
			player:SetAttribute("AirHockeyTable", nil)
			player:SetAttribute("AirHockeyWager", nil)
			thawCharacter(player)
		end
	end
end

function PlayerService.getTableForPlayer(player: Player): Model?
	for tableModel, t in pairs(tables) do
		if t.roleByPlayer[player] then return tableModel end
	end
	return nil
end

function PlayerService.getRole(tableModel: Model, player: Player): string?
	local t = tables[tableModel]
	return t and t.roleByPlayer[player]
end

function PlayerService.getPlayer(tableModel: Model, role: string): Player?
	local t = tables[tableModel]
	return t and t.playerByRole[role]
end

function PlayerService.hasAnyPlayers(tableModel: Model): boolean
	local t = tables[tableModel]
	if not t then return false end
	return t.playerByRole.Blue ~= nil or t.playerByRole.Orange ~= nil
end

-- RoleAssign remote — client signals character ready → position them
Remotes.RoleAssign.OnServerEvent:Connect(function(player: Player)
	local tableName = player:GetAttribute("AirHockeyTable")
	if not tableName then return end
	local role = player:GetAttribute("AirHockeyRole")
	if not role then return end
	for tableModel in pairs(tables) do
		if tableModel.Name == tableName then
			positionCharacter(player, role, tableModel)
			return
		end
	end
end)

-- Global player removing — release from whichever table they're on
Players.PlayerRemoving:Connect(function(player: Player)
	local tableName = player:GetAttribute("AirHockeyTable")
	if not tableName then return end
	for tableModel, t in pairs(tables) do
		if tableModel.Name == tableName then
			local role = t.roleByPlayer[player]
			if role then
				t.roleByPlayer[player] = nil
				t.playerByRole[role]   = nil
				if t.callbacks.onPlayerRemoved then
					t.callbacks.onPlayerRemoved(player, role)
				end
			end
			return
		end
	end
end)

return PlayerService