-- FXPlayer
-- Turns "this player scored" into the right cosmetic actually playing.
--
-- Goal explosions and victory shows are sequences owned by VFXLibrary; goal
-- crowd reactions are single licensed sounds described by the catalog. The
-- paddle hit is neither — it is fixed game audio cloned straight out of the
-- package folder.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local FXCatalog = require(script.Parent:WaitForChild("FXCatalog"))
local FXInventory = require(script.Parent:WaitForChild("FXInventory"))
local FX = require(script.Parent:WaitForChild("FX"))
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

local FXPlayer = {}

-- Only used to tint the free default effects, which take the scoring team's
-- colour. Bought cosmetics keep their own identity.
local TEAM_COLORS = {
	Blue = Color3.fromRGB(62, 168, 245),
	Orange = Color3.fromRGB(255, 150, 56),
}
local assetsRoot: Folder? = nil
local getEquippedAccessor: ((Player) -> { [string]: string }?)? = nil

local function getAssetsRoot(): Folder?
	if assetsRoot and assetsRoot.Parent then
		return assetsRoot
	end

	for _, rootName in ipairs(FXCatalog.ASSETS_ROOT_NAMES or { FXCatalog.ASSETS_ROOT_NAME }) do
		local candidate = ReplicatedStorage:FindFirstChild(rootName)
		if candidate and candidate:IsA("Folder") then
			assetsRoot = candidate
			return assetsRoot
		end
	end

	assetsRoot = ReplicatedStorage:FindFirstChild(FXCatalog.ASSETS_ROOT_NAME) :: Folder?
	return assetsRoot
end

local function resolvePath(path: string): Instance?
	local root = getAssetsRoot()
	if not root then
		return nil
	end
	local assets = root:FindFirstChild("Assets")
	if assets then
		root = assets :: Folder
	end
	local current: Instance = root
	-- string.split returns an array; generalized iteration over it yields the
	-- index first, so the name has to come from the second value.
	for _, segment in ipairs(string.split(path, ".")) do
		local child = current:FindFirstChild(segment)
		if not child then
			return nil
		end
		current = child
	end
	return current
end

function FXPlayer.bindInventoryAccessor(accessor)
	if typeof(accessor) == "function" then
		getEquippedAccessor = accessor
	end
end



-- UI audio -----------------------------------------------------------------
-- Short, dry, and quiet: interface sounds should confirm an action without
-- competing with the arena. All cut hard with stopAfter so a menu never rings.
local UI_SOUNDS = {
	click  = { id = 9114246932, speed = 2.4, volume = 0.18, stopAfter = 0.10 },
	select = { id = 9114246932, speed = 1.7, volume = 0.16, stopAfter = 0.12 },
	buy    = { id = 9125402735, speed = 1.7, volume = 0.32, stopAfter = 0.65 },
	denied = { id = 9120801590, speed = 0.7, volume = 0.28, stopAfter = 0.35 },
}

function FXPlayer.playUi(kind: string)
	local spec = UI_SOUNDS[kind]
	if not spec then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. spec.id
	sound.PlaybackSpeed = spec.speed
	sound.Volume = spec.volume
	-- SoundService keeps it flat in the mix rather than positioned in the world.
	sound.Parent = SoundService
	sound:Play()

	TweenService:Create(
		sound,
		TweenInfo.new(0.12, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, spec.stopAfter),
		{ Volume = 0 }
	):Play()
	Debris:AddItem(sound, spec.stopAfter + 0.4)
end

-- Catalog sound entries carry their own mix: the source recordings are long
-- crowd beds, so stopAfter fades them out at a goal-sized length instead of
-- letting nine seconds of cheering run over the next faceoff.
function FXPlayer.playSfx(parent: Instance, entry: FXCatalog.FxEntry, volume: number?)
	if not entry or not entry.soundId then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(entry.soundId)
	sound.Volume = entry.volume or volume or 1
	sound.Parent = parent
	sound:Play()

	local stopAfter = entry.stopAfter
	if stopAfter then
		TweenService:Create(
			sound,
			TweenInfo.new(0.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, stopAfter),
			{ Volume = 0 }
		):Play()
		Debris:AddItem(sound, stopAfter + 0.75)
	else
		Debris:AddItem(sound, 6)
	end
end

-- Hit sounds are fixed game audio, not shop items, so they bypass the catalog
-- and equipped-inventory lookup entirely. The folder holds one authored Sound
-- per variant (HardHit / SoftHit / WallHit); they are cloned rather than rebuilt
-- from a SoundId so their authored volume and playback settings survive.
FXPlayer.HIT_SFX_PATH = "Hit.SFX.default"

function FXPlayer.playHitSfx(parent: Instance, variant: string?, volumeScale: number?)
	local folder = resolvePath(FXPlayer.HIT_SFX_PATH)
	if not folder then
		return
	end

	local source = folder:FindFirstChild(variant or FX.HIT_SOFT)
	if not (source and source:IsA("Sound")) then
		return
	end

	local sound = source:Clone()
	sound.Volume = source.Volume * math.clamp(tonumber(volumeScale) or 1, 0, 1)
	sound.Parent = parent
	sound:Play()
	-- TimeLength reads 0 until the asset is loaded, hence the floor.
	Debris:AddItem(sound, math.max(source.TimeLength, 2) + 0.5)
end



-- Resolves the table a given player is seated at. Falls back to any table in the
-- workspace so FX still land somewhere sane for spectators.
function FXPlayer.findTableModel(player: Player?): Model?
	local name = player and player:GetAttribute("AirHockeyTable")
	if typeof(name) == "string" then
		local found = workspace:FindFirstChild(name)
		if found and found:IsA("Model") then
			return found
		end
	end

	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("Model") then
			local pads = obj:FindFirstChild("Pads")
			if pads and pads:FindFirstChild("BluePad") and pads:FindFirstChild("OrangePad") then
				return obj
			end
		end
	end
	return nil
end

local function getIceSurface(tableModel: Model?): CFrame?
	local tableInst = tableModel and tableModel:FindFirstChild("Table")
	local under = tableInst and tableInst:FindFirstChild("UnderTable")
	local ice = under and under:FindFirstChild("Ice")
	if ice and ice:IsA("BasePart") then
		return CFrame.new(ice.Position + Vector3.new(0, ice.Size.Y / 2, 0))
	end
	return nil
end

function FXPlayer.getPuckWorldCFrame(player: Player?): CFrame
	local tableModel = FXPlayer.findTableModel(player)
	if tableModel then
		local gamePieces = tableModel:FindFirstChild("GamePeices")
		local puckModel = gamePieces and gamePieces:FindFirstChild("Puck")
		if puckModel and puckModel:IsA("Model") then
			return puckModel:GetPivot()
		end
		local ice = getIceSurface(tableModel)
		if ice then
			return ice
		end
	end
	return CFrame.new(0, 4, 0)
end

-- Victory shows are staged over the whole table rather than wherever the puck
-- happened to stop, so they get the centre of the ice.
function FXPlayer.getTableCenterCFrame(player: Player?): CFrame
	local tableModel = FXPlayer.findTableModel(player)
	return (tableModel and getIceSurface(tableModel)) or FXPlayer.getPuckWorldCFrame(player)
end

local function getEquipped(player: Player)
	if getEquippedAccessor then
		local equipped = getEquippedAccessor(player)
		if typeof(equipped) == "table" then
			return equipped
		end
	end
	return FXInventory.getEquipped(player)
end

function FXPlayer.playEquippedSfx(player: Player, parent: Instance, slot: string, volume: number?)
	local equipped = getEquipped(player)
	local id = equipped[slot]
	if not id then
		return
	end

	local entry = FXCatalog.getEntry(slot, id)
	if entry then
		FXPlayer.playSfx(parent, entry, volume)
	end
end

-- `loadout` is the scoring player's equipped ids, sent by the server so both
-- players watch the same explosion. Without it each client would render its
-- own cosmetic, which defeats the point of buying one.
local function resolveId(player: Player, loadout: { [string]: string }?, slot: string): string?
	if typeof(loadout) == "table" and typeof(loadout[slot]) == "string" then
		return loadout[slot]
	end
	return getEquipped(player)[slot]
end

function FXPlayer.playEquippedGoal(player: Player, parent: Instance, team: string?, loadout: { [string]: string }?)
	local sfxEntry = FXCatalog.getEntry(FX.SLOT_GOAL_SFX, resolveId(player, loadout, FX.SLOT_GOAL_SFX) or "")
	if sfxEntry then
		FXPlayer.playSfx(parent, sfxEntry, FX.VOLUME_GOAL)
	end

	local vfxId = resolveId(player, loadout, FX.SLOT_GOAL_VFX)
	if vfxId then
		VFXLibrary.play(FX.SLOT_GOAL_VFX, vfxId, FXPlayer.getPuckWorldCFrame(player), {
			team = team,
			teamColor = TEAM_COLORS[team or ""],
		})
	end
end

function FXPlayer.playEquippedWin(player: Player, parent: Instance, team: string?, loadout: { [string]: string }?)
	local winId = resolveId(player, loadout, FX.SLOT_WIN_SFX)
	if winId then
		VFXLibrary.play(FX.SLOT_WIN_SFX, winId, FXPlayer.getTableCenterCFrame(player), {
			team = team,
			teamColor = TEAM_COLORS[team or ""],
		})
	end
end

function FXPlayer.playForRemoteKind(player: Player, parent: Instance, kind: string, variant: any, volumeScale: number?, team: string?)
	if kind == FX.KIND_HIT then
		FXPlayer.playHitSfx(parent, variant, volumeScale)
		return
	end
	if kind == FX.KIND_GOAL then
		FXPlayer.playEquippedGoal(player, parent, team, variant)
		return
	end
	if kind == FX.KIND_WIN then
		FXPlayer.playEquippedWin(player, parent, team, variant)
		return
	end
end

return FXPlayer
