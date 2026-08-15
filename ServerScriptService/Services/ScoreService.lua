local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

local function createScoreService(getPlayer: (string) -> Player?)
	local scores = { Blue = 0, Orange = 0 }

	local function fire()
		if not Remotes.Score then return end
		local payload = { Blue = scores.Blue, Orange = scores.Orange }
		for _, role in ipairs({"Blue", "Orange"}) do
			local pl = getPlayer(role)
			if pl then Remotes.Score:FireClient(pl, payload) end
		end
	end

	local service = {}

	function service.add(team: string): boolean
		if team ~= "Blue" and team ~= "Orange" then return false end
		scores[team] += 1
		fire()
		return scores[team] >= Constants.GOAL_WIN_SCORE
	end

	function service.reset()
		scores.Blue = 0; scores.Orange = 0
		fire()
	end

	function service.broadcast() fire() end

	function service.getScores()
		return { Blue = scores.Blue, Orange = scores.Orange }
	end

	return service
end

return { create = createScoreService }