local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local FX        = require(Shared:WaitForChild("FX"))
local Remotes   = require(Shared:WaitForChild("Remotes"))

-- hooks (all optional):
--   onStateChanged(state)
--   onGoal(scoringTeam, scores)
--   onMatchEnd(winnerRole, scores, reason)   reason = "score" | "forfeit"
--   getLoadout(player) -> { [slot]: id }     equipped cosmetics, for FX
local function createMatchService(puckService, scoreService, getPlayer: (string) -> Player?, hasAnyPlayers: () -> boolean, hooks)

	hooks = hooks or {}

	local state        = Constants.STATE_WAITING
	local roundRunning = false
	local goalDebounce = false
	local matchEnded   = false

	local function fireAll(remote, ...)
		for _, role in ipairs({"Blue", "Orange"}) do
			local pl = getPlayer(role)
			if pl then remote:FireClient(pl, ...) end
		end
	end

	-- The scorer's cosmetics are resolved here and sent to both seats, so a
	-- bought effect is seen by the person it was bought to impress. Clients only
	-- know their own inventory, so this cannot be decided client-side.
	local function loadoutFor(role: string?)
		if not (role and hooks.getLoadout) then
			return nil
		end
		local player = getPlayer(role)
		if not player then
			return nil
		end
		local ok, loadout = pcall(hooks.getLoadout, player)
		if ok and typeof(loadout) == "table" then
			return loadout
		end
		return nil
	end

	local function setState(s: string)
		state = s
		fireAll(Remotes.State, s)
		if hooks.onStateChanged then hooks.onStateChanged(s) end
	end

	local service = {}

	function service.init()
		setState(Constants.STATE_WAITING)
	end

	function service.getState() return state end

	function service.startRound()
		if roundRunning or not hasAnyPlayers() or matchEnded then return end
		roundRunning = true
		goalDebounce = false
		setState(Constants.STATE_COUNTDOWN)
		puckService.reset()
		fireAll(Remotes.Countdown, Constants.COUNTDOWN)
		task.wait(Constants.COUNTDOWN)
		-- Someone may have walked out (or won by forfeit) during the countdown.
		if matchEnded then
			roundRunning = false
			return
		end
		if not hasAnyPlayers() then
			roundRunning = false
			setState(Constants.STATE_WAITING)
			return
		end
		setState(Constants.STATE_PLAYING)
	end

	-- Ends the match for good. `reason` distinguishes a clean 7-goal win from a
	-- walkout, which matters for how the pot is settled.
	local function finish(winnerRole: string, reason: string)
		if matchEnded then return end
		matchEnded   = true
		goalDebounce = false
		roundRunning = false

		local finalScores = scoreService.getScores()
		fireAll(Remotes.FX, FX.KIND_WIN, winnerRole, loadoutFor(winnerRole))
		setState(Constants.STATE_MATCH_OVER)

		if hooks.onMatchEnd then
			hooks.onMatchEnd(winnerRole, finalScores, reason)
		end
	end

	function service.onGoal(scoringTeam: string)
		if goalDebounce or state ~= Constants.STATE_PLAYING then return end
		goalDebounce = true
		setState(Constants.STATE_GOAL)
		local isWin = scoreService.add(scoringTeam)
		fireAll(Remotes.FX, FX.KIND_GOAL, scoringTeam, loadoutFor(scoringTeam))
		if hooks.onGoal then hooks.onGoal(scoringTeam, scoreService.getScores()) end
		puckService.reset()
		if isWin then
			finish(scoringTeam, "score")
		else
			task.wait(Constants.GOAL_PAUSE)
			goalDebounce = false
			roundRunning = false
			setState(Constants.STATE_WAITING)
			if hasAnyPlayers() then task.spawn(service.startRound) end
		end
	end

	-- Called when a seat empties. Mid-match this is a forfeit: whoever is still
	-- standing on their pad takes the pot.
	function service.onPlayerLeft(leaverRole: string?)
		puckService.reset()
		roundRunning = false
		goalDebounce = false
		if matchEnded then
			setState(Constants.STATE_MATCH_OVER)
			return
		end

		if leaverRole then
			local otherRole = leaverRole == "Blue" and "Orange" or "Blue"
			if getPlayer(otherRole) then
				finish(otherRole, "forfeit")
				return
			end
		end

		setState(Constants.STATE_WAITING)
		if hasAnyPlayers() then task.spawn(service.startRound) end
	end

	function service.isEnded() return matchEnded end

	return service
end

return { create = createMatchService }