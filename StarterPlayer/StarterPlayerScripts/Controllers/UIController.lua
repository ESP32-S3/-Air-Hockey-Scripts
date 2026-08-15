-- UIController
-- Drives the pre-built AirHockeyUI authored in StarterGui.
-- Only the transient toast entries are created at runtime; everything else is
-- authored in StarterGui and merely navigated here.
--
-- UI hierarchy expected:
--   AirHockeyUI (ScreenGui)
--   └── HUD (Frame)
--       ├── CashBar (Frame)           ← always visible
--       │   ├── Amount / Delta        (TextLabel)
--       ├── TableBar (Frame)          ← visible only while seated
--       │   ├── TierLabel / StakeLabel(TextLabel)
--       ├── ShopButton (TextButton)   ← handled by ShopController
--       ├── Toasts (Frame)            ← ToastTemplate is cloned per message
--       ├── ScoreBoard (Frame)        ← visible only while seated
--       │   ├── BlueTeam   > ScoreValue  (TextLabel)
--       │   └── OrangeTeam > ScoreValue  (TextLabel)
--       ├── CountdownOverlay (Frame)  ← toggled Visible
--       │   └── CountdownLabel        (TextLabel)
--       └── WinOverlay (Frame)        ← toggled Visible
--           └── Card (Frame)
--               ├── WinLabel          (TextLabel)
--               ├── SubLabel          (TextLabel)
--               ├── PayoutLabel       (TextLabel)
--               └── ReturnToLobby     (TextButton) — fires Remotes.LeaveTable

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Remotes   = require(Shared:WaitForChild("Remotes"))
local FX        = require(Shared:WaitForChild("FX"))
local Constants = require(Shared:WaitForChild("Constants"))
local FXPlayer  = require(Shared:WaitForChild("FXPlayer"))

local PassController = require(script.Parent:WaitForChild("PassController"))

local UIController = {}

local INK       = Color3.fromRGB(22, 35, 58)
local INK_SOFT  = Color3.fromRGB(104, 120, 150)
local SKY       = Color3.fromRGB(62, 168, 245)
local ORANGE    = Color3.fromRGB(255, 150, 56)
local MINT      = Color3.fromRGB(94, 222, 158)
local RED       = Color3.fromRGB(255, 107, 107)
local YELLOW    = Color3.fromRGB(255, 201, 60)

local TEAM_COLORS = { Blue = SKY, Orange = ORANGE }

-- Every pop/punch in here drives a UIScale so the pixel font never renders at a
-- fractional TextSize, which would blur it.
local function scaleOf(inst: GuiObject): UIScale
	local existing = inst:FindFirstChildOfClass("UIScale")
	if existing then return existing end
	local s = Instance.new("UIScale")
	s.Parent = inst
	return s
end

local function punch(inst: GuiObject, from: number, time: number?)
	local s = scaleOf(inst)
	s.Scale = from
	TweenService:Create(s, TweenInfo.new(time or 0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Scale = 1 }):Play()
end

local function money(n: number): string
	local s = tostring(math.abs(math.floor(n)))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return (n < 0 and "-$" or "$") .. out
end

-- Cancellation token so stale countdown coroutines self-abort.
local countdownToken = 0

-- ── UI reference table ────────────────────────────────────────────────────────
-- Centralises all WaitForChild calls; every other function uses this table.
type UIRefs = {
	hud              : Frame,
	scoreBoard       : Frame,
	blueTeam         : Frame,
	blueScore        : TextLabel,
	orangeTeam       : Frame,
	orangeScore      : TextLabel,
	countdownOverlay : Frame,
	countdownLabel   : TextLabel,
	winOverlay       : Frame,
	winCard          : Frame,
	winTopStripe     : Frame,
	winBottomStripe  : Frame,
	winLabel         : TextLabel,
	winSubLabel      : TextLabel,
	winPayoutLabel   : TextLabel,
	returnToLobby    : TextButton,
	rematch          : TextButton,
	cashAmount       : TextLabel,
	cashDelta        : TextLabel,
	tableBar         : Frame,
	tierLabel        : TextLabel,
	stakeLabel       : TextLabel,
	toasts           : Frame,
	toastTemplate    : Frame,
}

local function getUI(player: Player): UIRefs
	local gui   = player:WaitForChild("PlayerGui"):WaitForChild("AirHockeyUI")
	local hud   = gui:WaitForChild("HUD")

	local scoreBoard  = hud:WaitForChild("ScoreBoard")
	local blueTeam    = scoreBoard:WaitForChild("BlueTeam")
	local orangeTeam  = scoreBoard:WaitForChild("OrangeTeam")

	local cdOverlay   = hud:WaitForChild("CountdownOverlay")
	local winOverlay  = hud:WaitForChild("WinOverlay")
	local winCard     = winOverlay:WaitForChild("Card")

	local cashBar     = hud:WaitForChild("CashBar")
	local tableBar    = hud:WaitForChild("TableBar")
	local toasts      = hud:WaitForChild("Toasts")

	return {
		hud              = hud,
		scoreBoard       = scoreBoard,
		blueTeam         = blueTeam,
		blueScore        = blueTeam:WaitForChild("ScoreValue")      :: TextLabel,
		orangeTeam       = orangeTeam,
		orangeScore      = orangeTeam:WaitForChild("ScoreValue")    :: TextLabel,
		countdownOverlay = cdOverlay,
		countdownLabel   = cdOverlay:WaitForChild("CountdownLabel") :: TextLabel,
		winOverlay       = winOverlay,
		winCard          = winCard,
		winTopStripe     = winCard:WaitForChild("TopStripe")        :: Frame,
		winBottomStripe  = winCard:WaitForChild("BottomStripe")     :: Frame,
		winLabel         = winCard:WaitForChild("WinLabel")         :: TextLabel,
		winSubLabel      = winCard:WaitForChild("SubLabel")         :: TextLabel,
		winPayoutLabel   = winCard:WaitForChild("PayoutLabel")      :: TextLabel,
		returnToLobby    = winCard:WaitForChild("ReturnToLobby")    :: TextButton,
		rematch          = winCard:WaitForChild("Rematch")          :: TextButton,
		cashAmount       = cashBar:WaitForChild("Amount")           :: TextLabel,
		cashDelta        = cashBar:WaitForChild("Delta")            :: TextLabel,
		tableBar         = tableBar,
		tierLabel        = tableBar:WaitForChild("TierLabel")       :: TextLabel,
		stakeLabel       = tableBar:WaitForChild("StakeLabel")      :: TextLabel,
		toasts           = toasts,
		toastTemplate    = toasts:WaitForChild("ToastTemplate")     :: Frame,
	}
end

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Show the CountdownOverlay with a message, then hide it after `hideAfter` seconds.
-- Passing nil for hideAfter leaves it visible until the next call.
local function showCountdown(ui: UIRefs, message: string, hideAfter: number?)
	local wasHidden = not ui.countdownOverlay.Visible
	ui.countdownLabel.Text    = message
	ui.countdownOverlay.Visible = true
	-- Each tick lands rather than fades in: the number overshoots and settles.
	-- The band itself only snaps open the first time, so consecutive ticks don't
	-- make it flicker.
	punch(ui.countdownLabel, 1.75, 0.26)
	if wasHidden then
		ui.countdownOverlay.Size = UDim2.new(1, 0, 0, 0)
		TweenService:Create(ui.countdownOverlay,
			TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.new(1, 0, 0, 142) }):Play()
	end
	if hideAfter then
		task.delay(hideAfter, function()
			ui.countdownOverlay.Visible = false
		end)
	end
end

local function hideCountdown(ui: UIRefs)
	ui.countdownOverlay.Visible = false
end

-- Set when the server tells us the other seat has armed a rematch. It is what
-- lets a player who does not own Instant Rematch see the button at all — they
-- can accept, but they can never open the offer.
local rematchOffered = false

local function canRematch(): boolean
	return PassController.owns("RematchReady") or rematchOffered
end

local function showWin(ui: UIRefs, team: string, myRole: string?, stake: number)
	local colour = TEAM_COLORS[team] or SKY
	ui.winLabel.Text      = team:upper() .. " WINS!"
	ui.winLabel.TextColor3 = colour
	-- The banner wears the winner's colour on both edges.
	ui.winTopStripe.BackgroundColor3    = colour
	ui.winBottomStripe.BackgroundColor3 = colour

	if myRole == nil then
		ui.winSubLabel.Text = "MATCH COMPLETE"
		ui.winPayoutLabel.Text = ""
	elseif myRole == team then
		ui.winSubLabel.Text = "YOU WON THE POT"
		ui.winPayoutLabel.Text = stake > 0 and ("+ " .. money(stake * 2)) or ""
		ui.winPayoutLabel.TextColor3 = MINT
	else
		ui.winSubLabel.Text = "BETTER LUCK NEXT ROUND"
		ui.winPayoutLabel.Text = stake > 0 and ("- " .. money(stake)) or ""
		ui.winPayoutLabel.TextColor3 = RED
	end

	ui.returnToLobby.Visible   = true
	ui.returnToLobby.Active    = true
	-- Shown to a holder, and to whoever a holder has offered a rematch to.
	-- Accepting stays free — otherwise a holder could only ever rematch another
	-- holder, which is almost nobody.
	ui.rematch.Visible         = myRole ~= nil and canRematch()
	ui.rematch.Active          = true
	ui.rematch.Text            = "REMATCH"
	ui.winOverlay.Visible      = true

	-- Banner slams down to full height, then the headline lands.
	ui.winCard.Size = UDim2.new(1, 0, 0, 0)
	TweenService:Create(ui.winCard, TweenInfo.new(0.24, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Size = UDim2.new(1, 0, 0, 300) }):Play()
	task.delay(0.14, function()
		if ui.winOverlay.Visible then punch(ui.winLabel, 1.5, 0.3) end
	end)
end

local function hideWin(ui: UIRefs)
	ui.winOverlay.Visible    = false
	ui.returnToLobby.Visible = false
	ui.rematch.Visible       = false
	rematchOffered           = false
end

-- Slides a short-lived message into the bottom-centre stack.
local TOAST_COLORS = {
	info  = SKY,
	win   = MINT,
	lose  = RED,
	error = RED,
}

local toastOrder = 0

local function pushToast(ui: UIRefs, message: string, kind: string?)
	if typeof(message) ~= "string" or message == "" then return end

	toastOrder += 1
	local toast = ui.toastTemplate:Clone()
	toast.Name = "Toast"
	toast.LayoutOrder = toastOrder
	toast.Visible = true
	toast.BackgroundTransparency = 1

	-- Message text stays ink so it is readable on the white plate; the kind is
	-- carried by the colour chip down the left edge instead.
	local label = toast:WaitForChild("Message") :: TextLabel
	label.Text = message
	label.TextColor3 = INK
	label.TextTransparency = 1

	local accent = toast:FindFirstChild("Accent")
	if accent and accent:IsA("Frame") then
		accent.BackgroundColor3 = TOAST_COLORS[kind or "info"] or TOAST_COLORS.info
	end

	toast.Parent = ui.toasts
	punch(toast, 0.9, 0.2)

	local fadeIn = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(toast, fadeIn, { BackgroundTransparency = 0 }):Play()
	TweenService:Create(label, fadeIn, { TextTransparency = 0 }):Play()

	task.delay(3.5, function()
		if not toast.Parent then return end
		local fadeOut = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(toast, fadeOut, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(label, fadeOut, { TextTransparency = 1 }):Play()
		task.wait(0.4)
		toast:Destroy()
	end)
end

local function setCash(ui: UIRefs, amount: number, delta: number?)
	ui.cashAmount.Text = money(amount)
	if not delta or delta == 0 then return end

	ui.cashDelta.Text = (delta > 0 and "+" or "") .. money(delta)
	ui.cashDelta.TextColor3 = delta > 0 and Color3.fromRGB(120, 235, 150) or Color3.fromRGB(255, 120, 120)
	ui.cashDelta.TextTransparency = 0
	TweenService:Create(
		ui.cashDelta,
		TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ TextTransparency = 1 }
	):Play()
end

-- Goals are the loudest thing on screen, so the digit that changed jumps and the
-- team's block flashes white for a beat.
local lastBlue, lastOrange = -1, -1

local function flashBlock(block: Frame, base: Color3)
	block.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	TweenService:Create(block, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundColor3 = base }):Play()
end

local function setScore(ui: UIRefs, blue: number, orange: number)
	if blue ~= lastBlue and lastBlue >= 0 and blue > lastBlue then
		punch(ui.blueScore, 1.9, 0.34)
		flashBlock(ui.blueTeam, SKY)
	end
	if orange ~= lastOrange and lastOrange >= 0 and orange > lastOrange then
		punch(ui.orangeScore, 1.9, 0.34)
		flashBlock(ui.orangeTeam, ORANGE)
	end
	lastBlue, lastOrange = blue, orange
	ui.blueScore.Text   = tostring(blue)
	ui.orangeScore.Text = tostring(orange)
end

-- ── init ─────────────────────────────────────────────────────────────────────

function UIController.init()
	local player = Players.LocalPlayer
	local ui     = getUI(player)

	local myRole: string? = nil
	local myStake = 0

	-- Arcade button feel: lift on hover, press into its own shadow on click.
	local function wireButton(button: TextButton, base: Color3)
		local home = button.Position
		local quick = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		button.MouseEnter:Connect(function()
			TweenService:Create(button, quick, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.35) }):Play()
		end)
		button.MouseLeave:Connect(function()
			TweenService:Create(button, quick, { BackgroundColor3 = base }):Play()
			button.Position = home
		end)
		button.MouseButton1Down:Connect(function()
			button.Position = home + UDim2.fromOffset(4, 4)
			FXPlayer.playUi("click")
		end)
		button.MouseButton1Up:Connect(function()
			button.Position = home
		end)
	end
	wireButton(ui.returnToLobby, YELLOW)
	wireButton(ui.rematch, MINT)

	-- The offer can land after the win card is already up, so reveal the button
	-- in place rather than only at showWin time.
	Remotes.Rematch.OnClientEvent:Connect(function(offered)
		rematchOffered = offered == true
		if ui.winOverlay.Visible and myRole ~= nil then
			ui.rematch.Visible = canRematch()
		end
	end)

	ui.rematch.MouseButton1Click:Connect(function()
		if not ui.rematch.Active then return end
		ui.rematch.Active = false
		ui.rematch.Text = "WAITING..."
		Remotes.Rematch:FireServer()
		-- Re-armed rather than left dead: the opponent may still be deciding, and
		-- a button that never comes back reads as broken.
		task.delay(4, function()
			if ui.rematch.Visible then
				ui.rematch.Active = true
				ui.rematch.Text = "REMATCH"
			end
		end)
	end)

	-- Scoreboard/countdown only make sense while seated at a table.
	local function refreshSeat()
		myRole = player:GetAttribute("AirHockeyRole")
		local tableName = player:GetAttribute("AirHockeyTable")
		local stake = tonumber(player:GetAttribute("AirHockeyWager")) or 0
		if stake > 0 then myStake = stake end

		local seated = typeof(tableName) == "string"
		ui.scoreBoard.Visible = seated
		ui.tableBar.Visible = seated

		if seated then
			local tableModel = workspace:FindFirstChild(tableName)
			local tier = tableModel and tableModel:GetAttribute(Constants.TIER_ATTR)
			local label = typeof(tier) == "string" and tier or tableName
			-- Priority Seating wears a crown on the seat it jumped the queue for.
			ui.tierLabel.Text = PassController.owns("PrioritySeating") and ("\u{2605} " .. label) or label
			ui.stakeLabel.Text = stake > 0
				and (money(stake) .. " · POT " .. money(stake * 2))
				or "FREE PLAY"
			punch(ui.scoreBoard, 0.85, 0.3)
		else
			myStake = 0
			hideWin(ui)
			hideCountdown(ui)
			setScore(ui, 0, 0)
		end
	end

	player:GetAttributeChangedSignal("AirHockeyRole"):Connect(refreshSeat)
	player:GetAttributeChangedSignal("AirHockeyTable"):Connect(refreshSeat)
	player:GetAttributeChangedSignal("AirHockeyWager"):Connect(refreshSeat)
	refreshSeat()

	-- Cash ──────────────────────────────────────────────────────────────
	setCash(ui, tonumber(player:GetAttribute(Constants.CASH_ATTR)) or 0)
	Remotes.CashSync.OnClientEvent:Connect(function(amount: number, delta: number?)
		setCash(ui, tonumber(amount) or 0, tonumber(delta) or 0)
	end)

	-- Server-pushed messages (wager results, buy-in failures, forfeits) ─────────
	Remotes.Notify.OnClientEvent:Connect(function(message: string, kind: string?)
		pushToast(ui, message, kind)
	end)

	Remotes.ShopResult.OnClientEvent:Connect(function(result)
		if typeof(result) == "table" and result.message then
			pushToast(ui, result.message, result.ok and "win" or "error")
		end
	end)

	-- Countdown timer ─────────────────────────────────────────────────────────
	Remotes.Countdown.OnClientEvent:Connect(function(duration: number)
		countdownToken += 1
		local token = countdownToken

		for i = duration, 1, -1 do
			if token ~= countdownToken then return end
			showCountdown(ui, tostring(i))
			task.wait(1)
		end

		if token ~= countdownToken then return end
		showCountdown(ui, "GO!")
		task.wait(0.5)
		if token ~= countdownToken then return end
		hideCountdown(ui)
	end)

	-- Live score (individual labels) ───────────────────────────────────────────
	Remotes.Score.OnClientEvent:Connect(function(s)
		setScore(ui, s.Blue or 0, s.Orange or 0)
	end)

	-- FX events: UI only (sounds/VFX are FXController + FXPlayer)
	Remotes.FX.OnClientEvent:Connect(function(kind: string, team: string)
		if kind == FX.KIND_GOAL then
			showCountdown(ui, (team or "Team") .. " scores!", 1.2)
		elseif kind == FX.KIND_WIN then
			hideCountdown(ui)
			showWin(ui, team or "", myRole, myStake)
		end
	end)

	Remotes.State.OnClientEvent:Connect(function(state: string)
		if state ~= FX.STATE_MATCH_OVER then
			hideWin(ui)
		end
	end)
end

return UIController