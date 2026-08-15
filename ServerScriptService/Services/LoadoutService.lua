-- LoadoutService
-- Persists the two pass-gated selections that are not FX catalog items: which
-- paddle skin a player uses, and which name-tag title they fly.
--
-- Selections are stored as chosen, and validated against pass ownership only
-- when read. Someone whose Paddle Pack lapses falls back to the standard mallet
-- but keeps their choice, so re-buying restores it rather than making them pick
-- again — and a stored id that no longer exists in Extras simply resolves to the
-- default instead of erroring.

local Players           = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local Monetization = require(Shared:WaitForChild("Monetization"))
local Extras       = require(Shared:WaitForChild("Extras"))
local Remotes      = require(Shared:WaitForChild("Remotes"))
local PassService  = require(script.Parent:WaitForChild("PassService"))

local LoadoutService = {}

local DATASTORE_NAME = "AH_Loadout_v1"

local store = nil
pcall(function()
	store = DataStoreService:GetDataStore(DATASTORE_NAME)
end)

-- userId -> { paddleSkin: string, title: string }  (raw choice, unvalidated)
local choiceByUserId: { [number]: { paddleSkin: string, title: string } } = {}
local dirtyByUserId: { [number]: boolean } = {}

local function defaultChoice()
	return {
		paddleSkin = Extras.DEFAULT_PADDLE_SKIN,
		title = Extras.DEFAULT_TITLE,
	}
end

-- The *effective* loadout: the stored choice with anything the player is no
-- longer entitled to swapped back for the default.
local function resolve(player: Player)
	local choice = choiceByUserId[player.UserId] or defaultChoice()
	local hasPass = PassService.predicateFor(player)

	local skin = Extras.getPaddleSkin(choice.paddleSkin)
	if not Extras.canUseSkin(skin, hasPass) then
		skin = Extras.getPaddleSkin(Extras.DEFAULT_PADDLE_SKIN)
	end

	local title = Extras.getTitle(choice.title)
	if not Extras.canUseTitle(title, hasPass) then
		title = Extras.getTitle(Extras.DEFAULT_TITLE)
	end

	return { paddleSkin = skin.id, title = title.id }
end

local function syncPlayer(player: Player)
	local effective = resolve(player)
	player:SetAttribute(Monetization.LOADOUT_ATTR_PADDLE, effective.paddleSkin)
	player:SetAttribute(Monetization.LOADOUT_ATTR_TITLE, effective.title)
	-- The client needs the raw choice too, so the shop can show a locked skin
	-- as still-selected rather than silently snapping the highlight to Standard.
	Remotes.LoadoutSync:FireClient(player, {
		effective = effective,
		choice = choiceByUserId[player.UserId] or defaultChoice(),
	})
end

local function loadPlayer(player: Player)
	local choice = defaultChoice()
	if store then
		local ok, stored = pcall(function()
			return store:GetAsync(tostring(player.UserId))
		end)
		if ok and typeof(stored) == "table" then
			if typeof(stored.paddleSkin) == "string" then choice.paddleSkin = stored.paddleSkin end
			if typeof(stored.title) == "string" then choice.title = stored.title end
		end
	end
	choiceByUserId[player.UserId] = choice
	if player.Parent then
		syncPlayer(player)
	end
	return choice
end

local function savePlayer(userId: number)
	if not store or not dirtyByUserId[userId] then return end
	local choice = choiceByUserId[userId]
	if not choice then return end
	local ok = pcall(function()
		store:SetAsync(tostring(userId), { paddleSkin = choice.paddleSkin, title = choice.title })
	end)
	if ok then
		dirtyByUserId[userId] = nil
	end
end

-- ── Public API ────────────────────────────────────────────────────────────

-- Always safe to call: an unloaded player resolves to the defaults rather than
-- yielding, because PaddleService calls this while spawning a paddle.
function LoadoutService.get(player: Player)
	if not choiceByUserId[player.UserId] then
		return defaultChoice()
	end
	return resolve(player)
end

function LoadoutService.set(player: Player, kind: string, id: string): (boolean, string)
	if typeof(kind) ~= "string" or typeof(id) ~= "string" then
		return false, "Bad request."
	end

	local choice = choiceByUserId[player.UserId]
	if not choice then
		choice = loadPlayer(player)
	end

	local hasPass = PassService.predicateFor(player)

	if kind == "paddle" then
		local skin = Extras.getPaddleSkin(id)
		if skin.id ~= id then
			return false, "That paddle doesn't exist."
		end
		if not Extras.canUseSkin(skin, hasPass) then
			return false, "Paddle Pack required."
		end
		choice.paddleSkin = skin.id
	elseif kind == "title" then
		local title = Extras.getTitle(id)
		if title.id ~= id then
			return false, "That title doesn't exist."
		end
		if not Extras.canUseTitle(title, hasPass) then
			return false, "Name Tag required."
		end
		choice.title = title.id
	else
		return false, "Bad request."
	end

	dirtyByUserId[player.UserId] = true
	syncPlayer(player)
	return true, "Equipped!"
end

function LoadoutService.init()
	local function onAdded(player: Player)
		task.spawn(loadPlayer, player)
	end

	Players.PlayerAdded:Connect(onAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		savePlayer(player.UserId)
		choiceByUserId[player.UserId] = nil
		dirtyByUserId[player.UserId] = nil
	end)

	game:BindToClose(function()
		for userId in pairs(dirtyByUserId) do
			savePlayer(userId)
		end
	end)

	Remotes.LoadoutRequest.OnServerEvent:Connect(function(player: Player, kind: string, id: string)
		local ok, message = LoadoutService.set(player, kind, id)
		Remotes.ShopResult:FireClient(player, {
			action = "loadout",
			ok = ok,
			code = ok and "equipped" or "denied",
			slot = kind,
			id = id,
			message = message,
		})
	end)

	-- Buying Paddle Pack mid-session should light up the skin they had already
	-- picked and been downgraded from, without them having to re-select it.
	PassService.Changed:Connect(function(player: Player)
		if choiceByUserId[player.UserId] then
			syncPlayer(player)
		end
	end)
end

return LoadoutService
