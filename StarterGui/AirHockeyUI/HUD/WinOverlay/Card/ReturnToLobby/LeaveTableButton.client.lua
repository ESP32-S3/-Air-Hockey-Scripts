local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local button = script.Parent

button.MouseButton1Click:Connect(function()
	button.Active = false
	Remotes.LeaveTable:FireServer()
	local overlay = button:FindFirstAncestor("WinOverlay")
	if overlay then overlay.Visible = false end
	task.delay(1, function() button.Active = true end)
end)
