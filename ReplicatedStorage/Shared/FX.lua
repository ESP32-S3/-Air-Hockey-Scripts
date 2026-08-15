-- Shared FX constants: remote kinds, match states, inventory attribute names, and volumes.

local FX = {}

-- FX remotes (server -> client)
FX.KIND_HIT = "Hit"
FX.KIND_GOAL = "Goal"
FX.KIND_WIN = "Win"

-- Player inventory attributes (JSON strings)
FX.ATTR_OWNED = "AH_FX_Owned"
FX.ATTR_EQUIPPED = "AH_FX_Equipped"

-- Inventory remotes
FX.REMOTE_INVENTORY_SYNC = "InventorySync"
FX.REMOTE_EQUIP_REQUEST = "EquipRequest"
FX.REMOTE_BUY_REQUEST = "BuyRequest"

-- MatchService / Remotes.State values
FX.STATE_WAITING = "Waiting"
FX.STATE_COUNTDOWN = "Countdown"
FX.STATE_PLAYING = "Playing"
FX.STATE_GOAL = "Goal"
FX.STATE_MATCH_OVER = "MatchOver"

-- Catalog slots. The paddle hit sound is deliberately absent: it is fixed game
-- audio, not a shop item, and plays from FXPlayer.HIT_SFX_PATH.
FX.SLOT_GOAL_SFX = "GoalSFX"
FX.SLOT_GOAL_VFX = "GoalVFX"
FX.SLOT_WIN_SFX = "WinSFX"

-- Hit sound variants. These names match the Sound instances authored under
-- AirHockeyFXPackage.Assets.Hit.SFX.default, and are picked server-side from
-- impact speed (Constants.HIT_HARD_SPEED).
FX.HIT_HARD = "HardHit"
FX.HIT_SOFT = "SoftHit"
FX.HIT_WALL = "WallHit"

-- Quietest a hit is allowed to play, as a fraction of the Sound's authored
-- volume; the loudest impact plays at 1.0.
FX.HIT_MIN_VOLUME_SCALE = 0.7

-- Scales volume across a variant's speed range so hits don't sound binary.
function FX.getHitVolumeScale(speed: number?, minSpeed: number, maxSpeed: number): number
	local span = math.max(maxSpeed - minSpeed, 1)
	local t = math.clamp(((tonumber(speed) or 0) - minSpeed) / span, 0, 1)
	return FX.HIT_MIN_VOLUME_SCALE + (1 - FX.HIT_MIN_VOLUME_SCALE) * t
end

FX.VOLUME_HIT = 0.6
FX.VOLUME_GOAL = 0.9
FX.VOLUME_WIN = 1.0
FX.VFX_GOAL_LIFETIME = 2.5

function FX.getSfxSlotForKind(kind: string): string?
	if kind == FX.KIND_GOAL then
		return FX.SLOT_GOAL_SFX
	end
	if kind == FX.KIND_WIN then
		return FX.SLOT_WIN_SFX
	end
	return nil
end

function FX.getVolumeForKind(kind: string): number
	if kind == FX.KIND_HIT then return FX.VOLUME_HIT end
	if kind == FX.KIND_GOAL then return FX.VOLUME_GOAL end
	if kind == FX.KIND_WIN then return FX.VOLUME_WIN end
	return 1
end

function FX.isPlayingState(state: string): boolean
	return state == FX.STATE_PLAYING
end

function FX.isMatchOver(state: string): boolean
	return state == FX.STATE_MATCH_OVER
end

return FX