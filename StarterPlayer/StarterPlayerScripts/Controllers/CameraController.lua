-- CameraController
-- Locks the camera to the seat camera of whichever table the player is sitting
-- at, and hands control back the moment they leave it. With several tables in
-- the workspace the table has to be resolved per player, not by a fixed name.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local CameraController = {}

local BIND_NAME = "AirHockeyCamera"
local bound = false
local currentCamPart: BasePart? = nil

local function findTableModel(name: string?): Model?
	if typeof(name) ~= "string" then return nil end
	local found = workspace:FindFirstChild(name)
	return (found and found:IsA("Model")) and found or nil
end

local function seatCamera(tableModel: Model, role: string): BasePart?
	local cameras = tableModel:FindFirstChild("Cameras")
	if not cameras then return nil end
	local part = role == "Blue" and cameras:FindFirstChild("BlueCam") or cameras:FindFirstChild("RedCam")
	return (part and part:IsA("BasePart")) and part or nil
end

function CameraController.release()
	currentCamPart = nil
	if bound then
		RunService:UnbindFromRenderStep(BIND_NAME)
		bound = false
	end
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then camera.CameraSubject = humanoid end
	end
end

function CameraController.attach(tableName: string?, role: string?)
	local tableModel = findTableModel(tableName)
	if not tableModel or (role ~= "Blue" and role ~= "Orange") then
		CameraController.release()
		return
	end

	local camPart = seatCamera(tableModel, role)
	if not camPart then
		CameraController.release()
		return
	end

	currentCamPart = camPart
	local camera = workspace.CurrentCamera
	if not camera then return end
	camera.CameraType = Enum.CameraType.Scriptable

	if bound then return end
	bound = true
	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value, function()
		local part = currentCamPart
		if part and part.Parent then
			workspace.CurrentCamera.CFrame = part.CFrame
		end
	end)
end

-- Follows the server-set attributes, so seating and leaving both "just work".
function CameraController.init()
	local player = Players.LocalPlayer

	local function sync()
		CameraController.attach(player:GetAttribute("AirHockeyTable"), player:GetAttribute("AirHockeyRole"))
	end

	player:GetAttributeChangedSignal("AirHockeyTable"):Connect(sync)
	player:GetAttributeChangedSignal("AirHockeyRole"):Connect(sync)
	player.CharacterAdded:Connect(function()
		task.wait(0.25)
		sync()
	end)
	sync()
end

return CameraController