local GameState = {}

GameState.State = "Waiting"

GameState.Changed = Instance.new("BindableEvent")

function GameState:Get()
	return self.State
end

function GameState:Set(newState)
	if self.State == newState then
		return
	end

	self.State = newState
	self.Changed:Fire(newState)
end

function GameState:OnChanged(callback)
	return self.Changed.Event:Connect(callback)
end

function GameState:Is(state)
	return self.State == state
end

return GameState