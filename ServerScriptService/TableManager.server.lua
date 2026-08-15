-- TableManager (multi-table, wagered)
-- Scans workspace for any Model with Pads/BluePad + Pads/OrangePad.
-- Spins up isolated PuckService/PaddleService/ScoreService/MatchService per table.
-- TableManager owns the heartbeat tick, the wager escrow, and the signage.
--
-- Money flow for one match:
--   both pads filled -> both stakes debited into a pot (escrow)
--   someone wins     -> pot paid to the winner
--   someone walks    -> forfeit, pot paid to whoever is left
--   nobody is left   -> pot refunded to whoever paid in

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Services       = script.Parent:WaitForChild("Services")
local PlayerService  = require(Services:WaitForChild("PlayerService"))
local PuckModule     = require(Services:WaitForChild("PuckService"))
local PaddleModule   = require(Services:WaitForChild("PaddleService"))
local ScoreModule    = require(Services:WaitForChild("ScoreService"))
local MatchModule    = require(Services:WaitForChild("MatchService"))
local FXInvService   = require(Services:WaitForChild("FXInventoryService"))
local EconomyService = require(Services:WaitForChild("EconomyService"))
local PassService    = require(Services:WaitForChild("PassService"))
local LoadoutService = require(Services:WaitForChild("LoadoutService"))

local Shared   = ReplicatedStorage:WaitForChild("Shared")
local Remotes  = require(Shared:WaitForChild("Remotes"))
local FX       = require(Shared:WaitForChild("FX"))
local Constants = require(Shared:WaitForChild("Constants"))
local Monetization = require(Shared:WaitForChild("Monetization"))
local Extras   = require(Shared:WaitForChild("Extras"))

local activeMatches: { [Model]: any } = {}  -- tableModel -> match context
local watchers: { [Model]: any } = {}       -- tableModel -> watcher handle

local function isTableModel(obj: Instance): boolean
	if not obj:IsA("Model") then return false end
	local p = obj:FindFirstChild("Pads")
	if not p then return false end
	return p:FindFirstChild("BluePad") ~= nil and p:FindFirstChild("OrangePad") ~= nil
end

local function getWager(tableModel: Model): number
	return math.max(0, math.floor(tonumber(tableModel:GetAttribute(Constants.WAGER_ATTR)) or 0))
end

local function getTier(tableModel: Model): string
	local tier = tableModel:GetAttribute(Constants.TIER_ATTR)
	return typeof(tier) == "string" and tier or tableModel.Name
end

-- Solo practice: in Studio, with nobody else in the server, one occupied pad is
-- enough to start. Always free play — no stake is escrowed and nothing is paid
-- out, so a solo test run can never move a player's balance.
local function isSoloAllowed(): boolean
	return RunService:IsStudio() and #Players:GetPlayers() <= 1
end

-- How long a lone player has to stay on the pad before a solo match commits, so
-- walking across a pad doesn't lock them into one.
local SOLO_START_DELAY = 1

local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return "$" .. out
end

local function notify(player: Player?, message: string, kind: string?)
	if player then
		Remotes.Notify:FireClient(player, message, kind or "info")
	end
end

-- ── Seat entitlements ────────────────────────────────────────────────────────

-- IsFriendsWith is a web call. Answering from cache only, and resolving misses
-- in the background, keeps the seat check non-yielding: it runs immediately
-- before the wager escrow, and a yield in there would let two passes through
-- the "is this table free" guard and debit both players twice. The retry loop
-- comes back every 2s, so an unknown pair is admitted a beat later rather than
-- never.
local friendCache: { [string]: boolean } = {}
local friendPending: { [string]: boolean } = {}

local function isFriendOf(player: Player, ownerId: number): boolean
	local key = player.UserId .. ":" .. ownerId
	local cached = friendCache[key]
	if cached ~= nil then return cached end

	if not friendPending[key] then
		friendPending[key] = true
		task.spawn(function()
			local ok, result = pcall(function()
				return player:IsFriendsWith(ownerId)
			end)
			friendCache[key] = ok and result == true
			friendPending[key] = nil
		end)
	end
	return false
end

local function getPrivateOwnerId(tableModel: Model): number?
	local id = tonumber(tableModel:GetAttribute(Monetization.TABLE_ATTR_OWNER))
	if not id or id == 0 then return nil end
	return id
end

-- nil when `player` may take a seat here, otherwise the reason to show them.
local function seatDenialReason(tableModel: Model, player: Player): string?
	local requiredPass = tableModel:GetAttribute(Monetization.TABLE_ATTR_REQUIRES_PASS)
	if typeof(requiredPass) == "string" and requiredPass ~= "" then
		if not PassService.owns(player, requiredPass) then
			local def = Monetization.getPass(requiredPass)
			return (def and def.name or requiredPass) .. " is required for this table."
		end
	end

	local ownerId = getPrivateOwnerId(tableModel)
	if ownerId and ownerId ~= player.UserId and not isFriendOf(player, ownerId) then
		local owner = Players:GetPlayerByUserId(ownerId)
		return owner
			and ("Private table — " .. owner.DisplayName .. "'s friends only.")
			or "This table is private."
	end

	return nil
end

-- ── Golden Puck ─────────────────────────────────────────────────────────────
-- The puck is a permanent child of the table rather than something spawned per
-- match, so the skin has to be reverted when the match ends. Originals are
-- captured the first time a table goes gold and replayed on teardown.

local GOLD_COLOR = Color3.fromRGB(255, 198, 66)
local puckOriginals: { [Model]: { [BasePart]: { any } } } = {}

local function puckParts(tableModel: Model): { BasePart }
	local pieces = tableModel:FindFirstChild("GamePeices")
	local puck = pieces and pieces:FindFirstChild("Puck")
	if not puck then return {} end

	local parts = {}
	if puck:IsA("BasePart") then table.insert(parts, puck) end
	for _, inst in ipairs(puck:GetDescendants()) do
		if inst:IsA("BasePart") then table.insert(parts, inst) end
	end
	return parts
end

local function setGoldenPuck(tableModel: Model, gold: boolean)
	if gold then
		if puckOriginals[tableModel] then return end
		local saved = {}
		for _, part in ipairs(puckParts(tableModel)) do
			saved[part] = { part.Color, part.Material, part.Reflectance }
			part.Color = GOLD_COLOR
			part.Material = Enum.Material.Metal
			part.Reflectance = 0.45
		end
		puckOriginals[tableModel] = saved
	else
		local saved = puckOriginals[tableModel]
		if not saved then return end
		for part, original in pairs(saved) do
			if part.Parent then
				part.Color, part.Material, part.Reflectance = original[1], original[2], original[3]
			end
		end
		puckOriginals[tableModel] = nil
	end
end

-- Both seats hear every impact, so FX always go to the whole table.
local function fireTableFx(tableModel: Model, kind: string, role: string?, variant: string?, volumeScale: number?)
	for _, seat in ipairs({ "Blue", "Orange" }) do
		local player = PlayerService.getPlayer(tableModel, seat)
		if player then
			Remotes.FX:FireClient(player, kind, role, variant, volumeScale)
		end
	end
end

-- Paddle hits are graded on the puck speed they produce rather than on raw
-- paddle velocity: PuckService folds the paddle's motion into that number and
-- bounds it, so it is free of the per-frame jitter a client-driven paddle
-- position carries.
local function fireHitFx(tableModel: Model, role: string, impactSpeed: number)
	local variant = impactSpeed >= Constants.HIT_HARD_SPEED and FX.HIT_HARD or FX.HIT_SOFT
	local scale = FX.getHitVolumeScale(impactSpeed, Constants.PUCK_MIN_HIT_SPEED, Constants.PUCK_MAX_SPEED)
	fireTableFx(tableModel, FX.KIND_HIT, role, variant, scale)
end

local function fireWallFx(tableModel: Model, impactSpeed: number)
	local scale = FX.getHitVolumeScale(impactSpeed, Constants.WALL_HIT_MIN_SPEED, Constants.PUCK_MAX_SPEED)
	fireTableFx(tableModel, FX.KIND_HIT, nil, FX.HIT_WALL, scale)
end

-- ── Signage ────────────────────────────────────────────────────────────────────
local STATUS_COLORS = {
	Open      = Color3.fromRGB(90, 220, 130),
	Waiting   = Color3.fromRGB(255, 205, 80),
	Live      = Color3.fromRGB(255, 95, 95),
	Finished  = Color3.fromRGB(160, 170, 190),
}

local function findSignLabel(tableModel: Model, labelName: string): TextLabel?
	local signage = tableModel:FindFirstChild("Signage")
	if not signage then return nil end
	local found = signage:FindFirstChild(labelName, true)
	return (found and found:IsA("TextLabel")) and found or nil
end

local function refreshSignage(tableModel: Model)
	local ctx = activeMatches[tableModel]
	local wager = getWager(tableModel)
	local solo = ctx ~= nil and ctx.solo == true

	local tierLabel = findSignLabel(tableModel, "Tier")
	if tierLabel then
		local ownerId = getPrivateOwnerId(tableModel)
		local owner = ownerId and Players:GetPlayerByUserId(ownerId) or nil
		local requiredPass = tableModel:GetAttribute(Monetization.TABLE_ATTR_REQUIRES_PASS)
		if owner then
			tierLabel.Text = string.upper(owner.DisplayName) .. "'S TABLE"
		elseif typeof(requiredPass) == "string" and requiredPass ~= "" then
			tierLabel.Text = "VIP · " .. getTier(tableModel)
		else
			tierLabel.Text = getTier(tableModel)
		end
	end

	local wagerLabel = findSignLabel(tableModel, "Wager")
	if wagerLabel then
		if solo then
			wagerLabel.Text = "SOLO PRACTICE · FREE"
		else
			wagerLabel.Text = wager > 0 and (money(wager) .. " each · " .. money(wager * 2) .. " pot") or "FREE PLAY"
		end
	end

	local statusKey = "Open"
	if ctx then
		local state = ctx.match.getState()
		if state == Constants.STATE_MATCH_OVER then
			statusKey = "Finished"
		elseif state == Constants.STATE_WAITING then
			statusKey = "Waiting"
		else
			statusKey = "Live"
		end
	end

	local statusLabel = findSignLabel(tableModel, "Status")
	if statusLabel then
		statusLabel.Text = statusKey == "Open" and "OPEN · STEP ON A PAD" or statusKey:upper()
		statusLabel.TextColor3 = STATUS_COLORS[statusKey] or STATUS_COLORS.Open
	end

	local scoreLabel = findSignLabel(tableModel, "Score")
	if scoreLabel then
		if ctx then
			local s = ctx.score.getScores()
			scoreLabel.Text = string.format("%d  –  %d", s.Blue, s.Orange)
		else
			scoreLabel.Text = "0  –  0"
		end
	end

end

local destroyMatch  -- forward declaration (settle -> destroy)

-- Pays out the escrowed pot. Called exactly once per match.
local function settle(tableModel: Model, winnerRole: string?, reason: string?)
	local ctx = activeMatches[tableModel]
	if not ctx or ctx.settled then return end
	ctx.settled = true

	local pot = ctx.pot or 0
	local stakes = ctx.stakes or {}

	if pot <= 0 then
		ctx.pot = 0
		return
	end

	local winner = winnerRole and ctx.playersByRole[winnerRole] or nil
	if winner and winner.Parent then
		local loserRole = winnerRole == "Blue" and "Orange" or "Blue"
		local loser = ctx.playersByRole[loserRole]
		local consolation = 0

		-- Table Insurance stacks with the house rate rather than replacing it, so
		-- raising Constants.LOSER_REFUND_RATE above the pass value can never leave
		-- a pass holder worse off than a free player.
		local refundRate = Constants.LOSER_REFUND_RATE
		if loser and PassService.owns(loser, "LoserRefund") then
			refundRate = math.max(refundRate, Monetization.LOSER_REFUND_RATE)
		end

		if loser and loser.Parent and refundRate > 0 then
			consolation = math.floor((stakes[loserRole] or 0) * refundRate)
			consolation = math.min(consolation, pot)
			if consolation > 0 then
				EconomyService.add(loser, consolation, "wager_consolation")
				notify(loser, "Insurance paid back " .. money(consolation) .. ".", "info")
			end
		end

		local payout = pot - consolation
		EconomyService.add(winner, payout, "wager_win")

		-- 2x Cash doubles the *profit*, not the pot. Half the pot is the winner's
		-- own stake coming back; multiplying all of it would pay four times the
		-- stake and read as a lie to anyone who does the arithmetic. The bonus is
		-- newly minted rather than taken from the loser, who has already been
		-- settled with above.
		local profit = payout - (stakes[winnerRole] or 0)
		if profit > 0 and PassService.owns(winner, "Cash2x") then
			local bonus = math.floor(profit * (Monetization.CASH_MULTIPLIER - 1))
			if bonus > 0 then
				EconomyService.add(winner, bonus, "pass_cash_multiplier")
				notify(winner, "2x Cash bonus " .. money(bonus) .. "!", "win")
			end
		end

		notify(winner, (reason == "forfeit" and "Opponent left — you win " or "You win ") .. money(payout) .. "!", "win")
		if loser and loser.Parent and consolation <= 0 then
			notify(loser, "You lost " .. money(stakes[loserRole] or 0) .. ".", "lose")
		end
	else
		-- No winner still connected: hand every stake back to whoever paid it.
		for role, amount in pairs(stakes) do
			local player = ctx.playersByRole[role]
			if player and player.Parent and amount > 0 then
				EconomyService.add(player, amount, "wager_refund")
				notify(player, "Match cancelled — " .. money(amount) .. " refunded.", "info")
			end
		end
	end

	ctx.pot = 0
end

-- One of bluePlayer/orangePlayer may be nil: that is a solo practice match, and
-- the empty side simply has no paddle.
local function spawnMatch(tableModel: Model, bluePlayer: Player?, orangePlayer: Player?, stakes, pot: number)
	if activeMatches[tableModel] then return end
	if not (bluePlayer or orangePlayer) then return end

	local solo = (bluePlayer == nil) or (orangePlayer == nil)

	local puck    = PuckModule.create(tableModel)
	local paddle  = PaddleModule.create(tableModel, puck)
	local score   = ScoreModule.create(function(role) return PlayerService.getPlayer(tableModel, role) end)

	local ctx = {
		puck = puck,
		paddle = paddle,
		score = score,
		stakes = stakes,
		pot = pot,
		settled = false,
		solo = solo,
		playersByRole = { Blue = bluePlayer, Orange = orangePlayer },
		-- Instant Rematch needs both seats to agree before either is re-staked.
		rematchReady = { Blue = false, Orange = false },
	}

	local match = MatchModule.create(
		puck, score,
		function(role) return PlayerService.getPlayer(tableModel, role) end,
		function()     return PlayerService.hasAnyPlayers(tableModel)    end,
		{
			onStateChanged = function() refreshSignage(tableModel) end,
			onGoal         = function() refreshSignage(tableModel) end,
			getLoadout     = function(player) return FXInvService.getEquipped(player) end,
			onMatchEnd     = function(winnerRole, _scores, reason)
				settle(tableModel, winnerRole, reason)
				refreshSignage(tableModel)

				-- Leave the win card up briefly, then hand the table back. A seat
				-- with Instant Rematch holds it open much longer, because agreeing
				-- to run it back is not something two people manage in eight
				-- seconds.
				local linger = Constants.MATCH_OVER_LINGER
				for _, seat in ipairs({ "Blue", "Orange" }) do
					local player = ctx.playersByRole[seat]
					if PassService.owns(player, "RematchReady") then
						linger = Monetization.REMATCH_LINGER
						-- Pre-armed: buying the pass is the opt-in, so the holder's
						-- opponent only has to press once. Accepting is deliberately
						-- free — gating the *accept* behind the pass would make a
						-- rematch impossible against anyone who has not bought it,
						-- which is most people.
						ctx.rematchReady[seat] = true
						notify(player, "Instant Rematch armed — LEAVE TABLE to opt out.", "info")

						local otherSeat = seat == "Blue" and "Orange" or "Blue"
						local other = ctx.playersByRole[otherSeat]
						if other then
							notify(other, player.DisplayName .. " is ready to run it back — hit REMATCH.", "info")
							-- Reveals the button for a non-holder: without this they
							-- would be told to press something they cannot see.
							Remotes.Rematch:FireClient(other, true)
						end
					end
				end

				task.delay(linger, function()
					-- A rematch swaps in a fresh context, which makes this pending
					-- teardown stale; without the identity check it would tear down
					-- the *new* match mid-play.
					if activeMatches[tableModel] == ctx then
						destroyMatch(tableModel)
					end
				end)
			end,
		}
	)
	ctx.match = match

	puck.init()
	puck.setGoalHandler(match.onGoal)
	puck.setWallHitHandler(function(impactSpeed)
		fireWallFx(tableModel, impactSpeed)
	end)
	paddle.init()
	match.init()

	PlayerService.registerTable(tableModel, {
		onRoleAssigned = function(player, role)
			paddle.spawnPaddle(role, player)
			score.broadcast()
			refreshSignage(tableModel)
		end,
		onPlayerRemoved = function(_pl, role)
			paddle.removePaddle(role)
			match.onPlayerLeft(role)
			refreshSignage(tableModel)
			-- Nobody left to forfeit to (always the case in solo): the match can
			-- never resume, so hand the table straight back.
			if not PlayerService.hasAnyPlayers(tableModel) and not match.isEnded() then
				task.defer(destroyMatch, tableModel)
			end
		end,
	})

	activeMatches[tableModel] = ctx

	if bluePlayer   then PlayerService.assignPadRole(tableModel, bluePlayer,   "Blue")   end
	if orangePlayer then PlayerService.assignPadRole(tableModel, orangePlayer, "Orange") end

	for _, role in ipairs({ "Blue", "Orange" }) do
		local player = ctx.playersByRole[role]
		if player then
			player:SetAttribute("AirHockeyWager", stakes[role] or 0)
		end
	end

	-- One Golden Puck owner golds the puck for the whole table. Same principle
	-- as the goal effects: a cosmetic bought to be seen is worth nothing if the
	-- opponent can't see it.
	setGoldenPuck(tableModel,
		PassService.owns(bluePlayer, "GoldenPuck") or PassService.owns(orangePlayer, "GoldenPuck"))

	refreshSignage(tableModel)

	-- Deferred so both seats are assigned before the countdown fires; starting it
	-- from onRoleAssigned would send the countdown to Blue only.
	task.defer(match.startRound)

	print("[TableManager] Match spawned on", tableModel.Name, "pot", pot, solo and "(solo)" or "")
end

function destroyMatch(tableModel: Model)
	local ctx = activeMatches[tableModel]
	if not ctx then return end

	-- Anything unsettled at this point had no winner — refund.
	settle(tableModel, nil, "abort")

	ctx.paddle.removePaddle("Blue")
	ctx.paddle.removePaddle("Orange")
	ctx.puck.reset()
	setGoldenPuck(tableModel, false)

	PlayerService.releaseAll(tableModel)
	PlayerService.unregisterTable(tableModel)
	activeMatches[tableModel] = nil

	-- Unlock pads last so nobody can re-seat mid-teardown.
	local pads = tableModel:FindFirstChild("Pads")
	if pads then
		local bp = pads:FindFirstChild("BluePad")
		local op = pads:FindFirstChild("OrangePad")
		if bp then bp:SetAttribute("Locked", false) end
		if op then op:SetAttribute("Locked", false) end
	end

	local watcher = watchers[tableModel]
	if watcher then
		watcher.matchActive = false
		-- Priority Seating: hold the freed table for pass holders for a moment.
		-- Only worth doing when somebody else is actually around to race for it;
		-- on a quiet server this would just be a stall with no beneficiary.
		if #Players:GetPlayers() > 1 then
			watcher.priorityUntil = os.clock() + Monetization.PRIORITY_WINDOW
		end
	end

	refreshSignage(tableModel)
	print("[TableManager] Match destroyed on", tableModel.Name)
end

-- Runs the same two players straight back at the same table, keeping both in
-- their seats. Requires that *both* have pressed REMATCH: a rematch re-stakes
-- the wager, and one player must never be able to spend the other's money.
local function tryRematch(tableModel: Model)
	local ctx = activeMatches[tableModel]
	if not ctx or not ctx.match.isEnded() then return end
	if not (ctx.rematchReady.Blue and ctx.rematchReady.Orange) then return end

	local bp, op = ctx.playersByRole.Blue, ctx.playersByRole.Orange
	if not (bp and op and bp.Parent and op.Parent) then return end

	local wager = ctx.solo and 0 or getWager(tableModel)
	local stakes = { Blue = 0, Orange = 0 }
	local pot = 0

	if wager > 0 then
		for _, player in ipairs({ bp, op }) do
			if not EconomyService.canAfford(player, wager) then
				notify(player, "You can't cover the " .. money(wager) .. " buy-in for a rematch.", "error")
				notify(player == bp and op or bp, "Opponent can't cover a rematch.", "error")
				ctx.rematchReady.Blue, ctx.rematchReady.Orange = false, false
				return
			end
		end
		if not EconomyService.trySpend(bp, wager, "wager_stake") then return end
		if not EconomyService.trySpend(op, wager, "wager_stake") then
			EconomyService.add(bp, wager, "wager_refund")
			return
		end
		stakes.Blue, stakes.Orange = wager, wager
		pot = wager * 2
	end

	-- Torn down without releasing the players: they keep their roles, their
	-- frozen camera position and their locked pads, so the new match starts
	-- where the old one finished instead of walking them back from the lobby.
	ctx.paddle.removePaddle("Blue")
	ctx.paddle.removePaddle("Orange")
	ctx.puck.reset()
	setGoldenPuck(tableModel, false)
	PlayerService.unregisterTable(tableModel)
	activeMatches[tableModel] = nil

	spawnMatch(tableModel, bp, op, stakes, pot)
	notify(bp, "Rematch! " .. (pot > 0 and (money(pot) .. " pot.") or "Free play."), "win")
	notify(op, "Rematch! " .. (pot > 0 and (money(pot) .. " pot.") or "Free play."), "win")
end

-- Heartbeat: tick all active matches
RunService.Heartbeat:Connect(function(dt)
	for tableModel, ctx in pairs(activeMatches) do
		local state = ctx.match.getState()
		ctx.paddle.tick(dt, state, function(role, impactSpeed)
			fireHitFx(tableModel, role, impactSpeed)
		end)
		ctx.puck.tick(state, dt)
	end
end)

-- Watch single table
local function watchTable(tableModel: Model)
	if watchers[tableModel] then return end

	local pads      = tableModel:FindFirstChild("Pads")
	local bluePad   = pads:FindFirstChild("BluePad")
	local orangePad = pads:FindFirstChild("OrangePad")

	local watcher = { matchActive = false }
	watchers[tableModel] = watcher

	local warnedShortAt = 0
	local warnedDeniedAt = 0
	local warnedPriorityAt = 0

	local tryStartMatch
	function tryStartMatch()
		if watcher.matchActive then return end

		local bId = bluePad:GetAttribute("OccupantId")
		local oId = orangePad:GetAttribute("OccupantId")
		if bId and oId and bId == oId then return end

		local bp = bId and Players:GetPlayerByUserId(bId) or nil
		local op = oId and Players:GetPlayerByUserId(oId) or nil

		-- Built as a list rather than iterating { bp, op }: either may be nil, and
		-- ipairs would stop at the hole and silently skip the occupied seat.
		local seated = {}
		if bp then table.insert(seated, bp) end
		if op then table.insert(seated, op) end

		-- VIP Lounge and privately claimed tables. Checked here rather than only
		-- on step-on, because this runs on a retry loop and a table can become
		-- private while somebody is already standing on the pad.
		for _, player in ipairs(seated) do
			local denial = seatDenialReason(tableModel, player)
			if denial then
				if os.clock() - warnedDeniedAt > 6 then
					warnedDeniedAt = os.clock()
					notify(player, denial, "error")
				end
				return
			end
		end

		-- Priority Seating: for a few seconds after this table frees up, only
		-- pass holders may claim it.
		if watcher.priorityUntil and os.clock() < watcher.priorityUntil and #seated > 0 then
			local waiting = {}
			for _, player in ipairs(seated) do
				if not PassService.owns(player, "PrioritySeating") then
					table.insert(waiting, player)
				end
			end
			if #waiting > 0 then
				if os.clock() - warnedPriorityAt > 5 then
					warnedPriorityAt = os.clock()
					local seconds = math.ceil(watcher.priorityUntil - os.clock())
					for _, player in ipairs(waiting) do
						notify(player, "Table reserved for Priority Seating — " .. seconds .. "s.", "info")
					end
				end
				return
			end
		end

		local solo = false
		if bp and op then
			watcher.soloArmedFor = nil  -- normal head-to-head
		elseif (bp or op) and isSoloAllowed() then
			local occupantId = bId or oId
			if watcher.soloArmedFor ~= occupantId then
				watcher.soloArmedFor = occupantId
				watcher.soloArmedAt  = os.clock()
				task.delay(SOLO_START_DELAY, function()
					if watcher.soloArmedFor == occupantId then tryStartMatch() end
				end)
			end
			if os.clock() - watcher.soloArmedAt < SOLO_START_DELAY then return end
			solo = true
		else
			watcher.soloArmedFor = nil
			return
		end

		-- Escrow: both stakes come out up front, so nobody can bet money they
		-- spend in the shop halfway through the match. Solo practice is always
		-- free, so it skips the escrow entirely.
		local wager = solo and 0 or getWager(tableModel)
		local stakes = { Blue = 0, Orange = 0 }
		local pot = 0

		if wager > 0 then
			local short = {}
			if not EconomyService.canAfford(bp, wager) then table.insert(short, bp) end
			if not EconomyService.canAfford(op, wager) then table.insert(short, op) end
			if #short > 0 then
				-- This is retried on a timer, so rate-limit the nagging.
				if os.clock() - warnedShortAt > 6 then
					warnedShortAt = os.clock()
					for _, pl in ipairs(short) do
						notify(pl, "You need " .. money(wager) .. " to play this table.", "error")
					end
					if #short == 1 then
						local other = short[1] == bp and op or bp
						notify(other, "Opponent can't cover the " .. money(wager) .. " buy-in.", "error")
					end
				end
				return
			end

			if not EconomyService.trySpend(bp, wager, "wager_stake") then return end
			if not EconomyService.trySpend(op, wager, "wager_stake") then
				EconomyService.add(bp, wager, "wager_refund")  -- roll back the first debit
				return
			end
			stakes.Blue, stakes.Orange = wager, wager
			pot = wager * 2
			notify(bp, money(wager) .. " staked — " .. money(pot) .. " pot.", "info")
			notify(op, money(wager) .. " staked — " .. money(pot) .. " pot.", "info")
		end

		watcher.matchActive = true
		bluePad:SetAttribute("Locked",   true)
		orangePad:SetAttribute("Locked", true)
		spawnMatch(tableModel, bp, op, stakes, pot)
	end

	local function onOccupantChanged(pad, role)
		if watcher.matchActive then return end  -- match running, pads are locked

		local id = pad:GetAttribute("OccupantId")
		if id then
			local pl = Players:GetPlayerByUserId(id)
			if pl then
				-- Immediate feedback on stepping on: the retry loop would get there
				-- eventually, but a silent pad reads as a bug.
				local denial = seatDenialReason(tableModel, pl)
				if denial then
					notify(pl, denial, "error")
				elseif not isSoloAllowed() then
					local wager = getWager(tableModel)
					if wager > 0 and not EconomyService.canAfford(pl, wager) then
						notify(pl, "This table costs " .. money(wager) .. " to sit at.", "error")
					end
				end
			end
		end

		refreshSignage(tableModel)
		tryStartMatch()
	end

	bluePad:GetAttributeChangedSignal("OccupantId"):Connect(function()
		onOccupantChanged(bluePad, "Blue")
	end)
	orangePad:GetAttributeChangedSignal("OccupantId"):Connect(function()
		onOccupantChanged(orangePad, "Orange")
	end)

	watcher.tryStartMatch = tryStartMatch
	refreshSignage(tableModel)
	print("[TableManager] Watching", tableModel.Name, "wager", getWager(tableModel),
		isSoloAllowed() and "— solo practice enabled" or "")
end

-- ── Private Table ──────────────────────────────────────────────────────────
-- A claim overrides the table's wager and locks it to the owner and their
-- friends. The tier's own stake is remembered so releasing puts the table back
-- exactly as it was rather than leaving a Celestial table priced at $25.

local claimedByUserId: { [number]: Model } = {}
local originalWager: { [Model]: number } = {}

local function findWatchedTable(name: string?): Model?
	if typeof(name) ~= "string" then return nil end
	for tableModel in pairs(watchers) do
		if tableModel.Name == name then return tableModel end
	end
	return nil
end

local function releaseClaim(tableModel: Model)
	local ownerId = getPrivateOwnerId(tableModel)
	tableModel:SetAttribute(Monetization.TABLE_ATTR_OWNER, 0)
	tableModel:SetAttribute(Monetization.TABLE_ATTR_PRIVATE, false)
	if originalWager[tableModel] then
		tableModel:SetAttribute(Constants.WAGER_ATTR, originalWager[tableModel])
		originalWager[tableModel] = nil
	end
	if ownerId then claimedByUserId[ownerId] = nil end
	refreshSignage(tableModel)
end

Remotes.ClaimTable.OnServerEvent:Connect(function(player: Player, tableName: string, action: string, wager: number?)
	if not PassService.owns(player, "PrivateTable") then
		notify(player, "Private Table is required to reserve a table.", "error")
		return
	end

	if action == "release" then
		local claimed = claimedByUserId[player.UserId]
		if claimed then
			releaseClaim(claimed)
			notify(player, "Table released.", "info")
		end
		return
	end

	if action ~= "claim" then return end

	local tableModel = findWatchedTable(tableName)
	if not tableModel then return end
	if activeMatches[tableModel] then
		notify(player, "That table is mid-match.", "error")
		return
	end

	local existingOwner = getPrivateOwnerId(tableModel)
	if existingOwner and existingOwner ~= player.UserId then
		notify(player, "Somebody already has that table reserved.", "error")
		return
	end

	-- One table each, so a single pass holder cannot fence off the whole hall.
	local previous = claimedByUserId[player.UserId]
	if previous and previous ~= tableModel then
		releaseClaim(previous)
	end

	-- Off a fixed ladder rather than an arbitrary number: a free-form stake
	-- between two consenting accounts is a money-transfer primitive.
	local chosen = nil
	for _, allowed in ipairs(Monetization.PRIVATE_WAGERS) do
		if allowed == wager then chosen = allowed end
	end
	chosen = chosen or getWager(tableModel)

	if originalWager[tableModel] == nil then
		originalWager[tableModel] = getWager(tableModel)
	end
	tableModel:SetAttribute(Constants.WAGER_ATTR, chosen)
	tableModel:SetAttribute(Monetization.TABLE_ATTR_OWNER, player.UserId)
	tableModel:SetAttribute(Monetization.TABLE_ATTR_PRIVATE, true)
	claimedByUserId[player.UserId] = tableModel

	notify(player, "Reserved " .. getTier(tableModel) .. " at "
		.. (chosen > 0 and money(chosen) or "free play") .. " — you and your friends only.", "win")
	refreshSignage(tableModel)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local claimed = claimedByUserId[player.UserId]
	if claimed then
		releaseClaim(claimed)
	end
end)

-- ── Instant Rematch ───────────────────────────────────────────────────────

local lastRematchAt: { [number]: number } = {}

Remotes.Rematch.OnServerEvent:Connect(function(player: Player)
	-- Debounced: without it, spamming the button spams the opponent's toasts.
	local now = os.clock()
	if now - (lastRematchAt[player.UserId] or 0) < 1 then return end
	lastRematchAt[player.UserId] = now

	local tableModel = PlayerService.getTableForPlayer(player)
	if not tableModel then return end

	local ctx = activeMatches[tableModel]
	if not ctx or not ctx.match.isEnded() then return end

	local role = PlayerService.getRole(tableModel, player)
	if not role then return end

	local otherRole = role == "Blue" and "Orange" or "Blue"

	-- At least one seat must own the pass. Two free players still have the
	-- ordinary route: leave, walk back to the pad.
	if not (PassService.owns(ctx.playersByRole[role], "RematchReady")
		or PassService.owns(ctx.playersByRole[otherRole], "RematchReady")) then
		notify(player, "Instant Rematch is required to run it back from here.", "error")
		return
	end

	-- Deliberately not skipped when this seat is already ready: a holder is
	-- pre-armed at match end, and if both seats are holders neither press would
	-- ever reach tryRematch.
	ctx.rematchReady[role] = true

	if ctx.rematchReady[otherRole] then
		tryRematch(tableModel)
	else
		notify(player, "Rematch requested — waiting on your opponent.", "info")
		notify(ctx.playersByRole[otherRole],
			player.DisplayName .. " wants a rematch. Hit REMATCH to accept.", "info")
		local other = ctx.playersByRole[otherRole]
		if other then Remotes.Rematch:FireClient(other, true) end
	end
end)

-- ── Emotes ─────────────────────────────────────────────────────────────────
-- Relayed through the server so the id can be checked against the fixed list
-- and rate limited. A taunt the opponent cannot mute would be a griefing tool,
-- which is why it is one every 1.5s and only between the two seats.

local lastEmoteAt: { [number]: number } = {}

Remotes.Emote.OnServerEvent:Connect(function(player: Player, emoteId: string)
	if not PassService.owns(player, "EmotePack") then return end
	if typeof(emoteId) ~= "string" or not Extras.getEmote(emoteId) then return end

	local now = os.clock()
	if now - (lastEmoteAt[player.UserId] or 0) < 1.5 then return end
	lastEmoteAt[player.UserId] = now

	local tableModel = PlayerService.getTableForPlayer(player)
	if not tableModel then return end
	local role = PlayerService.getRole(tableModel, player)
	if not role then return end

	for _, seat in ipairs({ "Blue", "Orange" }) do
		local other = PlayerService.getPlayer(tableModel, seat)
		if other then
			Remotes.Emote:FireClient(other, role, emoteId)
		end
	end
end)

-- A player bailing out of the win screen gives the table back early.
Remotes.LeaveTable.OnServerEvent:Connect(function(player: Player)
	local tableModel = PlayerService.getTableForPlayer(player)
	if not tableModel then
		PlayerService.thawCharacter(player)
		return
	end
	local ctx = activeMatches[tableModel]
	if ctx and not ctx.match.isEnded() then
		-- Bailing mid-match is a forfeit, handled by onPlayerRemoved.
		PlayerService.releaseRole(tableModel, player)
	else
		destroyMatch(tableModel)
	end
end)

-- Init
-- PassService first: everything below it asks about entitlements, and a sweep
-- that has not started yet reads as "owns nothing".
EconomyService.init()
PassService.init()
LoadoutService.init()
FXInvService.init()

local spawnPoint = workspace:FindFirstChildOfClass("SpawnLocation")
if spawnPoint then
	PlayerService.setLobbyCFrame(spawnPoint.CFrame * CFrame.new(0, 4, 0))
end

for _, obj in ipairs(workspace:GetChildren()) do
	if isTableModel(obj) then watchTable(obj) end
end

workspace.ChildAdded:Connect(function(obj)
	task.defer(function()
		if isTableModel(obj) then watchTable(obj) end
	end)
end)

-- Keep signage honest, and retry stalled seats (e.g. a player who couldn't
-- afford the buy-in when they stepped on but can now).
task.spawn(function()
	while true do
		task.wait(2)
		for tableModel, watcher in pairs(watchers) do
			if tableModel.Parent then
				refreshSignage(tableModel)
				if watcher.tryStartMatch then
					local ok, err = pcall(watcher.tryStartMatch)
					if not ok then warn("[TableManager] tryStartMatch failed:", err) end
				end
			end
		end
	end
end)

print("[TableManager] Initialised.")
