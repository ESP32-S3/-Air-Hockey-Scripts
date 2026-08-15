local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FX        = require(Shared:WaitForChild("FX"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local InputController = {}

local function getMouseWorldOnPlane(y: number): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then return nil end

	local mousePos = UserInputService:GetMouseLocation()
	local ray      = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	local origin   = ray.Origin
	local dir      = ray.Direction

	if math.abs(dir.Y) < 1e-4 then return nil end

	local t = (y - origin.Y) / dir.Y
	if t <= 0 then return nil end

	return origin + dir * t
end

-- The play surface height differs per table (PuckService publishes it as an
-- attribute), so the mouse ray has to be cast against that plane, not a global.
local function getPlaneY(player: Player): number
	local tableName = player:GetAttribute("AirHockeyTable")
	if typeof(tableName) == "string" then
		local tableModel = workspace:FindFirstChild(tableName)
		local y = tableModel and tableModel:GetAttribute("PlayPlaneY")
		if typeof(y) == "number" then return y end
	end
	return Constants.PADDLE_OFFSET_Y
end

function InputController.init()
	local player = Players.LocalPlayer
	local sendAccumulator = 0
	local matchState = FX.STATE_WAITING

	Remotes.State.OnClientEvent:Connect(function(state: string)
		matchState = state
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		if not FX.isPlayingState(matchState) then return end

		local worldPos = getMouseWorldOnPlane(getPlaneY(player))
		if not worldPos then return end

		sendAccumulator += dt
		if sendAccumulator < Constants.SEND_RATE then return end
		sendAccumulator = 0

		Remotes.PaddleTarget:FireServer(worldPos)
	end)
end

return InputController