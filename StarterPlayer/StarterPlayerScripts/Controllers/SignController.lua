-- SignController
-- Turns each table's sign board to face the local camera on every axis.
--
-- The boards are real parts with a SurfaceGui rather than BillboardGuis, so they
-- shrink with distance like anything else in the world instead of holding a
-- constant screen size. Rotation is applied client-side only: an anchored part
-- moved on the client doesn't replicate, so every player gets the board
-- square-on without it spinning for anyone else.

local RunService = game:GetService("RunService")

local SignController = {}

local boards: { BasePart } = {}

local function collect()
	table.clear(boards)
	for _, model in ipairs(workspace:GetChildren()) do
		local signage = model:FindFirstChild("Signage")
		local board = signage and signage:FindFirstChild("Board")
		if board and board:IsA("BasePart") then
			table.insert(boards, board)
		end
	end
end

function SignController.init()
	collect()
	-- Streaming can add or drop whole tables at runtime.
	workspace.ChildAdded:Connect(function() task.defer(collect) end)
	workspace.ChildRemoved:Connect(function() task.defer(collect) end)

	RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera then return end

		local eye = camera.CFrame.Position
		for _, board in ipairs(boards) do
			if board.Parent then
				local pos = board.Position
				local offset = eye - pos
				if offset.Magnitude > 0.01 then
					-- lookAt aims the part's -Z at the camera, which is the Front face
					-- the SurfaceGui is drawn on. Straight up or straight down would
					-- make the default up vector degenerate, so swap it near the poles.
					local up = math.abs(offset.Unit.Y) > 0.999
						and Vector3.new(0, 0, 1)
						or Vector3.new(0, 1, 0)
					board.CFrame = CFrame.lookAt(pos, eye, up)
				end
			end
		end
	end)
end

return SignController
