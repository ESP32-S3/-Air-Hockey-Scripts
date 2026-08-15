-- PadHandler (v2)
-- Workspace.TableModel.Pads.<PadName>.Hitbox.PadHandler
-- Attributes on pad model:
--   OccupantId   (number?)  UserId of standing player
--   OccupantName (string?)  display name
--   Locked       (bool)     true during active match

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local hitbox     = script.Parent
local pad        = hitbox.Parent          -- BluePad | OrangePad
local padsFolder = pad.Parent             -- Pads
local tableModel = padsFolder.Parent      -- TableModel
local padName    = pad.Name

local ACTIVE_COLOR = padName == "BluePad" and Color3.fromRGB(0,120,255) or Color3.fromRGB(255,140,0)
local LOCKED_COLOR = Color3.fromRGB(60,60,60)

type Snap = { color: Color3, material: Enum.Material }
local snapshots: { [BasePart]: Snap } = {}
for _, d in ipairs(pad:GetDescendants()) do
	if d:IsA("BasePart") then snapshots[d] = { color = d.Color, material = d.Material } end
end
snapshots[hitbox] = { color = hitbox.Color, material = hitbox.Material }

local function setVisual(c, m) for p in pairs(snapshots) do p.Color = c; p.Material = m end end
local function activatePad()   setVisual(ACTIVE_COLOR, Enum.Material.Neon) end
local function deactivatePad() for p, s in pairs(snapshots) do p.Color = s.color; p.Material = s.material end end
local function lockVisual()    setVisual(LOCKED_COLOR, Enum.Material.SmoothPlastic) end

local occupant: Player? = nil
local function setOccupant(pl)
	occupant = pl
	pad:SetAttribute("OccupantId",   pl and pl.UserId  or nil)
	pad:SetAttribute("OccupantName", pl and pl.Name    or nil)
end
local function isLocked() return pad:GetAttribute("Locked") == true end

local touchCounts: { [Player]: number } = {}

local function tryReassign()
	if isLocked() then return end
	for pl, n in pairs(touchCounts) do
		if n and n > 0 then setOccupant(pl); activatePad(); return end
	end
	setOccupant(nil); deactivatePad()
end

local function releasePlayer(pl)
	touchCounts[pl] = nil
	if occupant == pl then setOccupant(nil); deactivatePad(); tryReassign() end
end

hitbox.Touched:Connect(function(hit)
	if isLocked() then return end
	local pl = Players:GetPlayerFromCharacter(hit.Parent)
	if not pl then return end
	touchCounts[pl] = (touchCounts[pl] or 0) + 1
	if not occupant then setOccupant(pl); activatePad() end
end)

hitbox.TouchEnded:Connect(function(hit)
	local pl = Players:GetPlayerFromCharacter(hit.Parent)
	if not pl then return end
	local n = (touchCounts[pl] or 0) - 1
	if n <= 0 then
		touchCounts[pl] = nil
		if pl == occupant and not isLocked() then setOccupant(nil); deactivatePad(); tryReassign() end
	else
		touchCounts[pl] = n
	end
end)

pad:GetAttributeChangedSignal("Locked"):Connect(function()
	if isLocked() then
		lockVisual()
	else
		touchCounts = {}; setOccupant(nil); deactivatePad()
	end
end)

Players.PlayerRemoving:Connect(function(pl)
	if touchCounts[pl] or occupant == pl then releasePlayer(pl) end
end)

RunService.Heartbeat:Connect(function()
	if not occupant or isLocked() then return end
	local c = occupant.Character
	if not c or not c.Parent then releasePlayer(occupant) end
end)

pad:SetAttribute("Locked", false)
setOccupant(nil)
deactivatePad()
print("[PadHandler] Ready —", padName, "@", tableModel.Name)
